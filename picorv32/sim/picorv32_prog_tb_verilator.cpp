// Same program, one-cycle memory response, and checks as picorv32_prog_tb.prp.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vpicorv32_top.h"
#include "verilated.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t cycles = 500000;
  bool config_test = false;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--cycles") == 0 && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 10);
    } else if (std::strcmp(argv[i], "--config-test") == 0) {
      config_test = true;
    } else {
      std::fprintf(stderr, "usage: %s [--cycles N] [--config-test]\n", argv[0]);
      return 2;
    }
  }
  Vpicorv32_top dut;
  constexpr uint32_t rom[] = {0x00000093, 0x00A00113, 0x00308093, 0xFFF10113,
                              0xFE011CE3, 0x10102023, 0x0000006F, 0x00000013};
  constexpr uint32_t config_rom[] = {
      0x00300093, 0x00509113, 0x00215193, 0xF8000213, 0x40325293, 0x00518333,
      0x40130333, 0x001093B3, 0x00730333, 0x001153B3, 0x00730333, 0x401253B3,
      0x40730333, 0x0002A393, 0x00730333, 0x10602023, 0x0000006F, 0x00000013,
      0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013,
      0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013,
      0x00000013, 0x00000013};
  const uint32_t expected = config_test ? 58 : 30;
  uint32_t req_valid = 0, req_addr = 0, stored = 0;
  uint64_t done_cycle = 0;
  bool got = false, trapped = false;
  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    dut.clk = 0;
    dut.resetn = cycle >= 4;
    dut.irq = 0;
    dut.mem_ready = req_valid;
    dut.mem_rdata = (config_test ? config_rom[(req_addr >> 2) & 31]
                                 : rom[(req_addr >> 2) & 7]);
    dut.eval();
    dut.clk = 1;
    dut.eval();
    dut.clk = 0;
    dut.eval();
    if (dut.mem_valid && dut.mem_wstrb && dut.mem_addr == 0x100 && !got) {
      stored = dut.mem_wdata;
      got = true;
      done_cycle = cycle;
    }
    trapped |= dut.trap != 0;
    req_valid = dut.mem_valid;
    req_addr = dut.mem_addr;
  }
  dut.final();
  std::printf("picorv32 prog: stored=%u at cycle %llu of %llu\n", stored,
              static_cast<unsigned long long>(done_cycle),
              static_cast<unsigned long long>(cycles));
  if (trapped || !got || stored != expected) {
    std::fprintf(stderr, "FAIL picorv32.prog: trapped=%d got=%d stored=%u\n",
                 trapped, got, stored);
    return 1;
  }
  std::puts("PASS picorv32.prog (verilator)");
  return 0;
}
