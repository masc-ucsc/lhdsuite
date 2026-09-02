// A minimal Icarus/Verilator reference testbench: `addi x1,x0,5; sw x1,256(x0);
// jal x0,0` with the SAME one-cycle-latency memory model as
// picorv32_prog_tb.prp. It is NOT a bazel target — it is the ORACLE for the
// known-failing sim rows: iverilog runs this and prints
//   c=21 a=256 instr=0 wstrb=15 wdata=5
// (the store), while `lhd sim` on the same RTL never drives a write strobe at
// all. Reproduce with:
//   iverilog -g2012 -DSYNTHESIS -o /tmp/sim picorv32/sim/picorv32_min_tb.v \
//       picorv32/verilog/picorv32.v picorv32/verilog/picorv32_top.v && /tmp/sim
`timescale 1ns/1ps
module tb;
  reg clk=0, resetn=0; wire trap;
  wire mem_valid, mem_instr; reg mem_ready=0;
  wire [31:0] mem_addr, mem_wdata; wire [3:0] mem_wstrb; reg [31:0] mem_rdata=0;
  reg [31:0] rom [0:7];
  reg req_valid=0; reg [31:0] req_addr=0;
  integer c=0;
  picorv32_top dut(.clk(clk),.resetn(resetn),.trap(trap),.mem_valid(mem_valid),
    .mem_instr(mem_instr),.mem_ready(mem_ready),.mem_addr(mem_addr),
    .mem_wdata(mem_wdata),.mem_wstrb(mem_wstrb),.mem_rdata(mem_rdata),
    .irq(32'b0),.eoi());
  initial begin
    rom[0]=32'h00500093; rom[1]=32'h10102023; rom[2]=32'h0000006F;
    rom[3]=32'h00000013; rom[4]=32'h00000013; rom[5]=32'h00000013;
    rom[6]=32'h00000013; rom[7]=32'h00000013;
  end
  // Same one-cycle-latency model as the Pyrope driver.
  always @(posedge clk) begin
    c <= c+1;
    resetn <= (c >= 4);
    mem_ready <= req_valid;
    mem_rdata <= rom[(req_addr>>2) & 3'h7];
    if (mem_valid) $display("c=%0d a=%0d instr=%0d wstrb=%0d wdata=%0d", c, mem_addr, mem_instr, mem_wstrb, mem_wdata);
    req_valid <= mem_valid;
    req_addr  <= mem_addr;
    if (c > 60) $finish;
  end
  always #5 clk = ~clk;
endmodule
