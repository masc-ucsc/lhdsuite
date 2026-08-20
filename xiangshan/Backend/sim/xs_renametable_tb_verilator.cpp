// Verilator twin of xiangshan/Backend/sim/xs_renametable_tb.prp — the same
// stimulus, the same fold, the same printed line, so
// //bench:xs_renametable_sim_verilator can be read metric against metric with
// //bench:xs_renametable_sim_verilog.
//
// It is also the ORACLE: the XS drivers assert no golden value in source (see
// xs_alu_tb.prp for why), so what says the simulators agree about
// `RenameTableWrapper` is that `lhd sim` on the .prp tree, `lhd sim` on an lg:
// library read from this .sv, and Verilator on the same .sv all print the SAME
// checksum. bench/common.sh's sim_gate applies $CORE_SIM_EXPECT to all three.
// Keep the pair in lockstep: an edit to the LFSR, the driven ports, the
// observed outputs or the fold order must land in BOTH files — and re-pin
// `sim_expect` in bench/defs.bzl, since each of those changes the checksum.
//
// THE STIMULUS SCHEDULE. `RenameTableWrapper` declares `clock` and `reset`, so
// the Pyrope driver's `tick cycles clocks=(clock=1)` body is drive / `step` /
// read, where `step` is settle -> commit -> settle. Two eval()s reproduce it:
//
//   eval() @clock=0   settle with this cycle's inputs applied
//   eval() @clock=1   the posedge == step(); the reads below then see the
//                     post-edge value
//
// Every read here is BELOW the `step`, so there is no third eval (dino's twin
// needs one for a read placed above its step). Do not collapse the pair into a
// single toggle — that moves every read one cycle.
//
// WHAT IS DRIVEN: the rename/commit datapath is bundles and >64-bit vectors
// (io_intRenamePorts is u112, io_diffCommits.info is u10400) and a testbench
// scalar truncates past 64 bits, so the Pyrope driver leaves it at its default
// and moves the READ ports. This file drives exactly the same ports.
//
// Usage (see bench/sim_verilator.sh for the benched form):
//   verilator --cc --exe --build --top-module RenameTableWrapper -Wno-fatal \
//       -DSYNTHESIS -Ixiangshan/Backend/verilog \
//       -F xiangshan/Backend/verilog/filelist.f \
//       xiangshan/Backend/sim/xs_renametable_tb_verilator.cpp
//   ./obj_dir/VRenameTableWrapper --cycles 1000
//
// `--cycles N` is spelled the way `lhd sim` spells a test parameter on the
// driver it builds (`--arg cycles=N` reaches drv.bin as `--cycles N`), so the
// two binaries take the same command line.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VRenameTableWrapper.h"
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
      std::fprintf(stderr, "xs_renametable_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* top = new VRenameTableWrapper;

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

    top->io_hartId   = (uint8_t)(lfsr & 0xff);
    top->io_redirect = (uint8_t)((lfsr >> 8) & 1);

    // Two read ports per file, driven from disjoint LFSR slices so the three
    // register files see different address streams.
    top->io_intReadPorts_0_0_hold = (uint8_t)((lfsr >> 9) & 1);
    top->io_intReadPorts_0_0_addr = (uint8_t)((lfsr >> 10) & 0x1f);
    top->io_intReadPorts_1_1_hold = (uint8_t)((lfsr >> 15) & 1);
    top->io_intReadPorts_1_1_addr = (uint8_t)((lfsr >> 16) & 0x1f);
    top->io_fpReadPorts_0_0_hold  = (uint8_t)((lfsr >> 21) & 1);
    top->io_fpReadPorts_0_0_addr  = (uint8_t)((lfsr >> 22) & 0x3f);
    top->io_fpReadPorts_2_1_hold  = (uint8_t)((lfsr >> 28) & 1);
    top->io_fpReadPorts_2_1_addr  = (uint8_t)((lfsr >> 29) & 0x3f);
    top->io_vecReadPorts_0_0_hold = (uint8_t)((lfsr >> 35) & 1);
    top->io_vecReadPorts_0_0_addr = (uint8_t)((lfsr >> 36) & 0x3f);
    top->io_vecReadPorts_3_2_hold = (uint8_t)((lfsr >> 42) & 1);
    top->io_vecReadPorts_3_2_addr = (uint8_t)((lfsr >> 43) & 0x3f);
    top->eval();  // settle with this cycle's inputs

    top->clock = 1;
    top->eval();  // posedge == step(); outputs now hold the post-step value

    obs = top->io_intReadPorts_0_0_data;
    obs |= (uint64_t)top->io_intReadPorts_1_1_data << 8;
    obs |= (uint64_t)top->io_fpReadPorts_0_0_data << 16;
    obs |= (uint64_t)top->io_fpReadPorts_2_1_data << 24;
    obs |= (uint64_t)top->io_vecReadPorts_0_0_data << 32;
    obs |= (uint64_t)top->io_vecReadPorts_3_2_data << 40;

    // Order-sensitive fold: a schedule that computes the right values in the
    // wrong cycle still changes the checksum.
    // Masked to 63 bits so the printed checksum is unambiguously positive.
    sum = ((sum << 1) + obs) & 0x7fffffffffffffffULL;

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;  // the Pyrope side spells this `lfsr#[7..=63]`; see there
    lfsr ^= lfsr << 17;
  }

  top->final();
  std::printf("xs_renametable: cycles=%llu sum=%llu\n", (unsigned long long)cycles,
              (unsigned long long)sum);
  delete top;
  return 0;
}
