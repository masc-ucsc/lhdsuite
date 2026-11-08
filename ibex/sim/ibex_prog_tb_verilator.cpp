// Verilator twin of ibex_prog_tb.prp: the same program, the same
// request/grant/response memory model (answered one cycle late, at most one
// transaction in flight per bus), the same checks and the same per-cycle
// checksum fold. The two must print the same line, `sum` included; keep them
// in lockstep. Three eval()s per cycle reproduce the Pyrope driver's
// drive / `step` / read order.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vibex_suite_top.h"
#include "verilated.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t cycles = 2000;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--cycles") == 0 && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 10);
    } else {
      std::fprintf(stderr, "usage: %s [--cycles N]\n", argv[0]);
      return 2;
    }
  }
  Vibex_suite_top    dut;
  constexpr uint32_t rom[] = {0x00000093, 0x00A00113, 0x00308093, 0xFFF10113,
                              0xFE011CE3, 0x10102023, 0x0000006F, 0x00000013};
  uint32_t i_req = 0, i_gnt = 0, i_resp = 0, i_addr = 0;
  uint32_t d_req = 0, d_gnt = 0, d_resp = 0, stored = 0;
  bool     got        = false;
  uint64_t done_cycle = 0, sum = 0;
  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    const bool i_give = i_req != 0 && i_gnt == 0;
    const bool d_give = d_req != 0 && d_gnt == 0;
    dut.clk_i          = 0;
    dut.rst_ni         = cycle >= 4;
    dut.instr_gnt_i    = i_give;
    dut.instr_rvalid_i = i_resp;
    dut.instr_rdata_i  = rom[(i_addr >> 2) & 7];
    dut.data_gnt_i     = d_give;
    dut.data_rvalid_i  = d_resp;
    dut.data_rdata_i   = 0;  // the program never loads
    dut.eval();
    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();
    i_resp = i_give;
    d_resp = d_give;
    if (i_give) {
      i_addr = dut.instr_addr_o;
    }
    if (d_give && dut.data_we_o && dut.data_addr_o == 0x100 && !got) {
      stored     = dut.data_wdata_o;
      got        = true;
      done_cycle = cycle;
    }
    uint64_t obs = 0;
    if (dut.instr_req_o) {
      obs ^= 1 ^ (uint64_t{dut.instr_addr_o} << 2);
    }
    if (dut.data_req_o) {
      obs ^= 2 ^ (uint64_t{dut.data_addr_o} << 9) ^ (uint64_t{dut.data_we_o} << 41) ^ (uint64_t{dut.data_be_o} << 42);
      if (dut.data_we_o) {
        obs ^= uint64_t{dut.data_wdata_o} << 23;
      }
    }
    sum   = (sum * 31 + obs) & 0x7fffffffffffffffULL;
    i_gnt = i_give;
    d_gnt = d_give;
    i_req = dut.instr_req_o;
    d_req = dut.data_req_o;
  }
  dut.final();
  std::printf("ibex prog: stored=%u at cycle %llu of %llu sum=%llu\n",
              stored,
              static_cast<unsigned long long>(done_cycle),
              static_cast<unsigned long long>(cycles),
              static_cast<unsigned long long>(sum));
  if (!got || stored != 30) {
    std::fprintf(stderr, "FAIL ibex.prog: got=%d stored=%u\n", got, stored);
    return 1;
  }
  std::puts("PASS ibex.prog (verilator)");
  return 0;
}
