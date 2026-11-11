// Verilator twin of xiangshan/Mini16/sim/xs_mini16_tb.prp: the same stimulus, the same fold, the
// same printed line. It is also the ORACLE: the Pyrope trees, an lg: library read from the .sv and
// Verilator on the same .sv must print the SAME checksum. Keep the pair in lockstep (LFSR, driven
// ports, observed outputs, fold order) and re-pin `sim_expect` after any change.
//
// Packed-struct ports: the Verilog keeps the Chisel bundles as `struct packed`, which Verilator
// flattens MSB-first. io_frontend_cfVec_N_bits is 193 bits with `instr` in [192:161];
// io_fromWB_wbData_N_bits_robIdx is {flag, value[3:0]}; `trigger` is bits [94:91] of the frontend
// struct and must be 15 (TriggerAction.None), see the Pyrope driver.
//
// Schedule: two eval()s per cycle (clock=0 settle with this cycle's inputs, clock=1 the posedge),
// because the Pyrope driver reads only below its `step`.
//
// Usage:
//   verilator --cc --exe --build --top-module CtrlBlock -Wno-fatal -DSYNTHESIS \
//       -F xiangshan/Mini16/verilog/filelist.f xiangshan/Mini16/sim/xs_mini16_tb_verilator.cpp
//   ./obj_dir/VCtrlBlock --cycles 1000

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VCtrlBlock.h"
#include "verilated.h"

// Write `width` (<= 32) bits of `val` at bit `lo` of a Verilator wide port.
template <typename W>
static void set_bits(W& w, int lo, int width, uint32_t val) {
  for (int b = 0; b < width; ++b) {
    int      bit  = lo + b;
    uint32_t mask = 1u << (bit & 31);
    if ((val >> b) & 1) w[bit >> 5] |= mask;
    else                w[bit >> 5] &= ~mask;
  }
}

static inline uint64_t bits(uint64_t v, int lo, int hi) { return (v >> lo) & ((2ULL << (hi - lo)) - 1); }

int main(int argc, char** argv) {
  uint64_t cycles = 1000;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--cycles") && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 0);
    } else if (!std::strcmp(argv[i], "--help") || !std::strcmp(argv[i], "-h")) {
      std::printf("usage: %s [--cycles N]\n", argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "xs_mini16_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* t = new VCtrlBlock;

  uint64_t lfsr = 0x123456789abcdefULL;
  uint64_t sum  = 0;
  uint8_t  wbp  = 0;  // 5-bit writeback sweep pointer {flag, value}

  for (uint64_t clock = 0; clock < cycles; ++clock) {
    t->clock = 0;
    t->reset = clock < 4;

    t->io_fromTop_hartId = 0;

    uint32_t i0 = (uint32_t)((bits(lfsr, 10, 21) << 20) | (bits(lfsr, 5, 9) << 15) | (bits(lfsr, 0, 4) << 7) | 0x13);
    uint32_t i1 = (uint32_t)((bits(lfsr, 32, 36) << 20) | (bits(lfsr, 37, 41) << 15) | (bits(lfsr, 42, 46) << 7) | 0x33);

    t->io_frontend_cfVec_0_valid = 1;
    t->io_frontend_cfVec_1_valid = 1;
    t->io_frontend_cfVec_2_valid = 1;
    t->io_frontend_cfVec_3_valid = 1;
    t->io_frontend_cfVec_4_valid = 1;
    t->io_frontend_cfVec_5_valid = 1;
    t->io_frontend_cfVec_6_valid = 1;
    t->io_frontend_cfVec_7_valid = 1;
    set_bits(t->io_frontend_cfVec_0_bits, 161, 32, bits(lfsr, 48, 48) ? i1 : i0);
    set_bits(t->io_frontend_cfVec_1_bits, 161, 32, bits(lfsr, 49, 49) ? i1 : i0);
    set_bits(t->io_frontend_cfVec_2_bits, 161, 32, bits(lfsr, 50, 50) ? i1 : i0);
    set_bits(t->io_frontend_cfVec_3_bits, 161, 32, bits(lfsr, 51, 51) ? i1 : i0);
    set_bits(t->io_frontend_cfVec_4_bits, 161, 32, bits(lfsr, 52, 52) ? i1 : i0);
    set_bits(t->io_frontend_cfVec_5_bits, 161, 32, bits(lfsr, 53, 53) ? i1 : i0);
    set_bits(t->io_frontend_cfVec_6_bits, 161, 32, bits(lfsr, 54, 54) ? i1 : i0);
    set_bits(t->io_frontend_cfVec_7_bits, 161, 32, bits(lfsr, 55, 55) ? i1 : i0);

    set_bits(t->io_frontend_cfVec_0_bits, 91, 4, 15);  // trigger = TriggerAction.None
    set_bits(t->io_frontend_cfVec_1_bits, 91, 4, 15);  // trigger = TriggerAction.None
    set_bits(t->io_frontend_cfVec_2_bits, 91, 4, 15);  // trigger = TriggerAction.None
    set_bits(t->io_frontend_cfVec_3_bits, 91, 4, 15);  // trigger = TriggerAction.None
    set_bits(t->io_frontend_cfVec_4_bits, 91, 4, 15);  // trigger = TriggerAction.None
    set_bits(t->io_frontend_cfVec_5_bits, 91, 4, 15);  // trigger = TriggerAction.None
    set_bits(t->io_frontend_cfVec_6_bits, 91, 4, 15);  // trigger = TriggerAction.None
    set_bits(t->io_frontend_cfVec_7_bits, 91, 4, 15);  // trigger = TriggerAction.None
    t->io_toIssueBlock_intUops_0_ready  = 1;
    t->io_toIssueBlock_intUops_1_ready  = 1;
    t->io_toIssueBlock_intUops_2_ready  = 1;
    t->io_toIssueBlock_intUops_3_ready  = 1;
    t->io_toIssueBlock_intUops_4_ready  = 1;
    t->io_toIssueBlock_intUops_5_ready  = 1;
    t->io_toIssueBlock_intUops_6_ready  = 1;
    t->io_toIssueBlock_intUops_7_ready  = 1;
    t->io_toIssueBlock_intUops_8_ready  = 1;
    t->io_toIssueBlock_intUops_9_ready  = 1;
    t->io_toIssueBlock_intUops_10_ready = 1;
    t->io_toIssueBlock_intUops_11_ready = 1;
    t->io_toIssueBlock_intUops_12_ready = 1;
    t->io_toIssueBlock_intUops_13_ready = 1;
    t->io_toIssueBlock_intUops_14_ready = 1;
    t->io_toIssueBlock_intUops_15_ready = 1;
    t->io_toIssueBlock_intUops_16_ready = 1;
    t->io_toIssueBlock_intUops_17_ready = 1;
    t->io_toIssueBlock_intUops_18_ready = 1;
    t->io_toIssueBlock_intUops_19_ready = 1;
    t->io_toIssueBlock_intUops_20_ready = 1;
    t->io_toIssueBlock_intUops_21_ready = 1;
    t->io_toIssueBlock_fpUops_0_ready = 1;
    t->io_toIssueBlock_fpUops_1_ready = 1;
    t->io_toIssueBlock_fpUops_2_ready = 1;
    t->io_toIssueBlock_fpUops_3_ready = 1;
    t->io_toIssueBlock_fpUops_4_ready = 1;
    t->io_toIssueBlock_fpUops_5_ready = 1;
    t->io_toIssueBlock_fpUops_6_ready = 1;
    t->io_toIssueBlock_fpUops_7_ready = 1;
    t->io_toIssueBlock_vfUops_0_ready = 1;
    t->io_toIssueBlock_vfUops_1_ready = 1;
    t->io_toIssueBlock_vfUops_2_ready = 1;
    t->io_toIssueBlock_vfUops_3_ready = 1;
    t->io_toIssueBlock_vfUops_4_ready = 1;
    t->io_toIssueBlock_vfUops_5_ready = 1;
    t->io_toIssueBlock_vfUops_6_ready = 1;
    t->io_toIssueBlock_vfUops_7_ready = 1;
    t->io_toMem_lsqEnqIO_canAccept = 1;

    t->io_fromWB_wbData_1_valid       = 1;
    t->io_fromWB_wbData_1_bits_robIdx = (uint8_t)((wbp & 0x10) | ((wbp + 0) & 0xf));
    t->io_fromWB_wbData_2_valid       = 1;
    t->io_fromWB_wbData_2_bits_robIdx = (uint8_t)((wbp & 0x10) | ((wbp + 1) & 0xf));
    t->io_fromWB_wbData_3_valid       = 1;
    t->io_fromWB_wbData_3_bits_robIdx = (uint8_t)((wbp & 0x10) | ((wbp + 2) & 0xf));
    t->io_fromWB_wbData_4_valid       = 1;
    t->io_fromWB_wbData_4_bits_robIdx = (uint8_t)((wbp & 0x10) | ((wbp + 3) & 0xf));
    t->eval();

    t->clock = 1;
    t->eval();

    uint64_t obs = t->io_frontend_canAccept;
    obs |= (uint64_t)t->io_frontend_cfVec_0_ready << 1;
    obs |= (uint64_t)t->io_frontend_cfVec_7_ready << 2;
    obs |= (uint64_t)t->io_frontend_backendEmpty << 3;
    obs |= (uint64_t)t->io_toIssueBlock_intUops_0_valid << 4;
    obs |= (uint64_t)t->io_toIssueBlock_intUops_1_valid << 5;
    obs |= (uint64_t)t->io_toIssueBlock_intUops_2_valid << 6;
    obs |= (uint64_t)t->io_toIssueBlock_intUops_3_valid << 7;
    obs |= (uint64_t)t->io_toIssueBlock_intUops_4_valid << 8;
    obs |= (uint64_t)t->io_toIssueBlock_intUops_5_valid << 9;
    obs |= (uint64_t)t->io_toIssueBlock_intUops_6_valid << 10;
    obs |= (uint64_t)t->io_toIssueBlock_intUops_7_valid << 11;
    obs |= (uint64_t)t->io_robio_lsq_lcommit << 12;
    obs |= (uint64_t)t->io_robio_lsq_scommit << 16;
    obs |= (uint64_t)t->io_toMem_lsqEnqIO_needAlloc << 20;
    obs |= (uint64_t)t->io_robio_csr_perfinfo << 36;
    obs |= (uint64_t)t->io_error << 44;
    sum = (sum * 31 + obs) & 0x7fffffffffffffffULL;

    wbp = (uint8_t)((wbp + 4) & 31);

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;
    lfsr ^= lfsr << 17;
  }

  t->final();
  std::printf("xs_mini16: cycles=%llu sum=%llu\n", (unsigned long long)cycles, (unsigned long long)sum);
  delete t;
  return 0;
}
