// Minimal Verilator driver for minion_top: bring the core out of reset and run.
// Not a program test — an ORACLE HARNESS. Its job is to prove the whole design
// elaborates, builds and advances under an event-driven simulator, so that
// "lhd sim refuses minion" can be attributed to the simulator rather than to
// the design. minion_prog_tb_verilator.cpp (the real twin of the Pyrope program
// testbench) is the next step; this is the floor it stands on.
#include <cstdio>
#include "Vminion_top.h"
#include "verilated.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vminion_top;

  dut->clk_i    = 0;
  dut->rst_c_ni = 0;
  dut->rst_d_ni = 0;
  dut->rst_w_ni = 0;
  dut->eval();

  long cycles = 200;
  for (long c = 0; c < cycles; ++c) {
    if (c >= 4) { dut->rst_c_ni = 1; dut->rst_d_ni = 1; dut->rst_w_ni = 1; }
    dut->clk_i = 1; dut->eval();     // RISE
    dut->clk_i = 0; dut->eval();     // FALL
  }
  std::printf("minion_top: %ld cycles under verilator, no settle failure\n", cycles);
  dut->final();
  delete dut;
  return 0;
}
