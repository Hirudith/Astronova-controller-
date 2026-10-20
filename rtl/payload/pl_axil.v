// pl_axil.v -- top level of the switchable payload (Block 4).
//
// AXI4-Lite control/observation for the PS, plus the mode-switch handshake to
// the controller (connect sw_req/sw_target/sw_ack/pl_mode straight to
// astro_ctrl_axil). Run control, seed, counters and the AXI adaptor are test
// harness, outside the replicas; target fault-injection campaigns at the
// replicas (u_pl) only.
//
// Register map (byte offsets):
//   0x00 ID        RO  "PLD0"
//   0x04 VERSION   RO  {8'h0, variant, major, minor}
//   0x08 CTRL      RW  [0] run
//   0x0C CMD       WO  [0] clear (seed -> all replicas), [1] clear diagnostics
//   0x10 SEED      RW
//   0x14 STOP_AT   RW  iteration count at which the workload stops (0 = free)
//   0x18 STATUS    RO  [1:0] pl_mode [4:2] active replicas [5] done [6] sw_ack
//                      [7] sw_req [9:8] variant
//   0x1C CNT       RO  workload state (voted in TMR, replica 0 otherwise)
//   0x20 SIG       RO
//   0x24 ACC       RO
//   0x28 LFSR      RO
//   0x2C DMR_ERR   RO  cycles with a DMR mismatch
//   0x30 TMR_ERR   RO  cycles with a replica disagreement in TMR
//   0x34 SWITCHES  RO  mode changes applied
//   0x38 STICKY    RO  [0] DMR mismatch seen [1] TMR disagreement seen
//   0x40-0x4C      RO  cycles spent in mode 0..3 (energy accounting)

module pl_axil #(
    parameter [7:0] VARIANT  = 8'd2,
    parameter [1:0] DEF_MODE = 2'd2
) (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [7:0]  s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // controller handshake
    input  wire        sw_req,
    input  wire [1:0]  sw_target,
    output wire        sw_ack,
    output wire [1:0]  pl_mode,

    output wire        done,
    output wire        tmr_err,
    output wire        dmr_err
);

    wire clk = s_axi_aclk;
    wire rst = ~s_axi_aresetn;

    wire        wr_en;
    wire [5:0]  wr_addr, rd_addr;
    wire [31:0] wr_data;
    reg  [31:0] rd_data;

    axil_slave u_axil (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );

    // ------------------------------------------------------------------
    // Control registers
    // ------------------------------------------------------------------
    reg        run;
    reg [31:0] seed, stop_at;
    wire       cmd_clear = wr_en && (wr_addr == 6'h03) && wr_data[0];
    wire       cmd_cdiag = wr_en && (wr_addr == 6'h03) && wr_data[1];

    always @(posedge clk) begin
        if (rst) begin
            run     <= 1'b0;
            seed    <= 32'h1234_5678;
            stop_at <= 32'd0;
        end else if (wr_en) begin
            case (wr_addr)
                6'h02: run     <= wr_data[0];
                6'h04: seed    <= wr_data;
                6'h05: stop_at <= wr_data;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Replicas and switching
    // ------------------------------------------------------------------
    wire [127:0] state;
    wire [2:0]   active;
    wire         switched;

    pl_switchable #(.VARIANT(VARIANT), .DEF_MODE(DEF_MODE)) u_pl (
        .clk(clk), .rst(rst),
        .run(run), .stop_at(stop_at), .clear(cmd_clear), .seed(seed),
        .sw_req(sw_req), .sw_target(sw_target), .sw_ack(sw_ack), .pl_mode(pl_mode),
        .state(state), .done(done), .active(active),
        .tmr_err(tmr_err), .dmr_err(dmr_err), .switched(switched)
    );

    // ------------------------------------------------------------------
    // Measurement counters (saturating)
    // ------------------------------------------------------------------
    reg [31:0] dmr_cyc, tmr_cyc, n_switch;
    reg [31:0] mode_cyc [0:3];
    reg [1:0]  sticky;
    integer m;

    always @(posedge clk) begin
        if (rst || cmd_cdiag) begin
            dmr_cyc  <= 32'd0;
            tmr_cyc  <= 32'd0;
            n_switch <= 32'd0;
            sticky   <= 2'd0;
            for (m = 0; m < 4; m = m + 1) mode_cyc[m] <= 32'd0;
        end else begin
            if (dmr_err  && !(&dmr_cyc))  dmr_cyc  <= dmr_cyc + 32'd1;
            if (tmr_err  && !(&tmr_cyc))  tmr_cyc  <= tmr_cyc + 32'd1;
            if (switched && !(&n_switch)) n_switch <= n_switch + 32'd1;
            if (!(&mode_cyc[pl_mode]))    mode_cyc[pl_mode] <= mode_cyc[pl_mode] + 32'd1;
            sticky <= sticky | {tmr_err, dmr_err};
        end
    end

    wire [7:0] variant_id = VARIANT;

    always @* begin
        case (rd_addr)
            6'h00: rd_data = 32'h504C_4430;                     // "PLD0"
            6'h01: rd_data = {8'h00, variant_id, 8'd1, 8'd0};
            6'h02: rd_data = {31'd0, run};
            6'h04: rd_data = seed;
            6'h05: rd_data = stop_at;
            6'h06: rd_data = {22'd0, variant_id[1:0], sw_req, sw_ack, done, active, pl_mode};
            6'h07: rd_data = state[31:0];
            6'h08: rd_data = state[63:32];
            6'h09: rd_data = state[95:64];
            6'h0A: rd_data = state[127:96];
            6'h0B: rd_data = dmr_cyc;
            6'h0C: rd_data = tmr_cyc;
            6'h0D: rd_data = n_switch;
            6'h0E: rd_data = {30'd0, sticky};
            6'h10: rd_data = mode_cyc[0];
            6'h11: rd_data = mode_cyc[1];
            6'h12: rd_data = mode_cyc[2];
            6'h13: rd_data = mode_cyc[3];
            default: rd_data = 32'd0;
        endcase
    end

endmodule
