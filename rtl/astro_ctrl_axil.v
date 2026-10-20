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
// Bus protocol: axil_slave.v (full 32-bit writes only; partial strobes get SLVERR).
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
    // AXI4-Lite -> register-file strobes
    // ------------------------------------------------------------------
    wire        wr_en;
    wire [5:0]  wr_addr, rd_addr;
    wire [31:0] wdata_q;
    wire [31:0] core_rd, diag_rd;

    axil_slave u_axil (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wdata_q),
        .rd_addr(rd_addr), .rd_data(rd_addr[5] ? diag_rd : core_rd)
    );

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
