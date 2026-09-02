// Verilator twin of tag_cmp_tb.prp: every port requests every way while the
// complete cache-line array is invalid, so no way may report a hit.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vtag_cmp_wrap.h"
#include "verilated.h"

int main(int argc, char** argv) {
  uint64_t cycles = 200;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--cycles") && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 0);
    } else if (!std::strcmp(argv[i], "--help") || !std::strcmp(argv[i], "-h")) {
      std::printf("usage: %s [--cycles N]\n", argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "tag_cmp_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* top = new Vtag_cmp_wrap;

  top->clk_i  = 0;
  top->rst_ni = 0;
  top->req_i  = 0xffffffffffULL;  // five ports x eight ways
  std::memset(&top->tag_i, 0, sizeof(top->tag_i));
  std::memset(&top->rdata_i, 0, sizeof(top->rdata_i));
  top->eval();

  uint8_t hit_way = 0;
  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    top->rst_ni = cycle >= 2;
    top->clk_i  = 1;
    top->eval();
    top->clk_i = 0;
    top->eval();
    hit_way = top->hit_way_o;
    if (hit_way != 0) {
      std::fprintf(stderr,
                   "cva6 tag_cmp: invalid line hit at cycle %llu: hit_way=%u\n",
                   static_cast<unsigned long long>(cycle),
                   static_cast<unsigned>(hit_way));
      delete top;
      return 3;
    }
  }

  top->final();
  std::printf("cva6 tag_cmp: ran %llu cycles, hit_way=%u\n",
              static_cast<unsigned long long>(cycles),
              static_cast<unsigned>(hit_way));
  delete top;
  return 0;
}
