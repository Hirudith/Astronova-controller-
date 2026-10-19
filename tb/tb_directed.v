// tb_directed.v -- directed verification of the Astronova controller through
// its AXI4-Lite top level, against a behavioural switchable payload.
//
// Gate G1 cases: T4 stale, T5 invalid, T6 rapid-toggle, T7 reset-during-switch.
// Also: power-up safety, hysteresis and dwell, switch watchdog / fault,
// payload mode mismatch, static policies, hold-last-mode fallback (D6), voted
// state upsets, illegal-state recovery and AXI error handling.
//
// Protocol monitors run throughout:
//   M1 sw_target is stable while sw_req is high
//   M2 sw_req only rises after a cycle with sw_ack low (4-phase handshake)
//   M3 (when armed) no de-escalation earlier than DWELL_DN after the last switch
//   M4 outputs never X/Z after the first reset

`timescale 1ns/1ps
`include "astro_ctrl_defs.vh"

module tb_directed;

    // byte offsets
    localparam [7:0] R_ID = 8'h00, R_VERSION = 8'h04, R_CTRL = 8'h08, R_CMD = 8'h0C,
                     R_STATUS = 8'h10, R_TSTAT = 8'h14, R_AGE = 8'h18, R_DWELL = 8'h1C,
                     R_TDATA = 8'h20, R_TCRC = 8'h24, R_PRESCALE = 8'h28, R_FRESH_TO = 8'h2C,
                     R_DWELL_UP = 8'h30, R_DWELL_DN = 8'h34, R_SW_TO = 8'h38,
                     R_TH_ELEV = 8'h3C, R_TH_EXTR = 8'h40, R_MODE_MAP = 8'h44,
                     R_LIMITS = 8'h48, R_RTCNT = 8'h4C,
                     R_C_ACCEPT = 8'h80, R_C_REJECT = 8'h84, R_C_FB_ENTER = 8'h88,
                     R_C_SW_DONE = 8'h94, R_C_SW_FAIL = 8'h98, R_C_MISMATCH = 8'h9C,
                     R_C_ILLEGAL = 8'hA0, R_LAST_LAT = 8'hA4, R_TMR_ERR = 8'hAC,
                     R_STICKY = 8'hB8;

    localparam [1:0] BASE = 2'd0, PART = 2'd1, TMRM = 2'd2, TMRP = 2'd3;

    // state-vector bit positions (see the pack order in astro_ctrl_core.v)
    localparam FSM_LSB = 208, CUR_LSB = 42;

    // sim-scale defaults: 1 cycle per tick until PRESCALE is written
    localparam DEF_FRESH = 400, DEF_DWDN = 300, DEF_SWTO = 100;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg aresetn = 1'b0;

    reg  [7:0]  s_axi_awaddr = 0, s_axi_araddr = 0;
    reg         s_axi_awvalid = 0, s_axi_wvalid = 0, s_axi_bready = 0;
    reg         s_axi_arvalid = 0, s_axi_rready = 0;
    reg  [31:0] s_axi_wdata = 0;
    reg  [3:0]  s_axi_wstrb = 0;
    wire        s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
    wire [1:0]  s_axi_bresp, s_axi_rresp;
    wire [31:0] s_axi_rdata;

    wire        sw_req, fallback, fault, sw_window, tmr_err;
    wire [1:0]  sw_target, mode_cmd, threat_level;
    reg         pl_ack = 1'b0;
    reg  [1:0]  pl_mode = BASE;

    astro_ctrl_axil #(
        .TMR(1), .DEF_PRESCALE(24'd0), .DEF_FRESH_TO(DEF_FRESH),
        .DEF_DWELL_DN(DEF_DWDN), .DEF_SW_TO(DEF_SWTO)
    ) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(3'd0), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .sw_req(sw_req), .sw_target(sw_target), .sw_ack(pl_ack), .pl_mode(pl_mode),
        .mode_cmd(mode_cmd), .threat_level(threat_level), .fallback(fallback),
        .fault(fault), .sw_window(sw_window), .tmr_err(tmr_err)
    );

    // ------------------------------------------------------------------
    // Behavioural switchable payload (Level-1 style: switch + resync, then ack)
    // ------------------------------------------------------------------
    integer    pl_lat = 6;        // cycles from sw_req to sw_ack
    integer    pl_rel = 1;        // cycles from sw_req low to sw_ack low
    reg        pl_noack = 1'b0;   // never finishes a switch
    reg        pl_stuck = 1'b0;   // never drops sw_ack
    reg        pl_wrong = 1'b0;   // acks in the wrong mode
    reg        pl_busy = 1'b0;
    reg  [1:0] pl_tgt = 2'd0;
    integer    pl_cnt = 0, pl_rcnt = 0;

    always @(posedge clk) begin
        if (!pl_busy && !pl_ack && sw_req) begin
            pl_busy <= 1'b1;
            pl_tgt  <= sw_target;
            pl_cnt  <= pl_lat;
        end
        if (pl_busy) begin
            if (pl_cnt > 1) pl_cnt <= pl_cnt - 1;
            else if (!pl_noack) begin
                // a switch that was started is completed even if sw_req drops
                pl_busy <= 1'b0;
                pl_mode <= pl_wrong ? pl_tgt ^ 2'b01 : pl_tgt;
                pl_ack  <= 1'b1;
            end
        end
        if (pl_ack && !sw_req && !pl_stuck) begin
            if (pl_rcnt + 1 >= pl_rel) begin pl_ack <= 1'b0; pl_rcnt <= 0; end
            else pl_rcnt <= pl_rcnt + 1;
        end else begin
            pl_rcnt <= 0;
        end
    end

    // ------------------------------------------------------------------
    // Bookkeeping and monitors
    // ------------------------------------------------------------------
    integer errors = 0, checks = 0, cycle = 0, wu_i;
    integer cpt = 1;                        // clock cycles per tick
    integer dwell_dn_ticks = DEF_DWDN;
    reg     mon_dwell = 1'b0, seen_reset = 1'b0;
    reg     prev_req = 1'b0, prev_ack = 1'b0;
    reg [1:0] prev_tgt = 2'd0, prev_mode = 2'd0;
    integer last_change = 0, n_mode_changes = 0;

    task fail(input [8*72-1:0] msg);
        begin
            errors = errors + 1;
            $display("  FAIL @%0d: %0s", cycle, msg);
        end
    endtask

    task check(input cond, input [8*72-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) fail(msg);
        end
    endtask

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (aresetn) seen_reset <= 1'b1;
        if (seen_reset && aresetn) begin
            if (sw_req && prev_req && sw_target !== prev_tgt) fail("M1: sw_target changed while sw_req high");
            if (sw_req && !prev_req && prev_ack)               fail("M2: sw_req rose while sw_ack high");
            if (^{sw_req, sw_target, mode_cmd, threat_level, fallback, fault, sw_window} === 1'bx)
                fail("M4: X/Z on controller outputs");
            if (mode_cmd != prev_mode) begin
                if (mon_dwell && mode_cmd < prev_mode && (cycle - last_change) < dwell_dn_ticks * cpt)
                    fail("M3: de-escalated before DWELL_DN");
                last_change    = cycle;
                n_mode_changes = n_mode_changes + 1;
            end
        end
        prev_req  <= sw_req;
        prev_ack  <= pl_ack;
        prev_tgt  <= sw_target;
        prev_mode <= mode_cmd;
    end

    // ------------------------------------------------------------------
    // AXI4-Lite master tasks (inputs change on the falling edge)
    // ------------------------------------------------------------------
    reg [1:0] last_bresp;

    task axi_write_s(input [7:0] addr, input [31:0] data, input [3:0] strb);
        reg aw_ok, w_ok;
        begin
            @(negedge clk);
            s_axi_awaddr = addr; s_axi_awvalid = 1'b1;
            s_axi_wdata  = data; s_axi_wstrb = strb; s_axi_wvalid = 1'b1;
            s_axi_bready = 1'b1;
            aw_ok = 1'b0; w_ok = 1'b0;
            while (!(aw_ok && w_ok)) begin
                if (s_axi_awvalid && s_axi_awready) aw_ok = 1'b1;
                if (s_axi_wvalid && s_axi_wready)   w_ok  = 1'b1;
                @(negedge clk);
                if (aw_ok) s_axi_awvalid = 1'b0;
                if (w_ok)  s_axi_wvalid  = 1'b0;
            end
            while (!s_axi_bvalid) @(negedge clk);
            last_bresp = s_axi_bresp;
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task axi_write(input [7:0] addr, input [31:0] data);
        axi_write_s(addr, data, 4'hF);
    endtask

    task axi_read(input [7:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            s_axi_araddr = addr; s_axi_arvalid = 1'b1; s_axi_rready = 1'b1;
            while (!s_axi_arready) @(negedge clk);
            @(negedge clk);
            s_axi_arvalid = 1'b0;
            while (!s_axi_rvalid) @(negedge clk);
            data = s_axi_rdata;
            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Telemetry helpers
    // ------------------------------------------------------------------
    function [7:0] crc8_32(input [31:0] d);
        integer i;
        reg [7:0] c;
        begin
            c = 8'h00;
            for (i = 31; i >= 0; i = i - 1)
                c = (c[7] ^ d[i]) ? ({c[6:0], 1'b0} ^ 8'h07) : {c[6:0], 1'b0};
            crc8_32 = c;
        end
    endfunction

    reg [7:0] seq = 8'd0;        // last sequence number sent
    reg [7:0] acc_seq = 8'd0;    // last sequence number the controller accepted

    // kind: 0 valid, 1 bad CRC, 2 reserved bit, 3 source not ok, 4 replay, 5 old seq
    task send_kind(input [15:0] metric, input integer kind);
        reg [31:0] w;
        reg [7:0]  s;
        reg [7:0]  crc;
        begin
            if (kind == 4)      s = acc_seq;           // replay of the last accepted message
            else if (kind == 5) s = acc_seq - 8'd5;    // older message
            else begin seq = seq + 8'd1; s = seq; end
            if (kind == 0) acc_seq = s;
            w = {7'd0, (kind == 3) ? 1'b0 : 1'b1, s, metric};
            if (kind == 2) w[30] = 1'b1;
            crc = crc8_32(w);
            if (kind == 1) crc = crc ^ 8'h10;
            axi_write(R_TDATA, w);
            axi_write(R_TCRC, {24'd0, crc});
        end
    endtask

    task send(input [15:0] metric);
        send_kind(metric, 0);
    endtask

    task wait_cycles(input integer n);
        integer i;
        for (i = 0; i < n; i = i + 1) @(posedge clk);
    endtask

    // wait until the payload runs `m`, the controller commands `m` and is idle
    task wait_mode(input [1:0] m, input integer maxc, input [8*72-1:0] msg);
        begin
            wu_i = 0;
            while (!(pl_mode == m && mode_cmd == m && !sw_window && !pl_ack) && wu_i < maxc) begin
                @(posedge clk);
                wu_i = wu_i + 1;
            end
            check(pl_mode == m && mode_cmd == m, msg);
        end
    endtask

    task hard_reset(input integer n);
        begin
            @(negedge clk); aresetn = 1'b0;
            wait_cycles(n);
            @(negedge clk); aresetn = 1'b1;
            seq = 8'd0; acc_seq = 8'd0; cpt = 1; dwell_dn_ticks = DEF_DWDN;
        end
    endtask

    // config used by most tests (2 cycles per tick)
    task base_config;
        begin
            axi_write(R_PRESCALE, 32'd1);           cpt = 2;
            axi_write(R_FRESH_TO, 32'd150);
            axi_write(R_DWELL_UP, 32'd0);
            axi_write(R_DWELL_DN, 32'd100);         dwell_dn_ticks = 100;
            axi_write(R_SW_TO,    32'd60);
            axi_write(R_TH_ELEV,  {16'h0140, 16'h0180});
            axi_write(R_TH_EXTR,  {16'h0300, 16'h0400});
            axi_write(R_MODE_MAP, {24'd0, TMRM, TMRP, TMRM, BASE});   // FB,X,E,N
            axi_write(R_LIMITS,   32'h0003_0303);   // retry 3, recover 3, invalid 3
            axi_write(R_CTRL,     32'd0);
            axi_write(R_CMD,      32'd4);           // clear diagnostics
        end
    endtask

    // bring the controller to NORMAL / BASELINE with fresh telemetry
    task settle_normal;
        begin
            send(16'h0100); send(16'h0100); send(16'h0100);
            wait_mode(BASE, 4 * dwell_dn_ticks * cpt, "settle: reached BASELINE");
        end
    endtask

    reg [31:0] rd, rd2;
    integer    i, k, t0, t1, n_sw;

    task section(input [8*80-1:0] name);
        $display("[%0d] %0s", cycle, name);
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    initial begin
        wait_cycles(4);
        @(negedge clk); aresetn = 1'b1;

        // T1 ------------------------------------------------------------------
        section("T1 power-up: identification, safe-by-default fallback");
        axi_read(R_ID, rd);       check(rd == 32'h41535452, "ID register");
        axi_read(R_VERSION, rd);  check(rd == 32'h0001_0100, "VERSION reports TMR build 1.0");
        axi_read(R_FRESH_TO, rd); check(rd == DEF_FRESH, "FRESH_TO reset default");
        check(fallback == 1'b1, "fallback active after reset with no telemetry");
        wait_mode(TMRM, 200, "payload driven to TMR without any PS action");
        // sw_req high for pl_lat cycles of payload work, plus one cycle for the payload
        // to register sw_req and one for the controller to see sw_ack
        axi_read(R_LAST_LAT, rd); check(rd == pl_lat + 2, "LAST_LAT measures the handshake");

        base_config;

        // T2 ------------------------------------------------------------------
        section("T2 recovery from start-up fallback needs RECOVER_N messages");
        send(16'h0100); send(16'h0100);
        wait_cycles(20);
        check(fallback == 1'b1, "still in fallback after 2 of 3 valid messages");
        send(16'h0100);
        wait_cycles(4);
        check(fallback == 1'b0, "fallback exits after the 3rd valid message");
        wait_mode(BASE, 4 * dwell_dn_ticks * cpt, "relaxes to BASELINE at NORMAL threat");

        // T3 ------------------------------------------------------------------
        section("T3 thresholds, hysteresis and dwell");
        mon_dwell = 1'b1;
        send(16'h0190);                                        // 1.56x >= rise 1.5
        wait_mode(TMRM, 40, "ELEVATED escalates to TMR at once (DWELL_UP = 0)");
        check(threat_level == 2'd1, "threat level ELEVATED");
        t0 = last_change;
        send(16'h0150);                                        // 1.31x: inside the band
        wait_cycles(10);
        check(threat_level == 2'd1, "stays ELEVATED inside the hysteresis band");
        send(16'h0130);                                        // 1.19x < fall 1.25
        wait_cycles(10);
        check(threat_level == 2'd0, "drops to NORMAL below the fall threshold");
        check(mode_cmd == TMRM, "mode held at TMR during the dwell time");
        wait_mode(BASE, 2 * dwell_dn_ticks * cpt, "relaxes to BASELINE after DWELL_DN");
        check(last_change - t0 >= dwell_dn_ticks * cpt, "relaxation respected DWELL_DN");
        send(16'h0480);                                        // 4.5x
        wait_mode(TMRP, 40, "EXTREME selects TMR_PLUS (mode map)");
        check(threat_level == 2'd2, "threat level EXTREME");
        send(16'h0310);                                        // 3.06x: above extreme fall
        wait_cycles(10);
        check(threat_level == 2'd2, "stays EXTREME above its fall threshold");
        send(16'h0200);
        wait_cycles(10);
        check(threat_level == 2'd1, "EXTREME -> ELEVATED");
        wait_mode(TMRM, 2 * dwell_dn_ticks * cpt, "de-escalates one step to TMR after dwell");
        send(16'h0100);
        wait_mode(BASE, 2 * dwell_dn_ticks * cpt, "back to BASELINE");
        mon_dwell = 1'b0;

        // T4 ------------------------------------------------------------------
        section("T4 stale telemetry -> fallback, then recovery");
        axi_read(R_C_FB_ENTER, rd2);
        send(16'h0100);                                        // age restarts here
        t0 = cycle;
        wu_i = 0;
        while (!fallback && wu_i < 1000) begin @(posedge clk); wu_i = wu_i + 1; end
        t1 = cycle - t0;
        check(fallback == 1'b1, "fallback asserted once telemetry stops");
        check(t1 >= 150 * cpt - 20 && t1 <= 150 * cpt + 20, "fallback at FRESH_TO (+-20 cycles)");
        axi_read(R_STATUS, rd);   check(rd[10] == 1'b1, "STATUS.stale set");
        wait_mode(TMRM, 40, "fallback drives TMR immediately (no dwell)");
        axi_read(R_C_FB_ENTER, rd); check(rd == rd2 + 1, "FB_ENTER counted once");
        send(16'h0100); send(16'h0100);
        wait_cycles(10);
        check(fallback == 1'b1, "2 messages are not enough to leave fallback");
        send(16'h0100);
        wait_cycles(4);
        check(fallback == 1'b0, "3 messages leave fallback");
        wait_mode(BASE, 2 * dwell_dn_ticks * cpt, "relaxes after recovery + dwell");

        // T5 ------------------------------------------------------------------
        section("T5 invalid telemetry: CRC, reserved bits, source flag, replay, old seq");
        axi_read(R_C_REJECT, rd2);
        send_kind(16'h0500, 1);  axi_read(R_TSTAT, rd);
        check(rd[28:25] == 4'b0001, "bad CRC rejected (reason CRC)");
        check(threat_level == 2'd0 && mode_cmd == BASE, "rejected message has no effect");
        send(16'h0100);                                        // resets the invalid run
        send_kind(16'h0500, 2);  axi_read(R_TSTAT, rd);
        check(rd[28:25] == 4'b0010, "reserved bit rejected (reason RSVD)");
        send(16'h0100);
        send_kind(16'h0100, 3);  axi_read(R_TSTAT, rd);
        check(rd[28:25] == 4'b0100, "source-not-ok rejected (reason SRC)");
        send(16'h0100);
        send_kind(16'h0500, 4);  axi_read(R_TSTAT, rd);
        check(rd[28:25] == 4'b1000, "replayed sequence rejected (reason SEQ)");
        send(16'h0100);
        send_kind(16'h0500, 5);  axi_read(R_TSTAT, rd);
        check(rd[28:25] == 4'b1000, "older sequence rejected (reason SEQ)");
        axi_read(R_C_REJECT, rd); check(rd == rd2 + 5, "REJECT counter +5");
        check(fallback == 1'b0 && mode_cmd == BASE, "isolated rejects do not trigger fallback");
        send(16'h0100);
        send_kind(16'h0100, 1); send_kind(16'h0100, 3);
        wait_cycles(4);
        check(fallback == 1'b0, "two consecutive rejects: no fallback yet");
        send_kind(16'h0100, 4);
        wait_cycles(4);
        check(fallback == 1'b1, "3 consecutive rejects -> fallback (INVALID_LIMIT)");
        axi_read(R_STATUS, rd);   check(rd[11] == 1'b1 && rd[10] == 1'b0, "STATUS.invalid set, not stale");
        wait_mode(TMRM, 40, "invalid fallback drives TMR");
        settle_normal;
        // invalid messages must not refresh freshness
        axi_write(R_LIMITS, 32'h0003_0300);                    // INVALID_LIMIT = 0 (off)
        send(16'h0100);                                        // age restarts here
        t0 = cycle;
        while (!fallback && cycle - t0 < 2000) send_kind(16'h0100, 1);
        check(fallback == 1'b1, "stream of bad messages still goes stale");
        check(cycle - t0 >= 150 * cpt - 20, "...but not before FRESH_TO");
        axi_write(R_LIMITS, 32'h0003_0303);
        settle_normal;

        // T6 ------------------------------------------------------------------
        section("T6 rapid toggling of the threat input");
        mon_dwell = 1'b1;
        axi_read(R_C_SW_DONE, rd2);
        t0 = cycle;
        for (i = 0; i < 120; i = i + 1)
            send((i % 2) ? 16'h0100 : 16'h0200);               // NORMAL <-> ELEVATED every message
        t1 = cycle - t0;
        axi_read(R_C_SW_DONE, rd);
        n_sw = rd - rd2;
        $display("    %0d toggles in %0d cycles -> %0d switches (bound %0d)",
                 120, t1, n_sw, 2 * (t1 / (dwell_dn_ticks * cpt) + 1));
        check(n_sw <= 2 * (t1 / (dwell_dn_ticks * cpt) + 1), "switch count bounded by dwell");
        check(n_sw >= 2, "controller still follows the threat");
        // toggling inside the hysteresis band never changes the level
        send(16'h0200);
        wait_mode(TMRM, 40, "ELEVATED before band test");
        axi_read(R_C_SW_DONE, rd2);
        for (i = 0; i < 60; i = i + 1)
            send((i % 2) ? 16'h0145 : 16'h017F);               // both within [fall, rise)
        check(threat_level == 2'd1, "level unchanged by toggling inside the band");
        axi_read(R_C_SW_DONE, rd); check(rd == rd2, "no switches while toggling inside the band");
        mon_dwell = 1'b0;
        settle_normal;

        // T7 ------------------------------------------------------------------
        section("T7 reset during a switch (hard reset, offset sweep)");
        pl_lat = 12; pl_rel = 3;
        for (k = 0; k <= 18; k = k + 1) begin
            send(16'h0200);                                    // escalate to TMR
            wu_i = 0;
            while (!sw_req && wu_i < 100) begin @(posedge clk); wu_i = wu_i + 1; end
            wait_cycles(k);
            hard_reset(2);
            // after reset: no telemetry -> fallback -> TMR, no fault, consistent
            wait_mode(TMRM, 200, "after reset-in-switch: TMR");
            check(fault == 1'b0, "after reset-in-switch: no fault");
            axi_read(R_STATUS, rd);
            check(rd[2:0] == 3'd1 && rd[6:5] == rd[17:16], "after reset-in-switch: IDLE, mode_cmd == pl_mode");
            base_config;
            settle_normal;
        end
        section("T7b soft reset (CMD) during a switch");
        for (k = 0; k <= 14; k = k + 2) begin
            send(16'h0200);
            wu_i = 0;
            while (!sw_req && wu_i < 100) begin @(posedge clk); wu_i = wu_i + 1; end
            wait_cycles(k);
            axi_write(R_CMD, 32'd2);
            seq = 8'd0; acc_seq = 8'd0;
            wait_mode(TMRM, 200, "after soft reset in switch: TMR");
            check(fault == 1'b0 && fallback == 1'b1, "after soft reset: fallback, no fault");
            axi_read(R_SW_TO, rd); check(rd == 60, "soft reset keeps configuration");
            settle_normal;
        end
        pl_lat = 6; pl_rel = 1;

        // T8 ------------------------------------------------------------------
        section("T8 unresponsive payload: watchdog, retries, fault, clear");
        axi_read(R_C_SW_FAIL, rd2);
        pl_noack = 1'b1;
        send(16'h0200);
        wu_i = 0;
        while (!fault && wu_i < 2000) begin @(posedge clk); wu_i = wu_i + 1; end
        check(fault == 1'b1, "FAULT after RETRY_MAX failed switches");
        axi_read(R_C_SW_FAIL, rd); check(rd == rd2 + 3, "SW_FAIL counted 3 times");
        axi_read(R_STICKY, rd);    check(rd[1] == 1'b1, "sticky fault flag");
        check(sw_req == 1'b0, "no request held while in FAULT");
        pl_noack = 1'b0;                                       // payload recovers
        wait_cycles(30);
        axi_write(R_CMD, 32'd1);                               // clear fault
        wait_mode(TMRM, 200, "after clear: controller resyncs and reaches TMR");
        check(fault == 1'b0, "fault cleared");
        settle_normal;
        // stuck sw_ack after a switch also trips the watchdog
        pl_stuck = 1'b1;
        send(16'h0200);
        wu_i = 0;
        while (!fault && wu_i < 3000) begin @(posedge clk); wu_i = wu_i + 1; end
        check(fault == 1'b1, "stuck sw_ack leads to FAULT");
        pl_stuck = 1'b0;
        wait_cycles(10);
        axi_write(R_CMD, 32'd1);
        wait_mode(TMRM, 200, "recovers after stuck ack clears");
        settle_normal;

        // T9 ------------------------------------------------------------------
        section("T9 payload mode mismatch");
        axi_read(R_C_SW_FAIL, rd2);
        pl_wrong = 1'b1;
        send(16'h0200);
        wait_cycles(40);
        pl_wrong = 1'b0;
        axi_read(R_C_SW_FAIL, rd); check(rd > rd2, "ack with the wrong mode counts as a failed switch");
        wait_mode(TMRM, 400, "controller retries until the payload is in TMR");
        check(fault == 1'b0, "single wrong-mode ack does not fault");
        // payload leaves the commanded mode on its own (e.g. an upset in its mode logic)
        axi_read(R_C_MISMATCH, rd2);
        @(negedge clk); pl_mode = BASE;
        wait_cycles(30);
        axi_read(R_C_MISMATCH, rd); check(rd == rd2 + 1, "MISMATCH counted");
        check(pl_mode == TMRM && mode_cmd == TMRM, "controller re-asserts TMR");
        settle_normal;

        // T10 -----------------------------------------------------------------
        section("T10 static policies (P0 / P1) over-ride telemetry and fallback");
        axi_write(R_CTRL, {28'd0, BASE, 2'b10});               // static BASELINE
        send(16'h0800);
        wait_cycles(30);
        check(mode_cmd == BASE && pl_mode == BASE, "static BASELINE ignores EXTREME threat");
        wait_cycles(150 * cpt + 40);
        check(fallback == 1'b1 && mode_cmd == BASE, "static BASELINE ignores fallback");
        axi_write(R_CTRL, {28'd0, TMRM, 2'b10});               // static TMR
        wait_mode(TMRM, 40, "static TMR applied immediately");
        axi_write(R_CTRL, 32'd0);                              // adaptive again
        settle_normal;

        // T11 -----------------------------------------------------------------
        section("T11 fallback policy D6 = hold last mode");
        axi_write(R_CTRL, 32'd1);
        wu_i = 0;
        while (!fallback && wu_i < 1000) begin @(posedge clk); wu_i = wu_i + 1; end
        check(fallback == 1'b1, "stale -> fallback");
        wait_cycles(40);
        check(mode_cmd == BASE && pl_mode == BASE, "hold-last-mode keeps BASELINE");
        axi_write(R_CTRL, 32'd0);
        wait_mode(TMRM, 40, "fail-safe policy restores TMR");
        settle_normal;

        // T12 -----------------------------------------------------------------
        section("T12 upsets in the protected state");
        axi_read(R_TMR_ERR, rd2);
        pl_lat = 20;
        send(16'h0200);
        wu_i = 0;
        while (!sw_req && wu_i < 100) begin @(posedge clk); wu_i = wu_i + 1; end
        for (i = 0; i < 8; i = i + 1) begin                    // one replica at a time
            @(negedge clk);
            case (i % 3)
                0: dut.u_ctrl.g_tmr.g_dom[0].st_r[FSM_LSB + (i % 3)] = ~dut.u_ctrl.g_tmr.g_dom[0].st_r[FSM_LSB + (i % 3)];
                1: dut.u_ctrl.g_tmr.g_dom[1].st_r[CUR_LSB]          = ~dut.u_ctrl.g_tmr.g_dom[1].st_r[CUR_LSB];
                2: dut.u_ctrl.g_tmr.g_dom[2].st_r[FSM_LSB + 1]      = ~dut.u_ctrl.g_tmr.g_dom[2].st_r[FSM_LSB + 1];
            endcase
            #1;
            check(sw_req == 1'b1 && tmr_err == 1'b1, "single-replica upset masked and detected");
        end
        pl_lat = 6;
        wait_mode(TMRM, 100, "switch completes despite upsets");
        axi_read(R_TMR_ERR, rd); check(rd >= rd2 + 8, "TMR_ERR counter counts disagreements");
        // two replicas corrupted the same way: illegal FSM code -> recovery via INIT
        axi_read(R_C_ILLEGAL, rd2);
        @(negedge clk);
        dut.u_ctrl.g_tmr.g_dom[0].st_r[FSM_LSB + 2 -: 3] = 3'd7;
        dut.u_ctrl.g_tmr.g_dom[1].st_r[FSM_LSB + 2 -: 3] = 3'd7;
        wait_cycles(5);
        axi_read(R_C_ILLEGAL, rd); check(rd == rd2 + 1, "illegal FSM state detected");
        axi_read(R_STATUS, rd);    check(rd[2:0] == 3'd1, "FSM recovered to IDLE");
        check(mode_cmd == pl_mode, "mode consistent after recovery");
        settle_normal;

        // T13 -----------------------------------------------------------------
        section("T13 AXI: partial writes rejected, unmapped reads return 0");
        axi_read(R_SW_TO, rd2);
        axi_write_s(R_SW_TO, 32'd5, 4'h1);
        check(last_bresp == 2'b10, "partial-strobe write returns SLVERR");
        axi_read(R_SW_TO, rd); check(rd == rd2, "partial-strobe write ignored");
        axi_read(8'hFC, rd);   check(rd == 32'd0, "unmapped read returns 0");
        axi_write(R_SW_TO, 32'd60);
        check(last_bresp == 2'b00, "full write returns OKAY");

        // ---------------------------------------------------------------------
        $display("");
        if (errors == 0)
            $display("PASS: tb_directed, %0d checks, %0d cycles, %0d mode changes", checks, cycle, n_mode_changes);
        else
            $display("FAIL: tb_directed, %0d of %0d checks failed", errors, checks);
        $finish;
    end

    initial begin
        #(10 * 400000);
        $display("FAIL: tb_directed timeout");
        $finish;
    end

endmodule
