// Verilator twin of xiangshan/Backend/sim/xs_rob_tb.prp — the same stimulus,
// the same fold, the same printed line, so //bench:xs_rob_sim_verilator can be
// read metric against metric with //bench:xs_rob_sim_verilog.
//
// It is also the ORACLE: the XS drivers assert no golden value in source (see
// xs_alu_tb.prp for why), so what says the simulators agree about `Rob` is that
// `lhd sim` on the .prp tree, `lhd sim` on an lg: library read from this .sv,
// and Verilator on the same .sv all print the SAME checksum. bench/common.sh's
// sim_gate applies $CORE_SIM_EXPECT to all three. Keep the pair in lockstep: an
// edit to the LFSR, the driven ports, the observed outputs or the fold order
// must land in BOTH files — and re-pin `sim_expect`, since each of those
// changes the checksum.
//
// THE X-FILL, which this block needs and the other two do not. `Rob` has
// reset-free flops (walkPtrVec, walkPtrTrue, lastWalkPtr are plain
// `always @(posedge clock)`) whose power-on bits reach io_enq_isEmpty and
// io_enq_canAccept. Verilator is 2-state and zero-fills them; `lhd sim` draws
// each unknown bit from the run's seeded PRNG, so its checksum moved with
// `--seed`. That is why xs_rob's CORES entry carries
// `sim_sets: --set sim.unknown_zero=true` — with it the three simulators agree
// exactly. Nothing to do on this side: zero-fill is already what Verilator does.
//
// THE STIMULUS SCHEDULE. `Rob` declares `clock` and `reset`, so the Pyrope
// driver's `tick cycles clocks=(clock=1)` body is drive / `step` / read, where
// `step` is settle -> commit -> settle. Two eval()s reproduce it:
//
//   eval() @clock=0   settle with this cycle's inputs applied, i.e. the
//                     combinational state the flops will sample
//   eval() @clock=1   the posedge == step(); after it the outputs already hold
//                     the post-edge value, which is what the reads below see
//
// Unlike dino's twin there is no third eval, because this driver places NO read
// above its `step` — every read is of the post-step value. Do not "simplify"
// the pair into a single toggle: that would move the reads a cycle and the two
// benchmarks would stop being comparable.
//
// WHAT IS DRIVEN, and why so little: `Rob`'s real enqueue port `io_enq_req` is
// 4080 bits wide and a testbench scalar truncates past 64, so the dispatch
// datapath cannot be driven from the Pyrope side at all. This file drives
// exactly the same plain scalars it does.
//
// Usage (see bench/sim_verilator.sh for the benched form):
//   verilator --cc --exe --build --top-module Rob -Wno-fatal -DSYNTHESIS \
//       -Ixiangshan/Backend/verilog -F xiangshan/Backend/verilog/filelist.f \
//       xiangshan/Backend/sim/xs_rob_tb_verilator.cpp
//   ./obj_dir/VRob --cycles 1000
//
// `--cycles N` is spelled the way `lhd sim` spells a test parameter on the
// driver it builds (`--arg cycles=N` reaches drv.bin as `--cycles N`), so the
// two binaries take the same command line.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VRob.h"
#include "verilated.h"

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
      std::fprintf(stderr, "xs_rob_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* top = new VRob;

  // xorshift64: deterministic and seeded in source, so the checksum is
  // reproducible on every host and comparable between the two language sides.
  uint64_t lfsr = 0x123456789abcdefULL;
  uint64_t sum  = 0;
  uint64_t obs  = 0;

  top->clock = 0;
  top->reset = 1;

  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    top->clock = 0;
    top->reset = (cycle < 2);

    top->io_hartId            = 0;
    top->io_enq_needAlloc     = (uint8_t)(lfsr & 0xff);
    top->io_writeback_19_valid = (uint8_t)((lfsr >> 8) & 1);
    top->io_writeback_18_valid = (uint8_t)((lfsr >> 9) & 1);
    top->io_writeback_17_valid = (uint8_t)((lfsr >> 10) & 1);
    top->eval();  // settle with this cycle's inputs

    top->clock = 1;
    top->eval();  // posedge == step(); outputs now hold the post-step value

    obs = top->io_enq_canAccept;
    obs |= (uint64_t)top->io_enq_canAcceptForDispatch << 1;
    obs |= (uint64_t)top->io_enq_isEmpty << 2;
    obs |= (uint64_t)top->io_robFull << 3;
    obs |= (uint64_t)top->io_cpu_wfi << 4;
    obs |= (uint64_t)top->io_lsq_lcommit << 8;
    obs |= (uint64_t)top->io_lsq_scommit << 12;

    // Order-sensitive fold: a schedule that computes the right values in the
    // wrong cycle still changes the checksum.
    // Masked to 63 bits so the printed checksum is unambiguously positive.
    sum = ((sum << 1) + obs) & 0x7fffffffffffffffULL;

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;  // the Pyrope side spells this `lfsr#[7..=63]`; see there
    lfsr ^= lfsr << 17;
  }

  top->final();
  std::printf("xs_rob: cycles=%llu sum=%llu\n", (unsigned long long)cycles,
              (unsigned long long)sum);
  delete top;
  return 0;
}
