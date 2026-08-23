// One registered node of the adder tree.
module add_node #(
  parameter integer SW = 10
)(
  input                clock,
  input                reset,
  input  signed [SW-1:0] a,
  input  signed [SW-1:0] b,
  output signed [SW-1:0] s
);
  reg signed [SW-1:0] s_r;
  always @(posedge clock) begin
    if (reset) s_r <= {SW{1'b0}};
    else       s_r <= a + b;
  end
  assign s = s_r;
endmodule
