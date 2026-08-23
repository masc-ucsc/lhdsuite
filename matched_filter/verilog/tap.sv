// One storage tap. The return sample advances every cycle; the independent
// reference advances only while ref_load is asserted.
module tap(
  input                clock,
  input                reset,
  input  signed [7:0]  x_in,
  input  signed [7:0]  ref_in,
  input                ref_load,
  output signed [7:0]  x_out,
  output signed [7:0]  ref_out
);
  reg signed [7:0] x_r;
  reg signed [7:0] ref_r;
  always @(posedge clock) begin
    if (reset) begin
      x_r   <= 8'sd0;
      ref_r <= 8'sd0;
    end else begin
      x_r <= x_in;
      if (ref_load) ref_r <= ref_in;
    end
  end
  assign x_out   = x_r;
  assign ref_out = ref_r;
endmodule
