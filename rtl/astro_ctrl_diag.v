// astro_ctrl_diag.v -- measurement counters for the Astronova controller.
//
// Deliberately outside the TMR boundary: an upset here corrupts a statistic,
// never the commanded protection mode. Provides the switch-latency figures for
// RQ4 and the switch / fallback / reject counts used for the alert-behaviour
// metrics.

`include "astro_ctrl_defs.vh"

module astro_ctrl_diag (
    input  wire            clk,
    input  wire            rst,
    input  wire            clear,
    input  wire [`NEV-1:0] events,
    input  wire            sw_req,
    input  wire            fault,
    input  wire            tmr_err,
    input  wire [5:0]      rd_addr,
    output reg  [31:0]     rd_data
);

    reg [31:0] ev_cnt [0:`NEV-1];
    reg [31:0] lat_cnt, last_lat, max_lat, err_cyc;
    reg [63:0] cycles;
    reg [2:0]  sticky;

    integer e;
    always @(posedge clk) begin
        if (rst || clear) begin
            for (e = 0; e < `NEV; e = e + 1) ev_cnt[e] <= 32'd0;
            lat_cnt  <= 32'd0;
            last_lat <= 32'd0;
            max_lat  <= 32'd0;
            err_cyc  <= 32'd0;
            cycles   <= 64'd0;
            sticky   <= 3'd0;
        end else begin
            for (e = 0; e < `NEV; e = e + 1)
                if (events[e] && !(&ev_cnt[e])) ev_cnt[e] <= ev_cnt[e] + 32'd1;

            // cycles with sw_req high, including the cycle sw_ack is seen
            if (sw_req) begin
                if (events[`EV_SW_DONE]) begin
                    last_lat <= lat_cnt + 32'd1;
                    if (lat_cnt + 32'd1 > max_lat) max_lat <= lat_cnt + 32'd1;
                    lat_cnt  <= 32'd0;
                end else if (!(&lat_cnt)) begin
                    lat_cnt  <= lat_cnt + 32'd1;
                end
            end else begin
                lat_cnt <= 32'd0;
            end

            if (tmr_err && !(&err_cyc)) err_cyc <= err_cyc + 32'd1;
            cycles <= cycles + 64'd1;
            sticky <= sticky | {events[`EV_ILLEGAL], fault, tmr_err};
        end
    end

    wire [3:0] ev_off = rd_addr[3:0];   // A_DIAG_BASE is 0x20, so the low bits index the counter

    always @* begin
        if (rd_addr >= `A_DIAG_BASE && rd_addr < `A_DIAG_BASE + `NEV)
            rd_data = ev_cnt[ev_off];
        else begin
            case (rd_addr)
                `A_LAST_LAT: rd_data = last_lat;
                `A_MAX_LAT:  rd_data = max_lat;
                `A_TMR_ERR:  rd_data = err_cyc;
                `A_CYCLE_LO: rd_data = cycles[31:0];
                `A_CYCLE_HI: rd_data = cycles[63:32];
                `A_STICKY:   rd_data = {29'd0, sticky};
                default:     rd_data = 32'd0;
            endcase
        end
    end

endmodule
