// astro_ctrl_tmr.v -- protection boundary of the Astronova controller.
//
// TMR=1: three copies of astro_ctrl_core, three state registers and three
// voters. Each domain computes its next state from its own voted copy of the
// state, so a flip-flop upset in one domain is outvoted immediately and
// overwritten on the next clock edge (voted feedback). Configuration-memory
// upsets in one domain's logic are masked until scrubbing repairs them.
// Outputs are voted once (non-triplicated I/O); register read-back comes from
// domain 0's voted state.
//
// TMR=0: one unprotected copy, for measuring how much the protection buys.
//
// DONT_TOUCH / KEEP stop Vivado from merging the identical domains.

`include "astro_ctrl_defs.vh"

module astro_ctrl_tmr #(
    parameter        TMR            = 1,
    parameter        TMR_ERR_DETECT = 1,
    parameter [3:0]  DEF_CTRL       = 4'h0,
    parameter [23:0] DEF_PRESCALE   = 24'd99_999,
    parameter [31:0] DEF_FRESH_TO   = 32'd180_000,
    parameter [31:0] DEF_DWELL_UP   = 32'd0,
    parameter [31:0] DEF_DWELL_DN   = 32'd600_000,
    parameter [31:0] DEF_SW_TO      = 32'd10_000_000,
    parameter [31:0] DEF_TH_ELEV    = {16'h0140, 16'h0180},
    parameter [31:0] DEF_TH_EXTR    = {16'h0300, 16'h0400},
    parameter [7:0]  DEF_MODE_MAP   = 8'hA8,
    parameter [19:0] DEF_LIMITS     = 20'h3_03_03
) (
    input  wire            clk,
    input  wire            rst,

    input  wire            wr_en,
    input  wire [5:0]      wr_addr,
    input  wire [31:0]     wr_data,
    input  wire [5:0]      rd_addr,
    output wire [31:0]     rd_data,

    input  wire            sw_ack,
    input  wire [1:0]      pl_mode,
    output wire            sw_req,
    output wire [1:0]      sw_target,
    output wire [1:0]      mode_cmd,
    output wire [1:0]      threat_level,
    output wire            fallback,
    output wire            fault,
    output wire            busy,
    output wire [`NEV-1:0] events,
    output wire            tmr_err
);

    localparam W  = `ASTRO_ST_W;
    localparam OW = `ASTRO_OUT_W;

    wire [OW-1:0] out_v;

    generate
        if (TMR != 0) begin : g_tmr
            wire [3*W-1:0]  st_all;
            wire [3*OW-1:0] out_all;
            /* verilator lint_off UNUSEDSIGNAL */   // only domain 0 serves read-back
            wire [3*32-1:0] rd_all;
            /* verilator lint_on UNUSEDSIGNAL */

            genvar g;
            for (g = 0; g < 3; g = g + 1) begin : g_dom
                wire [W-1:0]  st_v;
                wire [W-1:0]  st_d;
                (* DONT_TOUCH = "yes", KEEP = "yes" *)
                reg  [W-1:0]  st_r;

                (* DONT_TOUCH = "yes", keep_hierarchy = "yes" *)
                tmr_voter #(.W(W)) u_vote (
                    .a(st_all[0 +: W]), .b(st_all[W +: W]), .c(st_all[2*W +: W]),
                    .y(st_v)
                );

                (* DONT_TOUCH = "yes", keep_hierarchy = "yes" *)
                astro_ctrl_core #(
                    .HAS_READ(g == 0), .BUILD_TMR(8'd1),
                    .DEF_CTRL(DEF_CTRL), .DEF_PRESCALE(DEF_PRESCALE),
                    .DEF_FRESH_TO(DEF_FRESH_TO), .DEF_DWELL_UP(DEF_DWELL_UP),
                    .DEF_DWELL_DN(DEF_DWELL_DN), .DEF_SW_TO(DEF_SW_TO),
                    .DEF_TH_ELEV(DEF_TH_ELEV), .DEF_TH_EXTR(DEF_TH_EXTR),
                    .DEF_MODE_MAP(DEF_MODE_MAP), .DEF_LIMITS(DEF_LIMITS)
                ) u_core (
                    .rst(rst), .st_q(st_v), .st_d(st_d),
                    .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
                    .rd_addr(rd_addr), .rd_data(rd_all[g*32 +: 32]),
                    .sw_ack(sw_ack), .pl_mode(pl_mode),
                    .out(out_all[g*OW +: OW])
                );

                always @(posedge clk) st_r <= st_d;

                assign st_all[g*W +: W] = st_r;
            end

            (* DONT_TOUCH = "yes", keep_hierarchy = "yes" *)
            tmr_voter #(.W(OW)) u_out_vote (
                .a(out_all[0 +: OW]), .b(out_all[OW +: OW]), .c(out_all[2*OW +: OW]),
                .y(out_v)
            );

            assign rd_data = rd_all[0 +: 32];

            if (TMR_ERR_DETECT != 0) begin : g_err
                assign tmr_err = |((st_all[0 +: W] ^ st_all[W +: W]) |
                                   (st_all[0 +: W] ^ st_all[2*W +: W]));
            end else begin : g_noerr
                assign tmr_err = 1'b0;
            end
        end else begin : g_simplex
            wire [W-1:0] st_d;
            reg  [W-1:0] st_r;

            astro_ctrl_core #(
                .HAS_READ(1), .BUILD_TMR(8'd0),
                .DEF_CTRL(DEF_CTRL), .DEF_PRESCALE(DEF_PRESCALE),
                .DEF_FRESH_TO(DEF_FRESH_TO), .DEF_DWELL_UP(DEF_DWELL_UP),
                .DEF_DWELL_DN(DEF_DWELL_DN), .DEF_SW_TO(DEF_SW_TO),
                .DEF_TH_ELEV(DEF_TH_ELEV), .DEF_TH_EXTR(DEF_TH_EXTR),
                .DEF_MODE_MAP(DEF_MODE_MAP), .DEF_LIMITS(DEF_LIMITS)
            ) u_core (
                .rst(rst), .st_q(st_r), .st_d(st_d),
                .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
                .rd_addr(rd_addr), .rd_data(rd_data),
                .sw_ack(sw_ack), .pl_mode(pl_mode),
                .out(out_v)
            );

            always @(posedge clk) st_r <= st_d;

            assign tmr_err = 1'b0;
        end
    endgenerate

    assign {events, busy, fault, fallback, threat_level, mode_cmd, sw_target, sw_req} = out_v;

endmodule

