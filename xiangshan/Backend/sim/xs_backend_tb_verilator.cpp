// Verilator twin of xiangshan/Backend/sim/xs_backend_tb.prp — the same
// stimulus, the same fold, the same printed line.
//
// NEITHER driver is wired to a bench target today: `xs_backend` has no `sim_tb`
// in the CORES table of bench/defs.bzl, so there is no `xs_backend_sim_pyrope`
// for this file to be the counterpart of. It is kept next to its .prp so the
// pair stays in lockstep — every driver under this directory has a twin, and
// the day `Backend` gets a sim scenario both sides already exist. See
// xs_alu_tb_verilator.cpp for the contract these twins are held to.
//
// WHAT HAS BEEN VERIFIED, and what has not (2026-08-19): `Backend` verilates
// and this file compiles clean against the generated `VBackend.h`, so the port
// names and widths it drives are real. It has never been RUN, and there is no
// checksum to compare against because the Pyrope side has no scenario either.
// Before wiring one, know the cost measured here: verilating `Backend` alone
// takes 348 s and 15.8 GB, and emits 1.5 GB of C++ in 748 translation units —
// `Rob`, at 176 MB in 65 units, already costs ~415 s of clang at -j8. That is
// an hour-scale target, not a routine-loop one.
//
// THE STIMULUS SCHEDULE. `Backend` declares `clock` and `reset`, so the Pyrope
// driver's `tick cycles clocks=(clock=1)` body is drive / `step` / read, where
// `step` is settle -> commit -> settle. Two eval()s reproduce it:
//
//   eval() @clock=0   settle with this cycle's inputs applied
//   eval() @clock=1   the posedge == step(); the reads below then see the
//                     post-edge value
//
// Every read is BELOW the `step`, so there is no third eval (dino's twin needs
// one for a read placed above its step).
//
// Usage:
//   verilator --cc --exe --build --top-module Backend -Wno-fatal -DSYNTHESIS \
//       -Ixiangshan/Backend/verilog -F xiangshan/Backend/verilog/filelist.f \
//       xiangshan/Backend/sim/xs_backend_tb_verilator.cpp
//   ./obj_dir/VBackend --cycles 1000
//
// `--cycles N` is spelled the way `lhd sim` spells a test parameter on the
// driver it builds (`--arg cycles=N` reaches drv.bin as `--cycles N`), so the
// two binaries take the same command line.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VBackend.h"
#include "verilated.h"

int main(int argc, char** argv) {
  uint64_t cycles = 1000;

  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--cycles") && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 0);
    } else if (!std::strcmp(argv[i], "--help") || !std::strcmp(argv[i], "-h")) {
      std::printf("usage: %s [--cycles N]\n", argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "xs_backend_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* top = new VBackend;

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

    top->io_fenceio_sbuffer_sbIsEmpty = (uint8_t)(lfsr & 1);
    top->io_frontend_cfVec_0_valid    = (uint8_t)((lfsr >> 1) & 1);
    top->io_frontend_cfVec_1_valid    = (uint8_t)((lfsr >> 2) & 1);
    top->io_frontend_cfVec_2_valid    = (uint8_t)((lfsr >> 3) & 1);
    top->io_frontend_cfVec_3_valid    = (uint8_t)((lfsr >> 4) & 1);
    top->io_frontend_wfi_wfiSafe      = (uint8_t)((lfsr >> 5) & 1);
    top->eval();  // settle with this cycle's inputs

    top->clock = 1;
    top->eval();  // posedge == step(); outputs now hold the post-step value

    obs = top->io_fenceio_fencei;
    obs |= (uint64_t)top->io_fenceio_sbuffer_flushSb << 1;
    obs |= (uint64_t)top->io_frontend_cfVec_0_ready << 2;
    obs |= (uint64_t)top->io_frontend_cfVec_1_ready << 3;
    obs |= (uint64_t)top->io_frontend_cfVec_2_ready << 4;
    obs |= (uint64_t)top->io_frontend_cfVec_3_ready << 5;

    // Order-sensitive fold: a schedule that computes the right values in the
    // wrong cycle still changes the checksum.
    // Masked to 63 bits so the printed checksum is unambiguously positive.
    sum = ((sum << 1) + obs) & 0x7fffffffffffffffULL;

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;  // the Pyrope side spells this `lfsr#[7..=63]`; see there
    lfsr ^= lfsr << 17;
  }

  top->final();
  std::printf("xs_backend: cycles=%llu sum=%llu\n", (unsigned long long)cycles,
              (unsigned long long)sum);
  delete top;
  return 0;
}
