// Verilator twin of xiangshan/Backend/sim/xs_alu_tb.prp — the same stimulus,
// the same fold, the same printed line, so //bench:xs_alu_sim_verilator can be
// read metric against metric with //bench:xs_alu_sim_verilog.
//
// It is also the ORACLE. The XS drivers assert no golden value in source (see
// xs_alu_tb.prp: they are compile-time and throughput benchmarks, not
// functional coverage), so the ONLY thing that says the two simulators agree
// about `Alu` is that all three of them — `lhd sim` on the .prp tree, `lhd sim`
// on an lg: library read from this .sv, and Verilator on the same .sv — print
// the SAME checksum. bench/common.sh's sim_gate applies the core's `sim_expect`
// (pinned in bench/defs.bzl, at the matched `sim_cycles` count) to all three,
// so a divergence fails a target instead of quietly producing two numbers. Keep
// the pair in lockstep: an edit to the LFSR, the driven fields, the observed
// outputs or the fold order must land in BOTH files — and re-pin `sim_expect`,
// since every one of those changes the checksum.
//
// THE STIMULUS SCHEDULE. `Alu` is purely combinational — 0 `always` blocks, no
// clock and no reset port — so the Pyrope `tick` body lowers to
// drive-then-`step`-then-read where `step` is a settle with nothing to commit.
// One `eval()` per cycle after the drives is exactly that; there is no clock to
// toggle and no reset ramp.
//
// WHAT IS DRIVEN, and why so little: `lhd sim` refuses to WRITE a hierarchical
// path more than one level into a DUT port, and a testbench scalar truncates
// past 64 bits, so xs_alu_tb.prp can reach only `io_in_bits.validPipe` and
// `io_in_bits.ctrlPipe`. This file drives the same two and leaves every other
// input at zero, which is what the Pyrope side leaves them at.
//
// Usage (see bench/sim_verilator.sh for the benched form):
//   verilator --cc --exe --build --top-module Alu -Wno-fatal -DSYNTHESIS \
//       -Ixiangshan/Backend/verilog -F xiangshan/Backend/verilog/filelist.f \
//       xiangshan/Backend/sim/xs_alu_tb_verilator.cpp
//   ./obj_dir/VAlu --cycles 1000
//
// `--cycles N` is spelled the way `lhd sim` spells a test parameter on the
// driver it builds (`--arg cycles=N` reaches drv.bin as `--cycles N`), so the
// two binaries take the same command line.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VAlu.h"
#include "verilated.h"

// `io_in_bits` is one 543-bit packed struct, which Verilator presents as a
// 17-word array rather than as named fields. SystemVerilog packs the FIRST
// declared member into the MOST significant bits, so Alu.sv's
//   {ctrl, ctrlPipe, validPipe, data, dataPipe}  (29, 29, 1, 242, 242 bits)
// lands as:
//   [542:514] ctrl   [513:485] ctrlPipe   [484] validPipe
//   [483:242] data   [241:0]   dataPipe
// which is the same numbering the generated Alu.prp uses (`validPipe` there is
// `(io_in__w1 >> 0x1e4) & 1`, i.e. bit 484).
static constexpr unsigned kValidPipeLsb   = 484;
static constexpr unsigned kCtrlPipeLsb    = 485;
static constexpr unsigned kCtrlPipeWidth  = 29;
static constexpr unsigned kInBitsWords    = 17;

// Deposit `width` (<= 32) bits of `v` at bit `lsb` of a Verilator wide signal.
// Word-at-a-time rather than bit-at-a-time on purpose: this runs inside the
// timed loop, and on a block as small as Alu a 29-iteration bit loop would be
// a measurable share of the "simulation" being benchmarked.
static inline void wide_put(uint32_t* w, unsigned lsb, unsigned width, uint32_t v) {
  const uint32_t mask = width >= 32 ? ~0u : ((1u << width) - 1);
  const unsigned i    = lsb >> 5;
  const unsigned off  = lsb & 31;
  v &= mask;
  w[i] = (w[i] & ~(mask << off)) | (v << off);
  if (off + width > 32) {  // off > 0 here, so the shift below is well defined
    const unsigned rest  = off + width - 32;
    const uint32_t rmask = (1u << rest) - 1;
    w[i + 1] = (w[i + 1] & ~rmask) | ((v >> (32 - off)) & rmask);
  }
}

int main(int argc, char** argv) {
  uint64_t cycles = 1000;

  // Argument shape of the driver `lhd sim` generates, so bench/sim_verilator.sh
  // can hand both binaries the same flags. Unknown flags are an error rather
  // than a silent default: a benchmark that ignored `--cycles` would report a
  // throughput for a run nobody asked for.
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--cycles") && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 0);
    } else if (!std::strcmp(argv[i], "--help") || !std::strcmp(argv[i], "-h")) {
      std::printf("usage: %s [--cycles N]\n", argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "xs_alu_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* top = new VAlu;

  // Every input the Pyrope driver leaves alone is zero there, so zero it here
  // explicitly rather than inheriting whatever --x-initial happens to default
  // to: the checksum is the oracle, and it must not depend on a Verilator flag.
  for (unsigned i = 0; i < kInBitsWords; ++i) top->io_in_bits[i] = 0;
  for (unsigned i = 0; i < 9; ++i) top->io_flush[i] = 0;  // 278 bits
  top->io_instrAddrTransType = 0;
  top->io_in_valid           = 0;
  top->io_out_ready          = 0;

  // xorshift64: deterministic and seeded in source, so the checksum is
  // reproducible on every host and comparable between the two language sides.
  uint64_t lfsr = 0x123456789abcdefULL;
  uint64_t sum  = 0;
  uint64_t obs  = 0;

  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    top->io_in_valid  = (uint8_t)(lfsr & 1);
    top->io_out_ready = (uint8_t)((lfsr >> 1) & 1);

    wide_put(top->io_in_bits.data(), kValidPipeLsb, 1, (uint32_t)((lfsr >> 2) & 1));
    wide_put(top->io_in_bits.data(), kCtrlPipeLsb, kCtrlPipeWidth,
             (uint32_t)((lfsr >> 3) & 0x1fffffffULL));

    top->eval();  // step: settle (Alu has no state to commit)

    obs = top->io_out_bits_res;  // struct packed {logic [63:0] data;}
    obs ^= (uint64_t)(top->io_out_bits_ctrl_robIdx & 0x1ff) << 1;  // .value
    obs ^= (uint64_t)top->io_out_bits_ctrl_pdest << 11;
    obs ^= (uint64_t)top->io_out_valid << 19;
    obs ^= (uint64_t)top->io_in_ready << 20;
    obs ^= (uint64_t)top->io_out_bits_ctrl_toRobValid << 21;
    obs ^= (uint64_t)top->io_out_bits_ctrl_rfWen << 22;

    // Order-sensitive fold: a schedule that computes the right values in the
    // wrong cycle still changes the checksum.
    // Masked to 63 bits so the printed checksum is unambiguously positive.
    sum = ((sum << 1) + obs) & 0x7fffffffffffffffULL;

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;
    lfsr ^= lfsr << 17;
  }

  top->final();
  std::printf("xs_alu: cycles=%llu sum=%llu\n", (unsigned long long)cycles,
              (unsigned long long)sum);
  delete top;
  return 0;
}
