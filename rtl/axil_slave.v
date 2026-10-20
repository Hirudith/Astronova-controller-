// axil_slave.v -- minimal AXI4-Lite slave (256-byte window, one transaction at
// a time) that turns bus accesses into a register-file interface:
//   write: one-cycle wr_en pulse with wr_addr / wr_data, after AW and W
//   read:  rd_addr follows s_axi_araddr; rd_data is sampled on the AR handshake
// Only full 32-bit writes are performed; partial-strobe writes get SLVERR.

module axil_slave (
    input  wire        clk,
    input  wire        rst,

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

    output reg         wr_en,
    output wire [5:0]  wr_addr,
    output wire [31:0] wr_data,
    output wire [5:0]  rd_addr,
    input  wire [31:0] rd_data
);

    // ------------------------------------------------------------------
    // Write channel
    // ------------------------------------------------------------------
    reg        aw_done, w_done;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [7:0]  awaddr_q;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [31:0] wdata_q;
    reg [3:0]  wstrb_q;

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

    assign wr_addr = awaddr_q[7:2];
    assign wr_data = wdata_q;

    // ------------------------------------------------------------------
    // Read channel
    // ------------------------------------------------------------------
    assign rd_addr       = s_axi_araddr[7:2];
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    always @(posedge clk) begin
        if (rst) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
        end else if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rdata  <= rd_data;
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

endmodule
