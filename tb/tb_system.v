// tb_system.v -- controller (Block 3) + switchable payload (Block 4) together,
// connected exactly as on the board, driven over AXI4-Lite.
//
// Compile with one of -DVAR_SWITCH (default) / -DVAR_STATIC / -DVAR_BASE.
// Plusargs from python/astronova/payload.py: +A_SEED +A_N +A_SIG +A_ACC +A_LFSR
// (run A, also reused by run C) and +B_SEED ... (run B).
//
//   Run A  clean run. For SWITCHABLE, random telemetry and policy changes switch
//          the payload through all four modes during the run. The final
//          workload state must equal the golden model: no switch may corrupt
//          the computation.
//   Run B  the same with upsets injected where the protection must hide them:
//          any replica while in TMR, inactive replicas otherwise, plus one DMR
//          detection check. The final state must still be golden.
//   Run C  negative control: an upset the variant cannot mask (replica 0 in
//          SIMPLEX / BASELINE, the same bit in two replicas for STATIC_TMR).
//          The final state must differ from golden, which shows that runs A
//          and B could have failed.

`timescale 1ns/1ps
`include "astro_ctrl_defs.vh"

`ifdef VAR_STATIC
  `define PL_VARIANT 1
`elsif VAR_BASE
  `define PL_VARIANT 0
`else
  `define PL_VARIANT 2
  `define VAR_SWITCH
`endif

module tb_system;

    localparam VARIANT = `PL_VARIANT;
    localparam [1:0] BASE = 2'd0, DMR = 2'd1, TMRM = 2'd2, TMRP = 2'd3;

    // controller registers
    localparam [8:0] C_CTRL = 9'h008, C_CMD = 9'h00C, C_TDATA = 9'h020, C_TCRC = 9'h024, C_PRESCALE = 9'h028,
                     C_FRESH = 9'h02C, C_DWUP = 9'h030, C_DWDN = 9'h034, C_SWTO = 9'h038,
                     C_MAP = 9'h044, C_LIMITS = 9'h048, C_SW_DONE = 9'h094, C_SW_FAIL = 9'h098,
                     C_MISMATCH = 9'h09C, C_LAST_LAT = 9'h0A4, C_MAX_LAT = 9'h0A8;
    // payload registers (address bit 8 selects the payload)
    localparam [8:0] P_ID = 9'h100, P_VERSION = 9'h104, P_CTRL = 9'h108, P_CMD = 9'h10C,
                     P_SEED = 9'h110, P_STOP = 9'h114, P_STATUS = 9'h118, P_CNT = 9'h11C,
                     P_SIG = 9'h120, P_ACC = 9'h124, P_LFSR = 9'h128, P_DMR = 9'h12C,
                     P_TMR = 9'h130, P_SWITCHES = 9'h134, P_STICKY = 9'h138, P_MODE_CYC = 9'h140;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg aresetn = 1'b0;

    // ------------------------------------------------------------------
    // AXI master + address decode
    // ------------------------------------------------------------------
    reg  [8:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 4'hF;

    wire        c_awready, c_wready, c_bvalid, c_arready, c_rvalid;
    wire        p_awready, p_wready, p_bvalid, p_arready, p_rvalid;
    wire [1:0]  c_bresp, p_bresp, c_rresp, p_rresp;
    wire [31:0] c_rdata, p_rdata;

    wire wsel = awaddr[8], rsel = araddr[8];
    wire awready = wsel ? p_awready : c_awready;
    wire wready  = wsel ? p_wready  : c_wready;
    wire bvalid  = wsel ? p_bvalid  : c_bvalid;
    wire arready = rsel ? p_arready : c_arready;
    wire rvalid  = rsel ? p_rvalid  : c_rvalid;
    wire [31:0] rdata = rsel ? p_rdata : c_rdata;

    wire       sw_req, sw_ack, fallback, fault, sw_window, c_tmr_err;
    wire [1:0] sw_target, pl_mode, mode_cmd, threat_level;
    wire       done, p_tmr_err, p_dmr_err;

    astro_ctrl_axil #(
        .TMR(1), .DEF_PRESCALE(24'd0), .DEF_FRESH_TO(32'd400),
        .DEF_DWELL_DN(32'd300), .DEF_SW_TO(32'd100)
    ) u_ctrl (
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr[7:0]), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid && !wsel),
        .s_axi_awready(c_awready), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid && !wsel), .s_axi_wready(c_wready), .s_axi_bresp(c_bresp),
        .s_axi_bvalid(c_bvalid), .s_axi_bready(bready && !wsel), .s_axi_araddr(araddr[7:0]),
        .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid && !rsel), .s_axi_arready(c_arready),
        .s_axi_rdata(c_rdata), .s_axi_rresp(c_rresp), .s_axi_rvalid(c_rvalid),
        .s_axi_rready(rready && !rsel),
        .sw_req(sw_req), .sw_target(sw_target), .sw_ack(sw_ack), .pl_mode(pl_mode),
        .mode_cmd(mode_cmd), .threat_level(threat_level), .fallback(fallback),
        .fault(fault), .sw_window(sw_window), .tmr_err(c_tmr_err)
    );

    pl_axil #(.VARIANT(VARIANT), .DEF_MODE(TMRM)) u_pl (
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr[7:0]), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid && wsel),
        .s_axi_awready(p_awready), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid && wsel), .s_axi_wready(p_wready), .s_axi_bresp(p_bresp),
        .s_axi_bvalid(p_bvalid), .s_axi_bready(bready && wsel), .s_axi_araddr(araddr[7:0]),
        .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid && rsel), .s_axi_arready(p_arready),
        .s_axi_rdata(p_rdata), .s_axi_rresp(p_rresp), .s_axi_rvalid(p_rvalid),
        .s_axi_rready(rready && rsel),
        .sw_req(sw_req), .sw_target(sw_target), .sw_ack(sw_ack), .pl_mode(pl_mode),
        .done(done), .tmr_err(p_tmr_err), .dmr_err(p_dmr_err)
    );

    task axi_write(input [8:0] addr, input [31:0] data);
        reg aw_ok, w_ok;
        begin
            @(negedge clk);
            awaddr = addr; awvalid = 1'b1; wdata = data; wvalid = 1'b1; bready = 1'b1;
            aw_ok = 1'b0; w_ok = 1'b0;
            while (!(aw_ok && w_ok)) begin
                if (awvalid && awready) aw_ok = 1'b1;
                if (wvalid && wready)   w_ok  = 1'b1;
                @(negedge clk);
                if (aw_ok) awvalid = 1'b0;
                if (w_ok)  wvalid  = 1'b0;
            end
            while (!bvalid) @(negedge clk);
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    task axi_read(input [8:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            araddr = addr; arvalid = 1'b1; rready = 1'b1;
            while (!arready) @(negedge clk);
            @(negedge clk);
            arvalid = 1'b0;
            while (!rvalid) @(negedge clk);
            data = rdata;
            @(negedge clk);
            rready = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Checks and monitors
    // ------------------------------------------------------------------
    integer errors = 0, checks = 0, cycle = 0;
    reg     prev_req = 1'b0, prev_ack = 1'b0;
    reg [1:0] prev_tgt = 2'd0;

    task check(input cond, input [8*80-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL @%0d: %0s", cycle, msg);
            end
        end
    endtask

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (aresetn) begin
            if (sw_req && prev_req && sw_target !== prev_tgt) begin
                errors = errors + 1; $display("  FAIL @%0d: M1 target changed during request", cycle);
            end
            if (sw_req && !prev_req && prev_ack) begin
                errors = errors + 1; $display("  FAIL @%0d: M2 request while ack high", cycle);
            end
            if (sw_ack && !prev_ack && pl_mode !== sw_target && VARIANT == 2) begin
                errors = errors + 1; $display("  FAIL @%0d: payload acked in the wrong mode", cycle);
            end
        end
        prev_req <= sw_req;
        prev_ack <= sw_ack;
        prev_tgt <= sw_target;
    end

    // ------------------------------------------------------------------
    // Telemetry
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

    reg [7:0] seq = 8'd0;
    task send(input [15:0] metric);
        reg [31:0] w;
        begin
            seq = seq + 8'd1;
            w = {7'd0, 1'b1, seq, metric};
            axi_write(C_TDATA, w);
            axi_write(C_TCRC, {24'd0, crc8_32(w)});
        end
    endtask

    // ------------------------------------------------------------------
    // Upset injection into the payload replicas
    // ------------------------------------------------------------------
    integer n_inj = 0;

    task flip(input integer rep, input integer b);
        begin
`ifdef VAR_SWITCH
            case (rep)
                0: u_pl.u_pl.g_switch.g_rep[0].st_r[b] = ~u_pl.u_pl.g_switch.g_rep[0].st_r[b];
                1: u_pl.u_pl.g_switch.g_rep[1].st_r[b] = ~u_pl.u_pl.g_switch.g_rep[1].st_r[b];
                default: u_pl.u_pl.g_switch.g_rep[2].st_r[b] = ~u_pl.u_pl.g_switch.g_rep[2].st_r[b];
            endcase
`elsif VAR_STATIC
            case (rep)
                0: u_pl.u_pl.g_static.g_rep[0].st_r[b] = ~u_pl.u_pl.g_static.g_rep[0].st_r[b];
                1: u_pl.u_pl.g_static.g_rep[1].st_r[b] = ~u_pl.u_pl.g_static.g_rep[1].st_r[b];
                default: u_pl.u_pl.g_static.g_rep[2].st_r[b] = ~u_pl.u_pl.g_static.g_rep[2].st_r[b];
            endcase
`else
            u_pl.u_pl.g_base.st_r[b] = ~u_pl.u_pl.g_base.st_r[b];
`endif
            n_inj = n_inj + 1;
        end
    endtask

    // Background injector for run B: one upset every 3-10 cycles, only where the
    // protection must hide it.
    reg     inj_on = 1'b0;
    integer inj_wait = 0, rep;
    always @(negedge clk) begin
        if (inj_on && !done) begin
            if (inj_wait > 0) inj_wait = inj_wait - 1;
            else begin
                inj_wait = 3 + ($urandom % 8);
                if (VARIANT == 1 || pl_mode[1])  rep = $urandom % 3;          // TMR: any replica
                else if (pl_mode == DMR)         rep = 2;                     // inactive replica
                else                             rep = 1 + ($urandom % 2);    // SIMPLEX: 1 or 2
                if (VARIANT != 0) flip(rep, $urandom % 128);
            end
        end
    end

    // ------------------------------------------------------------------
    // Run helpers
    // ------------------------------------------------------------------
    reg [31:0] a_seed, b_seed, a_sig, a_acc, a_lfsr, b_sig, b_acc, b_lfsr;
    integer    a_n, b_n;
    reg [31:0] rd, rd2, cnt, sig, acc, lfsr;
    integer    i, k, wu;

    task start_run(input [31:0] s, input integer n);
        begin
            axi_write(P_CTRL, 32'd0);
            axi_write(P_SEED, s);
            axi_write(P_STOP, n);
            axi_write(P_CMD, 32'd3);                 // clear workload + diagnostics
            axi_write(P_CTRL, 32'd1);                // run
        end
    endtask

    task read_result;
        begin
            axi_read(P_CNT, cnt); axi_read(P_SIG, sig);
            axi_read(P_ACC, acc); axi_read(P_LFSR, lfsr);
        end
    endtask

    // random activity that keeps the controller switching the payload
    reg [1:0] rnd_mode;
    task stir;
        begin
            rnd_mode = $urandom % 4;
            case ($urandom % 10)
                0, 1, 2, 3: send(16'h0100);                       // NORMAL   -> BASELINE
                4, 5:       send(16'h0200);                       // ELEVATED -> TMR
                6:          send(16'h0500);                       // EXTREME  -> TMR_PLUS
                7:          axi_write(C_CTRL, {28'd0, DMR, 2'b10});   // static DMR
                8:          axi_write(C_CTRL, {28'd0, rnd_mode, 2'b10});
                default:    axi_write(C_CTRL, 32'd0);             // adaptive
            endcase
            repeat ($urandom % 30) @(posedge clk);
        end
    endtask

    task policy_for_variant;
        begin
            if (VARIANT == 1)      axi_write(C_CTRL, {28'd0, TMRM, 2'b10});   // P1
            else if (VARIANT == 0) axi_write(C_CTRL, {28'd0, BASE, 2'b10});   // P0
            else                   axi_write(C_CTRL, 32'd0);                  // adaptive
        end
    endtask

    // hold the payload in TMR and wait until no switch is in flight
    task settle_tmr;
        begin
            axi_write(C_CTRL, {28'd0, TMRM, 2'b10});
            wu = 0;
            while (!(pl_mode == TMRM && mode_cmd == TMRM && !sw_window && !sw_ack) && wu < 500) begin
                @(posedge clk); wu = wu + 1;
            end
            check(pl_mode == TMRM && !sw_window, "settled in TMR");
        end
    endtask

    task wait_done;
        begin
            wu = 0;
            while (!done && wu < 200000) begin @(posedge clk); wu = wu + 1; end
            check(done, "workload reached STOP_AT");
        end
    endtask

    // ------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("A_SEED=%h", a_seed) || !$value$plusargs("A_N=%d", a_n) ||
            !$value$plusargs("A_SIG=%h", a_sig) || !$value$plusargs("A_ACC=%h", a_acc) ||
            !$value$plusargs("A_LFSR=%h", a_lfsr) || !$value$plusargs("B_SEED=%h", b_seed) ||
            !$value$plusargs("B_N=%d", b_n) || !$value$plusargs("B_SIG=%h", b_sig) ||
            !$value$plusargs("B_ACC=%h", b_acc) || !$value$plusargs("B_LFSR=%h", b_lfsr)) begin
            $display("FAIL: golden plusargs missing (see Makefile target 'system')");
            $finish;
        end
        repeat (4) @(posedge clk);
        @(negedge clk); aresetn = 1'b1;

        $display("[%0d] S0 identification and reset state (variant %0d)", cycle, VARIANT);
        axi_read(P_ID, rd);      check(rd == 32'h504C4430, "payload ID");
        axi_read(P_VERSION, rd); check(rd[23:16] == VARIANT, "payload VERSION reports variant");
        repeat (20) @(posedge clk);
        check(pl_mode == ((VARIANT == 0) ? BASE : TMRM), "payload reset mode");

        // controller: 2 cycles/tick, short dwell so the payload switches often
        axi_write(C_PRESCALE, 32'd1);
        axi_write(C_FRESH, 32'd400);
        axi_write(C_DWUP, 32'd0);
        axi_write(C_DWDN, 32'd20);
        axi_write(C_SWTO, 32'd60);
        axi_write(C_MAP, {24'd0, TMRM, TMRP, TMRM, BASE});       // FB, X, E, N
        axi_write(C_LIMITS, 32'h0003_0101);                      // retry 3, recover 1, invalid 1
        policy_for_variant;
        axi_write(C_CMD, 32'd5);           // clear the start-up fault (BASELINE) and counters
        send(16'h0100);
        repeat (50) @(posedge clk);

        // Run A -------------------------------------------------------------
        $display("[%0d] Run A: clean run, %0d iterations", cycle, a_n);
        if (VARIANT == 2) settle_tmr;
        axi_read(C_SW_DONE, rd2);
        start_run(a_seed, a_n);
        while (!done) begin
            if (VARIANT == 2) stir;
            else repeat (50) @(posedge clk);
        end
        if (VARIANT == 2) settle_tmr;
        read_result;
        check(cnt == a_n, "run A: iteration count");
        check(sig == a_sig && acc == a_acc && lfsr == a_lfsr, "run A: final state equals golden");
        if (VARIANT == 2) begin
            axi_read(P_SWITCHES, rd);
            axi_read(C_SW_DONE, k);
            $display("    payload mode switches during run A: %0d (controller completed %0d)", rd, k - rd2);
            check(rd >= 20, "run A: at least 20 mode switches during the run");
            check(rd == k - rd2, "run A: every controller switch applied exactly once by the payload");
            for (i = 0; i < 4; i = i + 1) begin
                axi_read(P_MODE_CYC + 4 * i, rd);
                $display("    cycles in mode %0d: %0d", i, rd);
                check(rd > 0, "run A: every mode used during the run");
            end
            policy_for_variant;
            axi_read(C_LAST_LAT, rd); axi_read(C_MAX_LAT, rd2);
            $display("    Level-1 switch latency (controller LAST_LAT / MAX_LAT): %0d / %0d cycles", rd, rd2);
            check(rd == 2 && rd2 == 2, "Level-1 switch completes in 2 cycles");
        end
        axi_read(C_SW_FAIL, rd);   check(rd == 0, "no failed switches");
        axi_read(C_MISMATCH, rd);  check(rd == 0, "no payload mode mismatches");
        check(fault == 1'b0, "controller not in FAULT");

        // Run B -------------------------------------------------------------
        if (VARIANT != 0) begin
            $display("[%0d] Run B: upsets the protection must hide, %0d iterations", cycle, b_n);
            start_run(b_seed, b_n);
            if (VARIANT == 2) begin
                // DMR detection: corrupt replica 1 while in DMR, then go to TMR
                axi_write(C_CTRL, {28'd0, DMR, 2'b10});
                wu = 0;
                while (pl_mode != DMR && wu < 200) begin @(posedge clk); wu = wu + 1; end
                @(negedge clk); flip(1, 77);
                repeat (5) @(posedge clk);
                axi_read(P_STICKY, rd); check(rd[0] == 1'b1, "DMR mismatch detected");
                axi_write(C_CTRL, {28'd0, TMRM, 2'b10});
                repeat (10) @(posedge clk);
                axi_write(C_CTRL, 32'd0);
            end
            inj_on = 1'b1;
            while (!done) begin
                if (VARIANT == 2) stir;
                else repeat (50) @(posedge clk);
            end
            inj_on = 1'b0;
            policy_for_variant;
            read_result;
            $display("    %0d upsets injected", n_inj);
            check(cnt == b_n, "run B: iteration count");
            check(sig == b_sig && acc == b_acc && lfsr == b_lfsr, "run B: final state equals golden despite upsets");
            axi_read(P_TMR, rd); check(rd > 0, "run B: TMR disagreements observed and corrected");
        end

        // Run C (negative control) ------------------------------------------
        $display("[%0d] Run C: negative control, an upset the variant cannot mask", cycle);
        if (VARIANT == 2) begin
            axi_write(C_CTRL, {28'd0, BASE, 2'b10});
            wu = 0;
            while (pl_mode != BASE && wu < 200) begin @(posedge clk); wu = wu + 1; end
        end
        start_run(a_seed, a_n);
        repeat (a_n / 2) @(posedge clk);
        @(negedge clk);
        flip(0, 40);
        if (VARIANT == 1) flip(1, 40);                 // same bit in two replicas
        wait_done;
        read_result;
        check(sig != a_sig || acc != a_acc, "run C: unmasked upset corrupts the result (checker is live)");

        $display("");
        if (errors == 0)
            $display("PASS: tb_system variant %0d, %0d checks, %0d cycles", VARIANT, checks, cycle);
        else
            $display("FAIL: tb_system variant %0d, %0d of %0d checks failed", VARIANT, errors, checks);
        $finish;
    end

    initial begin
        #(10 * 3000000);
        $display("FAIL: tb_system timeout");
        $finish;
    end

endmodule
