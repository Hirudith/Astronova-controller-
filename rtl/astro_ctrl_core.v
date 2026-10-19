// astro_ctrl_core.v -- next-state logic of the Astronova protection controller.
//
// This module is purely combinational. All controller state (configuration and
// run-time) is carried in one packed vector: st_q is the (voted) current state,
// st_d the next state. astro_ctrl_tmr.v instantiates one copy (TMR=0) or three
// copies with voted feedback (TMR=1) and owns the flip-flops.
//
// Function, per clock cycle (order matters; python/astronova/model.py mirrors it):
//   1. tick prescaler
//   2. register writes (config, telemetry staging, commands)
//   3. telemetry commit: CRC / reserved-bit / source-flag / sequence checks,
//      threat level update with hysteresis, freshness age
//   4. dwell timer
//   5. fallback entry/exit (stale, consecutive-invalid)
//   6. desired-mode selection and dwell gating
//   7. mode-switch FSM with 4-phase sw_req/sw_ack handshake and watchdog
//   8. soft reset (dynamic state only), hard reset (everything)

`include "astro_ctrl_defs.vh"

module astro_ctrl_core #(
    parameter        HAS_READ     = 1,
    parameter [7:0]  BUILD_TMR    = 8'd1,
    parameter [3:0]  DEF_CTRL     = 4'h0,
    parameter [23:0] DEF_PRESCALE = 24'd99_999,       // 1 ms tick at 100 MHz
    parameter [31:0] DEF_FRESH_TO = 32'd180_000,      // 3 min
    parameter [31:0] DEF_DWELL_UP = 32'd0,            // escalate immediately
    parameter [31:0] DEF_DWELL_DN = 32'd600_000,      // 10 min before relaxing
    parameter [31:0] DEF_SW_TO    = 32'd10_000_000,   // 100 ms handshake watchdog
    parameter [31:0] DEF_TH_ELEV  = {16'h0140, 16'h0180}, // fall 1.25x, rise 1.5x (Q8.8)
    parameter [31:0] DEF_TH_EXTR  = {16'h0300, 16'h0400}, // fall 3.0x,  rise 4.0x (Q8.8)
    parameter [7:0]  DEF_MODE_MAP = 8'hA8,            // FB=TMR X=TMR E=TMR N=BASELINE
    parameter [19:0] DEF_LIMITS   = 20'h3_03_03       // retry 3, recover 3, invalid 3
) (
    input  wire                    rst,
    input  wire [`ASTRO_ST_W-1:0]  st_q,
    output reg  [`ASTRO_ST_W-1:0]  st_d,

    input  wire                    wr_en,
    input  wire [5:0]              wr_addr,
    input  wire [31:0]             wr_data,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [5:0]              rd_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [31:0]             rd_data,

    input  wire                    sw_ack,
    input  wire [1:0]              pl_mode,

    output wire [`ASTRO_OUT_W-1:0] out
);

    // ------------------------------------------------------------------
    // State unpacking. The concatenation order defines the layout of st_q.
    // ------------------------------------------------------------------
    wire [3:0]  c_ctrl_q;
    wire [23:0] c_presc_q;
    wire [31:0] c_fresh_q, c_dup_q, c_ddn_q, c_swto_q;
    wire [15:0] c_er_q, c_ef_q, c_xr_q, c_xf_q;
    wire [7:0]  c_map_q, c_invl_q, c_recn_q;
    wire [3:0]  c_retry_q;

    wire [2:0]  fsm_q;
    wire [23:0] presc_q;
    wire [31:0] age_q, dwell_q, wd_q;
    /* verilator lint_off UNUSEDSIGNAL */   // read-back only (unused when HAS_READ=0)
    wire [15:0] metric_q;
    wire [7:0]  lseq_q;
    wire        hseq_q;
    wire [1:0]  level_q;
    wire [7:0]  invc_q, recc_q;
    wire        fb_q;
    wire [1:0]  cur_q, tgt_q;
    wire [3:0]  fails_q, rej_q;
    wire [31:0] tdata_q;
    /* verilator lint_on UNUSEDSIGNAL */

    assign {c_ctrl_q, c_presc_q, c_fresh_q, c_dup_q, c_ddn_q, c_swto_q,
            c_er_q, c_ef_q, c_xr_q, c_xf_q, c_map_q, c_invl_q, c_recn_q, c_retry_q,
            fsm_q, presc_q, age_q, dwell_q, wd_q, metric_q, lseq_q, hseq_q, level_q,
            invc_q, recc_q, fb_q, cur_q, tgt_q, fails_q, rej_q, tdata_q} = st_q;

    reg [3:0]  c_ctrl_d;
    reg [23:0] c_presc_d;
    reg [31:0] c_fresh_d, c_dup_d, c_ddn_d, c_swto_d;
    reg [15:0] c_er_d, c_ef_d, c_xr_d, c_xf_d;
    reg [7:0]  c_map_d, c_invl_d, c_recn_d;
    reg [3:0]  c_retry_d;

    reg [2:0]  fsm_d;
    reg [23:0] presc_d;
    reg [31:0] age_d, dwell_d, wd_d;
    reg [15:0] metric_d;
    reg [7:0]  lseq_d;
    reg        hseq_d;
    reg [1:0]  level_d;
    reg [7:0]  invc_d, recc_d;
    reg        fb_d;
    reg [1:0]  cur_d, tgt_d;
    reg [3:0]  fails_d, rej_d;
    reg [31:0] tdata_d;

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    // CRC-8, polynomial 0x07, init 0x00, no reflection, MSB first
    // (CRC-8/SMBUS). Covers the 32-bit telemetry word.
    function [7:0] crc8_32;
        input [31:0] d;
        integer i;
        reg [7:0] c;
        begin
            c = 8'h00;
            for (i = 31; i >= 0; i = i - 1)
                c = (c[7] ^ d[i]) ? ({c[6:0], 1'b0} ^ 8'h07) : {c[6:0], 1'b0};
            crc8_32 = c;
        end
    endfunction

    // Threat level with hysteresis: rise thresholds to go up, fall thresholds
    // (<= rise) to come down.
    function [1:0] next_level;
        input [1:0]  lv;
        input [15:0] m, er, ef, xr, xf;
        begin
            case (lv)
                `LV_NORMAL:   next_level = (m >= xr) ? `LV_EXTREME :
                                           (m >= er) ? `LV_ELEVATED : `LV_NORMAL;
                `LV_ELEVATED: next_level = (m >= xr) ? `LV_EXTREME :
                                           (m <  ef) ? `LV_NORMAL : `LV_ELEVATED;
                `LV_EXTREME:  next_level = (m >= xf) ? `LV_EXTREME :
                                           (m <  ef) ? `LV_NORMAL : `LV_ELEVATED;
                default:      next_level = (m >= xr) ? `LV_EXTREME :
                                           (m >= er) ? `LV_ELEVATED : `LV_NORMAL;
            endcase
        end
    endfunction

    function [31:0] sat_inc32;
        input [31:0] v;
        sat_inc32 = (&v) ? v : v + 32'd1;
    endfunction

    function [7:0] sat_inc8;
        input [7:0] v;
        sat_inc8 = (&v) ? v : v + 8'd1;
    endfunction

    // ------------------------------------------------------------------
    // Combinational intermediates
    // ------------------------------------------------------------------
    reg        tick;
    reg        cmd_clr, cmd_srst, commit;
    reg [7:0]  seq_diff;
    reg [3:0]  rej;
    reg        accept, reject;
    reg        stale, inval, fb_cond;
    reg        static_en, force_sw, allowed, timeout;
    reg [1:0]  desired, map_mode;
    reg [3:0]  fails_n;
    reg [`NEV-1:0] ev;

    always @* begin
        // defaults: hold state
        {c_ctrl_d, c_presc_d, c_fresh_d, c_dup_d, c_ddn_d, c_swto_d,
         c_er_d, c_ef_d, c_xr_d, c_xf_d, c_map_d, c_invl_d, c_recn_d, c_retry_d,
         fsm_d, presc_d, age_d, dwell_d, wd_d, metric_d, lseq_d, hseq_d, level_d,
         invc_d, recc_d, fb_d, cur_d, tgt_d, fails_d, rej_d, tdata_d} = st_q;
        ev = {`NEV{1'b0}};

        // 1. tick prescaler ------------------------------------------------
        tick    = (presc_q == 24'd0);
        presc_d = tick ? c_presc_q : presc_q - 24'd1;

        // 2. register writes ------------------------------------------------
        cmd_clr  = wr_en && (wr_addr == `A_CMD) && wr_data[0];
        cmd_srst = wr_en && (wr_addr == `A_CMD) && wr_data[1];
        commit   = wr_en && (wr_addr == `A_TCRC);
        if (wr_en) begin
            case (wr_addr)
                `A_CTRL:     c_ctrl_d  = wr_data[3:0];
                `A_TDATA:    tdata_d   = wr_data;
                `A_PRESCALE: begin                     // new period starts now
                    c_presc_d = wr_data[23:0];
                    presc_d   = wr_data[23:0];
                end
                `A_FRESH_TO: c_fresh_d = wr_data;
                `A_DWELL_UP: c_dup_d   = wr_data;
                `A_DWELL_DN: c_ddn_d   = wr_data;
                `A_SW_TO:    c_swto_d  = wr_data;
                `A_TH_ELEV:  {c_ef_d, c_er_d} = wr_data;
                `A_TH_EXTR:  {c_xf_d, c_xr_d} = wr_data;
                `A_MODE_MAP: c_map_d   = wr_data[7:0];
                `A_LIMITS:   {c_retry_d, c_recn_d, c_invl_d} = wr_data[19:0];
                default: ;
            endcase
        end

        // 3. telemetry commit ------------------------------------------------
        // TDATA: [15:0] metric [23:16] seq [24] source-ok [31:25] reserved (0)
        seq_diff      = tdata_q[23:16] - lseq_q;
        rej[`RJ_CRC]  = (wr_data[7:0] != crc8_32(tdata_q));
        rej[`RJ_RSVD] = (tdata_q[31:25] != 7'd0);
        rej[`RJ_SRC]  = ~tdata_q[24];
        rej[`RJ_SEQ]  = hseq_q && ((seq_diff == 8'd0) || seq_diff[7]);   // accept 1..127 ahead
        accept = commit && (rej == 4'd0);
        reject = commit && (rej != 4'd0);

        if (accept) begin
            metric_d = tdata_q[15:0];
            lseq_d   = tdata_q[23:16];
            hseq_d   = 1'b1;
            age_d    = 32'd0;
            invc_d   = 8'd0;
            recc_d   = sat_inc8(recc_q);
            level_d  = next_level(level_q, tdata_q[15:0], c_er_q, c_ef_q, c_xr_q, c_xf_q);
            ev[`EV_ACCEPT] = 1'b1;
        end else begin
            if (reject) begin
                invc_d = sat_inc8(invc_q);
                recc_d = 8'd0;
                rej_d  = rej;
                ev[`EV_REJECT] = 1'b1;
            end
            if (tick) age_d = sat_inc32(age_q);
        end

        // 4. dwell timer (cleared by a completed switch below) --------------
        if (tick) dwell_d = sat_inc32(dwell_q);

        // 5. fallback ---------------------------------------------------------
        stale   = (c_fresh_q != 32'd0) && (age_q >= c_fresh_q);
        inval   = (c_invl_q  != 8'd0)  && (invc_q >= c_invl_q);
        fb_cond = stale | inval;
        if (!fb_q) begin
            if (fb_cond) begin
                fb_d   = 1'b1;
                recc_d = 8'd0;
                ev[`EV_FB_ENTER] = 1'b1;
            end
        end else if (!fb_cond && (recc_q >= c_recn_q)) begin
            fb_d = 1'b0;
            ev[`EV_FB_EXIT] = 1'b1;
        end

        // 6. desired mode -----------------------------------------------------
        case (level_q)
            `LV_NORMAL:   map_mode = c_map_q[1:0];
            `LV_ELEVATED: map_mode = c_map_q[3:2];
            `LV_EXTREME:  map_mode = c_map_q[5:4];
            default:      map_mode = c_map_q[7:6];
        endcase
        static_en = c_ctrl_q[1];
        if (static_en)  desired = c_ctrl_q[3:2];
        else if (fb_q)  desired = c_ctrl_q[0] ? cur_q : c_map_q[7:6];   // D6: hold / fail-safe
        else            desired = map_mode;
        force_sw = static_en | fb_q;    // overrides and fallback bypass dwell
        allowed  = force_sw || ((desired > cur_q) ? (dwell_q >= c_dup_q)
                                                  : (dwell_q >= c_ddn_q));

        // 7. mode-switch FSM --------------------------------------------------
        timeout = (c_swto_q != 32'd0) && (wd_q >= c_swto_q);
        fails_n = (&fails_q) ? fails_q : fails_q + 4'd1;
        case (fsm_q)
            `S_INIT: begin
                if (!sw_ack) begin
                    cur_d = pl_mode;
                    fsm_d = `S_IDLE;
                    wd_d  = 32'd0;
                end else if (timeout) begin
                    fails_d = fails_n;
                    fsm_d   = (c_retry_q != 4'd0 && fails_n >= c_retry_q) ? `S_FAULT : `S_INIT;
                    wd_d    = 32'd0;
                    ev[`EV_SW_FAIL] = 1'b1;
                end else begin
                    wd_d = sat_inc32(wd_q);
                end
            end
            `S_IDLE: begin
                wd_d = 32'd0;
                if (!sw_ack) begin
                    if (pl_mode != cur_q) begin          // payload left the commanded mode
                        tgt_d = cur_q;
                        fsm_d = `S_REQ;
                        ev[`EV_MISMATCH] = 1'b1;
                        ev[`EV_SW_START] = 1'b1;
                    end else if ((desired != cur_q) && allowed) begin
                        tgt_d = desired;
                        fsm_d = `S_REQ;
                        ev[`EV_SW_START] = 1'b1;
                    end
                end
            end
            `S_REQ: begin
                if (sw_ack) begin
                    wd_d = 32'd0;
                    if (pl_mode == tgt_q) begin
                        cur_d   = tgt_q;
                        dwell_d = 32'd0;
                        fails_d = 4'd0;
                        fsm_d   = `S_REL;
                        ev[`EV_SW_DONE] = 1'b1;
                    end else begin
                        fails_d = fails_n;
                        fsm_d   = (c_retry_q != 4'd0 && fails_n >= c_retry_q) ? `S_FAULT : `S_INIT;
                        ev[`EV_SW_FAIL] = 1'b1;
                    end
                end else if (timeout) begin
                    wd_d    = 32'd0;
                    fails_d = fails_n;
                    fsm_d   = (c_retry_q != 4'd0 && fails_n >= c_retry_q) ? `S_FAULT : `S_INIT;
                    ev[`EV_SW_FAIL] = 1'b1;
                end else begin
                    wd_d = sat_inc32(wd_q);
                end
            end
            `S_REL: begin
                if (!sw_ack) begin
                    fsm_d = `S_IDLE;
                    wd_d  = 32'd0;
                end else if (timeout) begin
                    wd_d    = 32'd0;
                    fails_d = fails_n;
                    fsm_d   = (c_retry_q != 4'd0 && fails_n >= c_retry_q) ? `S_FAULT : `S_INIT;
                    ev[`EV_SW_FAIL] = 1'b1;
                end else begin
                    wd_d = sat_inc32(wd_q);
                end
            end
            `S_FAULT: begin
                wd_d = 32'd0;
                if (cmd_clr) begin
                    fsm_d   = `S_INIT;
                    fails_d = 4'd0;
                end
            end
            default: begin                                // illegal encoding
                fsm_d = `S_INIT;
                wd_d  = 32'd0;
                ev[`EV_ILLEGAL] = 1'b1;
            end
        endcase

        // 8. resets -------------------------------------------------------------
        if (cmd_srst || rst) begin
            fsm_d = `S_INIT;  presc_d = 24'd0;
            age_d = 32'hFFFF_FFFF;  dwell_d = 32'hFFFF_FFFF;  wd_d = 32'd0;
            metric_d = 16'd0;  lseq_d = 8'd0;  hseq_d = 1'b0;  level_d = `LV_NORMAL;
            invc_d = 8'd0;  recc_d = 8'd0;  fb_d = 1'b1;                // start in fallback
            cur_d = `M_BASELINE;  tgt_d = `M_BASELINE;  fails_d = 4'd0;  rej_d = 4'd0;
            tdata_d = 32'd0;
            ev = {`NEV{1'b0}};
        end
        if (rst) begin
            c_ctrl_d  = DEF_CTRL;      c_presc_d = DEF_PRESCALE;
            c_fresh_d = DEF_FRESH_TO;  c_dup_d   = DEF_DWELL_UP;
            c_ddn_d   = DEF_DWELL_DN;  c_swto_d  = DEF_SW_TO;
            {c_ef_d, c_er_d} = DEF_TH_ELEV;
            {c_xf_d, c_xr_d} = DEF_TH_EXTR;
            c_map_d   = DEF_MODE_MAP;
            {c_retry_d, c_recn_d, c_invl_d} = DEF_LIMITS;
        end

        st_d = {c_ctrl_d, c_presc_d, c_fresh_d, c_dup_d, c_ddn_d, c_swto_d,
                c_er_d, c_ef_d, c_xr_d, c_xf_d, c_map_d, c_invl_d, c_recn_d, c_retry_d,
                fsm_d, presc_d, age_d, dwell_d, wd_d, metric_d, lseq_d, hseq_d, level_d,
                invc_d, recc_d, fb_d, cur_d, tgt_d, fails_d, rej_d, tdata_d};
    end

    // ------------------------------------------------------------------
    // Outputs: functions of the current state only (events also of inputs)
    // ------------------------------------------------------------------
    wire o_req   = (fsm_q == `S_REQ);
    wire o_fault = (fsm_q == `S_FAULT);
    wire o_busy  = (fsm_q == `S_REQ) || (fsm_q == `S_REL);
    assign out = {ev, o_busy, o_fault, fb_q, level_q, cur_q, tgt_q, o_req};

    // ------------------------------------------------------------------
    // Register read-back (instantiated in one domain only)
    // ------------------------------------------------------------------
    generate
        if (HAS_READ != 0) begin : g_read
            reg [31:0] rd_mux;
            assign rd_data = rd_mux;
            always @* begin
                case (rd_addr)
                    `A_ID:       rd_mux = `ASTRO_ID;
                    `A_VERSION:  rd_mux = {8'h00, BUILD_TMR, `ASTRO_VER_MAJOR, `ASTRO_VER_MINOR};
                    `A_CTRL:     rd_mux = {28'd0, c_ctrl_q};
                    `A_STATUS:   rd_mux = {12'd0, desired, pl_mode, sw_ack, o_req, o_busy, o_fault,
                                            inval, stale, fb_q, tgt_q, cur_q, level_q, fsm_q};
                    `A_TSTAT:    rd_mux = {3'd0, rej_q, hseq_q, lseq_q, metric_q};
                    `A_AGE:      rd_mux = age_q;
                    `A_DWELL:    rd_mux = dwell_q;
                    `A_TDATA:    rd_mux = tdata_q;
                    `A_PRESCALE: rd_mux = {8'd0, c_presc_q};
                    `A_FRESH_TO: rd_mux = c_fresh_q;
                    `A_DWELL_UP: rd_mux = c_dup_q;
                    `A_DWELL_DN: rd_mux = c_ddn_q;
                    `A_SW_TO:    rd_mux = c_swto_q;
                    `A_TH_ELEV:  rd_mux = {c_ef_q, c_er_q};
                    `A_TH_EXTR:  rd_mux = {c_xf_q, c_xr_q};
                    `A_MODE_MAP: rd_mux = {24'd0, c_map_q};
                    `A_LIMITS:   rd_mux = {12'd0, c_retry_q, c_recn_q, c_invl_q};
                    `A_RTCNT:    rd_mux = {12'd0, fails_q, recc_q, invc_q};
                    `A_WD:       rd_mux = wd_q;
                    default:     rd_mux = 32'd0;
                endcase
            end
        end else begin : g_noread
            assign rd_data = 32'd0;
        end
    endgenerate

endmodule
