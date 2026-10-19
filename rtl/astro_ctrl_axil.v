// astro_ctrl_axil.v -- top level of the Astronova protection controller.
//
// AXI4-Lite slave (256-byte window) for the Zynq PS, plus the payload-side
// mode-switch interface. Drop into a Vivado block design with "Add Module" and
// connect s_axi to M_AXI_GP0 through an AXI SmartConnect / Interconnect.
//
// Payload contract (4-phase handshake, all signals synchronous to s_axi_aclk):
//   1. controller raises sw_req with sw_target stable; sw_ack is low
//   2. payload switches to sw_target, resynchronises its state, then drives
//      pl_mode = sw_target and raises sw_ack
//   3. controller drops sw_req (it checks pl_mode == sw_target on the ack)
//   4. payload drops sw_ack; the switch window is closed
// pl_mode must always report the mode the payload is actually running in.
//
// Only full 32-bit writes are performed; partial-strobe writes get SLVERR.
// The AXI protocol logic sits outside the TMR boundary: an upset here can
// corrupt one bus transaction, which the telemetry CRC/sequence checks catch.

`include "astro_ctrl_defs.vh"

module astro_ctrl_axil #(
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
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    /* verilator lint_off UNUSEDSIGNAL */   // prot ignored, addr[1:0] ignored (word access)
    input  wire [7:0]  s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // payload mode-switch interface
    output wire        sw_req,
    output wire [1:0]  sw_target,
    input  wire        sw_ack,
    input  wire [1:0]  pl_mode,

    // status
    output wire [1:0]  mode_cmd,       // mode the controller currently commands
    output wire [1:0]  threat_level,   // NORMAL / ELEVATED / EXTREME
    output wire        fallback,       // fail-safe active (stale / invalid / reset)
    output wire        fault,          // payload unresponsive; wire to IRQ_F2P
    output wire        sw_window,      // switch in progress (fault-injection trigger)
    output wire        tmr_err         // replica disagreement this cycle
);

    wire clk = s_axi_aclk;
    wire rst = ~s_axi_aresetn;

    // ------------------------------------------------------------------
    // AXI4-Lite write channel -> single-cycle register write strobe
    // ------------------------------------------------------------------
    reg        aw_done, w_done;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [7:0]  awaddr_q;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [31:0] wdata_q;
    reg [3:0]  wstrb_q;
    reg        wr_en;

    assign s_axi_awready = !aw_done && !s_axi_bvalid;
    assign s_axi_wready  = !w_done  && !s_axi_bvalid;

    always @(posedge clk) begin
        if (rst) begin
            aw_done      <= 1'b0;
            w_done       <= 1'b0;
            awaddr_q     <= 8'd0;
            wdata_q      <= 32'd0;
            wstrb_q      <= 4'd0;
            wr_en        <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            wr_en <= 1'b0;
            if (s_axi_awvalid && s_axi_awready) begin
                awaddr_q <= s_axi_awaddr;
                aw_done  <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata_q <= s_axi_wdata;
                wstrb_q <= s_axi_wstrb;
                w_done  <= 1'b1;
            end
            if (aw_done && w_done && !s_axi_bvalid) begin
                wr_en        <= (wstrb_q == 4'hF);
                s_axi_bresp  <= (wstrb_q == 4'hF) ? 2'b00 : 2'b10;   // OKAY / SLVERR
                s_axi_bvalid <= 1'b1;
                aw_done      <= 1'b0;
                w_done       <= 1'b0;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    wire [5:0] wr_addr = awaddr_q[7:2];

    // ------------------------------------------------------------------
    // AXI4-Lite read channel
    // ------------------------------------------------------------------
    wire [5:0]  rd_addr = s_axi_araddr[7:2];
    wire [31:0] core_rd, diag_rd;

    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    always @(posedge clk) begin
        if (rst) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
        end else if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rdata  <= rd_addr[5] ? diag_rd : core_rd;
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Protected controller and diagnostics
    // ------------------------------------------------------------------
    wire [`NEV-1:0] events;
    wire            busy;

    astro_ctrl_tmr #(
        .TMR(TMR), .TMR_ERR_DETECT(TMR_ERR_DETECT),
        .DEF_CTRL(DEF_CTRL), .DEF_PRESCALE(DEF_PRESCALE),
        .DEF_FRESH_TO(DEF_FRESH_TO), .DEF_DWELL_UP(DEF_DWELL_UP),
        .DEF_DWELL_DN(DEF_DWELL_DN), .DEF_SW_TO(DEF_SW_TO),
        .DEF_TH_ELEV(DEF_TH_ELEV), .DEF_TH_EXTR(DEF_TH_EXTR),
        .DEF_MODE_MAP(DEF_MODE_MAP), .DEF_LIMITS(DEF_LIMITS)
    ) u_ctrl (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wdata_q),
        .rd_addr(rd_addr), .rd_data(core_rd),
        .sw_ack(sw_ack), .pl_mode(pl_mode),
        .sw_req(sw_req), .sw_target(sw_target), .mode_cmd(mode_cmd),
        .threat_level(threat_level), .fallback(fallback), .fault(fault),
        .busy(busy), .events(events), .tmr_err(tmr_err)
    );

    assign sw_window = busy;

    astro_ctrl_diag u_diag (
        .clk(clk), .rst(rst),
        .clear(wr_en && (wr_addr == `A_CMD) && wdata_q[2]),
        .events(events), .sw_req(sw_req), .fault(fault), .tmr_err(tmr_err),
        .rd_addr(rd_addr), .rd_data(diag_rd)
    );

endmodule
