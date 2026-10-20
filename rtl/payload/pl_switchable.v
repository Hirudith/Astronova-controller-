// pl_switchable.v -- payload protection variants and Level-1 mode switching (Block 4).
//
// VARIANT 0  BASELINE    one replica, no redundancy           reports mode 0
// VARIANT 1  STATIC_TMR  three replicas, voted feedback        reports mode 2
// VARIANT 2  SWITCHABLE  three replicas; mode selects how many run:
//              0 SIMPLEX  replica 0 only (1 and 2 clock-enable low)
//              1 DMR      replicas 0 and 1, compared (detection only)
//              2 TMR      all three, voted feedback
//              3 TMR      as 2 (the controller's TMR_PLUS; e.g. a faster scrub
//                         rate is applied outside the payload)
//
// Level-1 switching (decision D2): a switch takes effect in the cycle the request
// is seen. Replicas that become active are loaded with replica 0's next state in
// that same cycle (state resynchronisation [39]), so the computation neither
// stalls nor diverges. sw_ack rises one cycle later.
//
// Handshake (see docs/SPEC.md section 4): sw_ack rises after a request and falls
// after sw_req falls; pl_mode always reports the running mode. Static variants
// acknowledge every request and keep reporting their fixed mode, so a request
// for another mode shows up at the controller as a mode mismatch.
//
// Protection boundary of the SWITCHABLE variant: the replicas, their voters and
// the mode register are triplicated (each domain selects its own feedback and
// clock enable from its own voted mode copy). The switch adapter, the replica-0
// "next state" used for loading, and the read-out path are single. These
// non-triplicated additions are what the switchable-TMR penalty (RQ5) measures.

module pl_switchable #(
    parameter       VARIANT  = 2,
    parameter [1:0] DEF_MODE = 2'd2      // mode after reset (SWITCHABLE only)
) (
    input  wire         clk,
    input  wire         rst,

    // workload control
    input  wire         run,
    input  wire [31:0]  stop_at,
    input  wire         clear,           // load the seed state into every replica
    input  wire [31:0]  seed,

    // controller handshake
    input  wire         sw_req,
    /* verilator lint_off UNUSEDSIGNAL */   // ignored by the static variants
    input  wire [1:0]   sw_target,
    /* verilator lint_on UNUSEDSIGNAL */
    output reg          sw_ack,
    output wire [1:0]   pl_mode,

    // observation
    output wire [127:0] state,           // voted in TMR, replica 0 otherwise
    output wire         done,
    output wire [2:0]   active,          // replicas currently clocked
    output wire         tmr_err,         // replicas disagree while in TMR
    output wire         dmr_err,         // replicas 0 and 1 disagree while in DMR
    output wire         switched         // a mode change was applied this cycle
);

    localparam W = 128;

    wire [W-1:0] seed_state = {(seed == 32'd0) ? 32'd1 : seed, 96'd0};
    wire         req_new    = sw_req && !sw_ack;

    function [2:0] act_mask;            // {r2, r1, r0} clocked in mode m
        input [1:0] m;
        act_mask = {m[1], m != 2'd0, 1'b1};
    endfunction

    generate
        // ======================================================================
        if (VARIANT == 0) begin : g_base
            reg  [W-1:0] st_r;
            wire [W-1:0] st_d;

            pl_workload u_wl (.st_q(st_r), .run(run), .stop_at(stop_at), .st_d(st_d));

            always @(posedge clk) begin
                if (rst || clear) st_r <= seed_state;
                else              st_r <= st_d;
            end

            assign state    = st_r;
            assign pl_mode  = 2'd0;
            assign active   = 3'b001;
            assign tmr_err  = 1'b0;
            assign dmr_err  = 1'b0;
            assign switched = 1'b0;

        // ======================================================================
        end else if (VARIANT == 1) begin : g_static
            wire [3*W-1:0] st_all;
            /* verilator lint_off UNUSEDSIGNAL */   // only domain 0's copy is read out
            wire [3*W-1:0] stv_all;
            /* verilator lint_on UNUSEDSIGNAL */
            genvar g;
            for (g = 0; g < 3; g = g + 1) begin : g_rep
                wire [W-1:0] st_v, st_d;
                (* DONT_TOUCH = "yes", KEEP = "yes" *)
                reg  [W-1:0] st_r;

                (* DONT_TOUCH = "yes", keep_hierarchy = "yes" *)
                tmr_voter #(.W(W)) u_vote (
                    .a(st_all[0 +: W]), .b(st_all[W +: W]), .c(st_all[2*W +: W]), .y(st_v));
                (* DONT_TOUCH = "yes", keep_hierarchy = "yes" *)
                pl_workload u_wl (.st_q(st_v), .run(run), .stop_at(stop_at), .st_d(st_d));

                always @(posedge clk) begin
                    if (rst || clear) st_r <= seed_state;
                    else              st_r <= st_d;
                end
                assign st_all[g*W +: W]  = st_r;
                assign stv_all[g*W +: W] = st_v;
            end

            assign state    = stv_all[0 +: W];
            assign pl_mode  = 2'd2;
            assign active   = 3'b111;
            assign tmr_err  = (st_all[0 +: W] != st_all[W +: W]) || (st_all[0 +: W] != st_all[2*W +: W]);
            assign dmr_err  = 1'b0;
            assign switched = 1'b0;

        // ======================================================================
        end else begin : g_switch
            // mode register: triplicated with voted feedback
            wire [5:0] mode_all;
            /* verilator lint_off UNUSEDSIGNAL */   // only domain 0's copies are read out
            wire [5:0] modev_all;
            wire [1:0] mode0 = modev_all[1:0];    // domain 0's voted mode
            wire       apply = req_new;           // every mode code is supported
            wire [2:0] load  = apply ? (act_mask(sw_target) & ~act_mask(mode0)) : 3'b000;

            wire [3*W-1:0] stv_all, std_all;
            /* verilator lint_on UNUSEDSIGNAL */
            wire [3*W-1:0] st_all;
            wire [W-1:0]   st_d0 = std_all[0 +: W];   // replica 0 next state, used for loading

            genvar g;
            for (g = 0; g < 3; g = g + 1) begin : g_rep
                wire [1:0]   mode_v;
                (* DONT_TOUCH = "yes", KEEP = "yes" *)
                reg  [1:0]   mode_r;
                wire [W-1:0] st_v, st_d, fb;
                (* DONT_TOUCH = "yes", KEEP = "yes" *)
                reg  [W-1:0] st_r;

                (* DONT_TOUCH = "yes", keep_hierarchy = "yes" *)
                tmr_voter #(.W(2)) u_mvote (
                    .a(mode_all[1:0]), .b(mode_all[3:2]), .c(mode_all[5:4]), .y(mode_v));
                (* DONT_TOUCH = "yes", keep_hierarchy = "yes" *)
                tmr_voter #(.W(W)) u_vote (
                    .a(st_all[0 +: W]), .b(st_all[W +: W]), .c(st_all[2*W +: W]), .y(st_v));

                assign fb = mode_v[1] ? st_v : st_r;      // voted feedback only in TMR
                /* verilator lint_off UNUSEDSIGNAL */
                wire [2:0] am = act_mask(mode_v);
                /* verilator lint_on UNUSEDSIGNAL */
                wire       ce = am[g];                    // this replica is clocked

                (* DONT_TOUCH = "yes", keep_hierarchy = "yes" *)
                pl_workload u_wl (.st_q(fb), .run(run), .stop_at(stop_at), .st_d(st_d));

                always @(posedge clk) begin
                    if (rst)        mode_r <= DEF_MODE;
                    else if (apply) mode_r <= sw_target;
                    else            mode_r <= mode_v;

                    if (rst || clear) st_r <= seed_state;
                    else if (load[g]) st_r <= st_d0;      // resynchronise a newly active replica
                    else if (ce)      st_r <= st_d;
                end

                assign mode_all[2*g +: 2]  = mode_r;
                assign modev_all[2*g +: 2] = mode_v;
                assign st_all[g*W +: W]    = st_r;
                assign stv_all[g*W +: W]   = st_v;
                assign std_all[g*W +: W]   = st_d;
            end

            assign pl_mode  = mode0;
            assign active   = act_mask(mode0);
            assign state    = mode0[1] ? stv_all[0 +: W] : st_all[0 +: W];
            assign tmr_err  = mode0[1] && ((st_all[0 +: W] != st_all[W +: W]) ||
                                           (st_all[0 +: W] != st_all[2*W +: W]));
            assign dmr_err  = (mode0 == 2'd1) && (st_all[0 +: W] != st_all[W +: W]);
            assign switched = apply && (sw_target != mode0);
        end
    endgenerate

    // switch adapter: 4-phase acknowledge (the mode itself is applied above)
    always @(posedge clk) begin
        if (rst)          sw_ack <= 1'b0;
        else if (req_new) sw_ack <= 1'b1;
        else if (!sw_req) sw_ack <= 1'b0;
    end

    assign done = (stop_at != 32'd0) && (state[31:0] == stop_at);

endmodule
