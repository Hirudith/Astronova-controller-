// pl_workload.v -- reference workload for the switchable payload (Block 4).
//
// Placeholder for decision D1 (ITC'99 B13, matrix multiply, Monte Carlo kernel
// or CNN layer). Any workload can replace it if it keeps this shape: a purely
// combinational next-state function of one replica, with all of its state in
// one vector, so that pl_switchable can triplicate, vote and copy that state.
//
// This one is an iterative kernel with an internal input generator, so a run
// is fully determined by the seed and the iteration count, and the final
// signature can be checked against python/astronova/payload.py:
//   lfsr <- Galois LFSR step (taps 0x80200003)
//   acc  <- acc * 0x9E3779B1 + lfsr          (32-bit)
//   sig  <- rotl(sig, 5) ^ acc
//   cnt  <- cnt + 1
// It advances once per cycle while run=1, and stops when cnt == stop_at
// (stop_at = 0: free-running).

module pl_workload (
    input  wire [127:0] st_q,      // {lfsr, acc, sig, cnt}
    input  wire         run,
    input  wire [31:0]  stop_at,
    output wire [127:0] st_d
);
    wire [31:0] lfsr = st_q[127:96];
    wire [31:0] acc  = st_q[95:64];
    wire [31:0] sig  = st_q[63:32];
    wire [31:0] cnt  = st_q[31:0];

    wire        done   = (stop_at != 32'd0) && (cnt == stop_at);
    wire [31:0] lfsr_n = {1'b0, lfsr[31:1]} ^ (lfsr[0] ? 32'h8020_0003 : 32'd0);
    wire [31:0] acc_n  = acc * 32'h9E37_79B1 + lfsr_n;
    wire [31:0] sig_n  = {sig[26:0], sig[31:27]} ^ acc_n;

    assign st_d = (run && !done) ? {lfsr_n, acc_n, sig_n, cnt + 32'd1} : st_q;
endmodule
