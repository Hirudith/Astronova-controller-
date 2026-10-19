// tmr_voter.v -- bitwise 2-of-3 majority voter.
module tmr_voter #(
    parameter W = 1
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire [W-1:0] c,
    output wire [W-1:0] y
);
    assign y = (a & b) | (b & c) | (a & c);
endmodule
