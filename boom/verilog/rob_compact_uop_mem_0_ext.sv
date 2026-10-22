// Hand-written LEC stub for the firtool-emitted rob_compact_uop_mem_0_ext blackbox.
// 32x27 1R1W asynchronous-read memory, patterned after Rocket's rf_31x32.sv.
module rob_compact_uop_mem_0_ext(
  input  [4:0]  R0_addr,
  input         R0_en,
                R0_clk,
  output [26:0] R0_data,
  input  [4:0]  W0_addr,
  input         W0_en,
                W0_clk,
  input  [26:0] W0_data
);
  reg [26:0] Memory[0:31];
  always @(posedge W0_clk) begin
    if (W0_en & 1'h1)
      Memory[W0_addr] <= W0_data;
  end
  assign R0_data = R0_en ? Memory[R0_addr] : 27'bx;
endmodule
