// Verilator twin of sim/gemmini_tb.prp (8x8 mesh), driving verilog/GemminiSimTop.sv (flat ports). Same stimulus
// and checksum; must print the same sum as lhd sim run with --init-zero (see ../README.md).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "VGemminiSimTop.h"
#include "verilated.h"
static inline uint64_t bits(uint64_t v, int lo, int n) { return (v >> lo) & ((n == 64) ? ~0ULL : ((1ULL << n) - 1)); }
int main(int argc, char** argv) {
  uint64_t cycles = 1000;
  if (argc > 2 && !std::strcmp(argv[1], "--cycles")) cycles = std::strtoull(argv[2], nullptr, 0);
  auto* t = new VGemminiSimTop;
  uint64_t lfsr = 0x123456789abcdefULL, sum = 0, obs = 0;
  const uint64_t M63 = 0x7fffffffffffffffULL;
  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    t->clock = 0; t->reset = (cycle < 4);
    t->a_valid = bits(lfsr, 0, 1); t->a_bits = lfsr;
    t->b_valid = bits(lfsr, 1, 1); t->b_bits = lfsr >> 1;
    t->d_valid = bits(lfsr, 2, 1); t->d_bits = lfsr >> 2;
    t->req_valid = bits(lfsr, 3, 1); t->req_tag_id = bits(lfsr, 20, 1); t->req_dataflow = bits(lfsr, 21, 1);
    t->req_propagate = bits(lfsr, 22, 1); t->req_shift = bits(lfsr, 23, 5); t->req_a_transpose = bits(lfsr, 28, 1);
    t->req_bd_transpose = bits(lfsr, 29, 1); t->req_total_rows = bits(lfsr, 30, 4); t->req_flush = bits(lfsr, 34, 2);
    t->wr_valid = bits(lfsr, 4, 1); t->wr_addr = bits(lfsr, 35, 6);
    t->wr_data_0 = lfsr; t->wr_data_1 = lfsr >> 1; t->wr_data_2 = lfsr >> 2; t->wr_data_3 = lfsr >> 3;
    t->wr_acc = bits(lfsr, 41, 1); t->wr_mask = bits(lfsr, 24, 32);
    t->rd_valid = bits(lfsr, 5, 1); t->rd_scale = bits(lfsr, 0, 32); t->rd_addr = bits(lfsr, 44, 6);
    t->rd_act = bits(lfsr, 50, 3); t->rd_full = bits(lfsr, 53, 1); t->rd_fromDMA = bits(lfsr, 54, 1);
    t->rd_resp_ready = bits(lfsr, 6, 1);
    t->eval(); t->clock = 1; t->eval();
    obs = t->a_ready;
    obs |= (uint64_t)t->b_ready << 1; obs |= (uint64_t)t->d_ready << 2; obs |= (uint64_t)t->req_ready << 3;
    obs |= (uint64_t)t->wr_ready << 4; obs |= (uint64_t)t->rd_req_ready << 5; obs |= (uint64_t)t->rd_resp_valid << 6;
    obs |= (uint64_t)t->resp_valid << 7; obs |= (uint64_t)t->resp_tag_id << 8; obs |= (uint64_t)t->resp_last << 9;
    obs ^= (uint64_t)t->resp_total_rows << 10;
    obs |= (uint64_t)t->rd_resp_fromDMA << 13; obs |= (uint64_t)t->rd_resp_act << 14; obs |= (uint64_t)t->rd_resp_bank << 17;
    obs ^= (uint64_t)t->rd_resp_scale << 20;
    obs ^= t->resp_data_0 & M63; obs ^= t->resp_data_1 & M63; obs ^= t->resp_data_2 & M63; obs ^= t->resp_data_3 & M63;
    obs ^= t->rd_data_0 & M63; obs ^= t->rd_data_1 & M63; obs ^= t->rd_data_2 & M63; obs ^= t->rd_data_3 & M63;
    sum = ((sum << 1) + obs) & M63;
    lfsr ^= lfsr << 13; lfsr ^= lfsr >> 7; lfsr ^= lfsr << 17;
  }
  t->final();
  std::printf("gemmini8: cycles=%llu sum=%llu\n", (unsigned long long)cycles, (unsigned long long)sum);
  return 0;
}
