// Verilator twin of dino/sim/dino_prog_tb.prp — the SAME program, the same
// stimulus schedule, the same asserts and the same printed line, so
// //bench:dino_sim_verilator can be compared against //bench:dino_sim_verilog
// metric for metric (both gate on CORE_SIM_MARKER + CORE_SIM_EXPECT, so a
// divergence between the two simulators fails a target instead of quietly
// producing two different numbers).
//
// It is also a cross-simulator ORACLE: `lhd sim` and Verilator run the same
// RTL through the same driver, so if they disagree on x2/x3/done_cycle one of
// them has a codegen bug. Keep the two files in lockstep — an edit to the
// program, the ROM index or the drive/read order must land in both.
//
// THE STIMULUS SCHEDULE. `lhd sim` lowers the Pyrope `tick` body to
//   drive(reset, imem_good, imem_ready); read(io_imem_address); drive(instr,
//   dmem_good, dmem_readdata); step(); read(io_dmem_*)
// where a read is a reference into the design's settled outputs and `step` is
// settle -> commit -> settle (the trailing settle is what leaves those outputs
// holding the post-edge value). The three eval()s below are exactly that:
//
//   eval() @clock=0   the pre-fetch read — io_imem_address is the address the
//                     CPU is asking for THIS cycle (io_imem_instruction still
//                     holds the previous cycle's word, as in the Pyrope tb).
//                     io_imem_address is `pc[63:0]`, a pure register read, so
//                     it does not depend on the inputs driven just above it —
//                     which is why this read stays valid now that a pre-step
//                     read observes the PREVIOUS settle rather than
//                     recomputing against the just-driven inputs.
//   eval() @clock=0   settle again with the fetched word applied, i.e. the
//                     combinational state the flops will sample
//   eval() @clock=1   the posedge — step(); after it the outputs already
//                     reflect the new register state, which is the post-step
//                     read the Pyrope driver does on io_dmem_*
//
// Getting this wrong does not fail loudly, it shifts `done at cycle N` by one
// and the two benchmarks stop being comparable — so do not "simplify" it into
// the usual two-eval clock toggle.
//
// Usage (see bench/sim_verilator.sh for the benched form):
//   verilator --cc --exe --build --top-module PipelinedDualIssueCPU \
//       -DSYNTHESIS -F dino/verilog/filelist.f dino/sim/dino_prog_tb_verilator.cpp
//   ./obj_dir/VPipelinedDualIssueCPU --cycles 1000000
//
// `--cycles N` is spelled the way `lhd sim` spells a test parameter on the
// driver it builds (`--arg cycles=N` reaches drv.bin as `--cycles N`), so the
// two binaries take the same command line.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VPipelinedDualIssueCPU.h"
#include "verilated.h"

// The program, byte-for-byte the `rom` of dino_prog_tb.prp: a loop that
// INCREMENTS x2 and DECREMENTS x3, then stores both to dmem. The testbench
// taps the store bus to check x2 == iters and x3 == -(iters + 2) (the +2: the
// branch-shadow addi pair at 0x94/0x98 is flushed on every taken bne but
// architecturally EXECUTES once, on the final fall-through).
static const uint32_t kRom[64] = {
    0x00000093,  // [0]  addi x1,  x0, 0
    0x00000113,  // [1]  addi x2,  x0, 0
    0x00000193,  // [2]  addi x3,  x0, 0
    0x00000213,  // [3]  addi x4,  x0, 0
    0x00000293,  // [4]  addi x5,  x0, 0
    0x00000313,  // [5]  addi x6,  x0, 0
    0x00000393,  // [6]  addi x7,  x0, 0
    0x00000413,  // [7]  addi x8,  x0, 0
    0x00000493,  // [8]  addi x9,  x0, 0
    0x00000513,  // [9]  addi x10, x0, 0
    0x00000593,  // [10] addi x11, x0, 0
    0x00000613,  // [11] addi x12, x0, 0
    0x00000693,  // [12] addi x13, x0, 0
    0x00000713,  // [13] addi x14, x0, 0
    0x00000793,  // [14] addi x15, x0, 0
    0x00000813,  // [15] addi x16, x0, 0
    0x00000893,  // [16] addi x17, x0, 0
    0x00000913,  // [17] addi x18, x0, 0
    0x00000993,  // [18] addi x19, x0, 0
    0x00000A13,  // [19] addi x20, x0, 0
    0x00000A93,  // [20] addi x21, x0, 0
    0x00000B13,  // [21] addi x22, x0, 0
    0x00000B93,  // [22] addi x23, x0, 0
    0x00000C13,  // [23] addi x24, x0, 0
    0x00000C93,  // [24] addi x25, x0, 0
    0x00000D13,  // [25] addi x26, x0, 0
    0x00000D93,  // [26] addi x27, x0, 0
    0x00000E13,  // [27] addi x28, x0, 0
    0x00000E93,  // [28] addi x29, x0, 0
    0x00000F13,  // [29] addi x30, x0, 0
    0x00000F93,  // [30] addi x31, x0, 0
    0x00000013,  // [31] nop; align the workload to a fetch pair
    0x06400093,  // [32] addi x1, x0, 100; iteration bound
    0x00000013,  // [33] nop
    0x00110113,  // [34] addi x2, x2, 1; loop, dual-issued pair...
    0xFFF18193,  // [35] addi x3, x3, -1; ...independent, same fetch
    0xFE111CE3,  // [36] bne  x2, x1, -8; until x2 == x1 (-> [34])
    0xFFF18193,  // [37] addi x3, x3, -1; flushed while branch taken
    0xFFF18193,  // [38] addi x3, x3, -1; flushed while branch taken
    0x00000013,  // [39] nop; write-back before the stores
    0x00203023,  // [40] sd   x2, 0(x0); expose x2 to the tb
    0x00303423,  // [41] sd   x3, 8(x0); expose x3 to the tb
    0x00000063,  // [42] beq  x0, x0, 0; spin forever
    0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013,
    0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013,
    0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013,
};

// One failed check = one printed line + a non-zero exit, mirroring the way an
// `assert(cond, "msg")` in a Pyrope `test` block reports and fails.
static int  failures = 0;
static void check(bool cond, const char* msg) {
  if (!cond) {
    std::printf("dino_prog_tb_verilator.cpp:assert fail: %s\n", msg);
    ++failures;
  }
}

int main(int argc, char** argv) {
  uint64_t cycles = 1000000;

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
      std::fprintf(stderr, "dino_prog_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* top = new VPipelinedDualIssueCPU;

  uint64_t st0        = 0;  // sd x2,0(x0) data
  int64_t  st8        = 0;  // sd x3,8(x0) data (signed: the tb asserts -102)
  bool     got0       = false;
  bool     got8       = false;
  uint64_t done_cycle = 0;

  top->clock               = 0;
  top->reset               = 1;
  top->io_imem_good        = 0;
  top->io_imem_ready       = 0;
  top->io_imem_instruction = 0;
  top->io_dmem_good        = 0;
  top->io_dmem_readdata    = 0;

  for (uint64_t clock = 0; clock < cycles; ++clock) {
    top->clock         = 0;
    top->reset         = (clock < 2);
    top->io_imem_good  = 1;
    top->io_imem_ready = 1;
    top->eval();  // pre-fetch peek: io_imem_address for THIS cycle

    // 2 consecutive 32-bit slots from the aligned fetch address (mask to 64).
    // No RISC-V compress, so the pair is always 8-byte aligned.
    const uint64_t i         = (top->io_imem_address >> 2) & 0x3E;
    top->io_imem_instruction = (uint64_t)kRom[i] | ((uint64_t)kRom[i + 1] << 32);
    top->io_dmem_good        = 1;
    top->io_dmem_readdata    = 0;
    top->eval();  // settle with the fetched word applied

    top->clock = 1;
    top->eval();  // posedge == step(); outputs now hold the post-step peek

    if (top->io_dmem_memwrite) {
      if (top->io_dmem_address == 0) {
        st0  = top->io_dmem_writedata;
        got0 = true;
      } else if (top->io_dmem_address == 8) {
        st8  = (int64_t)top->io_dmem_writedata;
        got8 = true;
      }
    }
    if (done_cycle == 0 && got0 && got8) {
      done_cycle = clock;
    }
  }

  top->final();

  check(got0 && got8, "program stored both counters");
  check(st0 == 100, "x2 counted up to the iteration bound");
  check(st8 == -102, "x3 counted down in lockstep: x3 == -(100 + 2)");

  // Committed instructions: 31 register clears + 1 setup
  //                         + 100*(addi,addi,bne) + 2 stores = 334
  // (nops excluded). IPC in milli-units to stay integer-friendly.
  const uint64_t ipc_milli = done_cycle > 0 ? (334 * 1000) / done_cycle : 0;
  const int64_t  neg_x3    = -st8;
  std::printf("dino program: x2=%llu -x3=%lld, done at cycle %llu, IPC=%llu milli-instr/cycle\n",
              (unsigned long long)st0,
              (long long)neg_x3,
              (unsigned long long)done_cycle,
              (unsigned long long)ipc_milli);
  if (failures) {
    std::printf("FAIL cpu.prog (%d assert(s))\n", failures);
  } else {
    std::printf("PASS cpu.prog\n");
  }

  delete top;
  return failures ? 1 : 0;
}
