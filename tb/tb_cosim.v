// tb_cosim.v -- replay a trace from python/gen_cosim.py and compare the RTL
// with the Python reference model on every cycle (outputs and register
// read-back, which exposes the internal timers and counters).
//
// Plusargs:
//   +TRACE=<file>   trace to replay (default cosim_trace.hex)
//   +INJECT=<n>     (TMR builds, compile with -DINJECT) flip one random bit of
//                   one random replica's state with probability n/1000 per cycle
//   +DOUBLE         flip the same bit in two replicas instead (negative control:
//                   TMR cannot mask this, so the comparison is expected to fail)
//
// Injection relies on hierarchical writes into the DUT's state registers, which
// Icarus honours and Verilator does not; run injection campaigns on Icarus.

`timescale 1ns/1ps
`include "astro_ctrl_defs.vh"

module tb_cosim;
    parameter TMR = 1;

    localparam W = `ASTRO_ST_W;

    reg         clk = 1'b0;
    reg         rst, wr_en, sw_ack;
    reg  [5:0]  wr_addr, rd_addr;
    reg  [31:0] wr_data;
    reg  [1:0]  pl_mode;

    wire        sw_req, fallback, fault, busy, tmr_err;
    wire [1:0]  sw_target, mode_cmd, threat_level;
    wire [`NEV-1:0] events;
    wire [31:0] rd_data;

    always #5 clk = ~clk;

    astro_ctrl_tmr #(.TMR(TMR)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .sw_ack(sw_ack), .pl_mode(pl_mode),
        .sw_req(sw_req), .sw_target(sw_target), .mode_cmd(mode_cmd),
        .threat_level(threat_level), .fallback(fallback), .fault(fault),
        .busy(busy), .events(events), .tmr_err(tmr_err)
    );

    wire [18:0] out_bits = {events, busy, fault, fallback, threat_level, mode_cmd, sw_target, sw_req};

    reg [1023:0] trace;
    integer fd, n, cyc, errors, inject_rate, injections, detected, double_inj;
    reg [63:0] vin, vexp;
    integer dom, bitn, dom2;

`ifdef INJECT
    task flip(input integer d, input integer b);
        begin
            case (d)
                0: dut.g_tmr.g_dom[0].st_r[b] = ~dut.g_tmr.g_dom[0].st_r[b];
                1: dut.g_tmr.g_dom[1].st_r[b] = ~dut.g_tmr.g_dom[1].st_r[b];
                default: dut.g_tmr.g_dom[2].st_r[b] = ~dut.g_tmr.g_dom[2].st_r[b];
            endcase
        end
    endtask
`endif

    initial begin
        if (!$value$plusargs("TRACE=%s", trace)) trace = "cosim_trace.hex";
        if (!$value$plusargs("INJECT=%d", inject_rate)) inject_rate = 0;
        double_inj = $test$plusargs("DOUBLE");
        fd = $fopen(trace, "r");
        if (fd == 0) begin
            $display("FAIL: cannot open trace %0s", trace);
            $finish;
        end
        errors = 0; cyc = 0; injections = 0; detected = 0;
        rst = 1'b1; wr_en = 1'b0; wr_addr = 6'd0; wr_data = 32'd0;
        rd_addr = 6'd0; sw_ack = 1'b0; pl_mode = 2'd0;

        while (!$feof(fd)) begin
            n = $fscanf(fd, "%h %h\n", vin, vexp);
            if (n == 2) begin
                @(negedge clk);
                rst     = vin[63];
                wr_en   = vin[62];
                wr_addr = vin[61:56];
                wr_data = vin[55:24];
                sw_ack  = vin[23];
                pl_mode = vin[22:21];
                rd_addr = vin[20:15];
`ifdef INJECT
                if (inject_rate > 0 && cyc > 2 && ($urandom % 1000) < inject_rate) begin
                    dom  = $urandom % 3;
                    bitn = $urandom % W;
                    flip(dom, bitn);
                    if (double_inj) begin
                        dom2 = (dom + 1 + ($urandom % 2)) % 3;
                        flip(dom2, bitn);
                    end
                    injections = injections + 1;
                end
`endif
                // VERSION reports the build; the trace is generated for TMR=1
                if (rd_addr == `A_VERSION) vexp[48] = (TMR != 0);
                #4;
                if (tmr_err) detected = detected + 1;
                // cycle 0 is the first reset cycle: state is still X in the RTL
                if (cyc > 0 && ({rd_data, 13'd0, out_bits} !== vexp)) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("MISMATCH cycle %0d: in=%h exp=%h got=%h", cyc, vin, vexp,
                                 {rd_data, 13'd0, out_bits});
                end
                cyc = cyc + 1;
            end
        end
        $fclose(fd);
        if (inject_rate > 0)
            $display("injections: %0d (%0s), cycles with replica disagreement: %0d",
                     injections, double_inj ? "double" : "single", detected);
        if (injections > 0 && !double_inj && detected != injections) begin
            $display("FAIL: %0d injections but %0d detected -- injection not effective in this simulator",
                     injections, detected);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS: tb_cosim TMR=%0d, %0d cycles match the reference model", TMR, cyc);
        else
            $display("FAIL: tb_cosim TMR=%0d, %0d mismatching cycles out of %0d", TMR, errors, cyc);
        $finish;
    end
endmodule
