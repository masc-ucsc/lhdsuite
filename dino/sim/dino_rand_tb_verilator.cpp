// Verilator twin of dino/sim/dino_rand_tb.prp: the same xorshift64 instruction
// generator, the same mid-run reset, the same per-cycle output checksum. It is an
// independent (non-LiveHD) oracle: build it once against the original Verilog and
// once against `lhd compile ... --emit verilog:` of dino/pyrope2 and compare the
// printed checksum with `lhd sim`'s.
//   verilator --cc --exe --build --top-module PipelinedDualIssueCPU \
//       -DSYNTHESIS -F dino/verilog/filelist.f dino/sim/dino_rand_tb_verilator.cpp
//   ./obj_dir/VPipelinedDualIssueCPU --cycles 20000 --seed 1
// Keep the generator in lockstep with the .prp: any edit lands in both files.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VPipelinedDualIssueCPU.h"
#include "verilated.h"

static inline uint64_t bits(uint64_t x, int lo, int hi) { return (x >> lo) & ((1ULL << (hi - lo + 1)) - 1); }
static inline uint64_t step64(uint64_t x) {
  x ^= x << 13;
  x ^= x >> 7;
  x ^= x << 17;
  return x;
}
static uint64_t pick_op(uint64_t r) {
  switch (bits(r, 0, 3)) {
    case 0: return 0x33;  case 1: return 0x13;  case 2: return 0x3b;  case 3: return 0x1b;
    case 4: return 0x03;  case 5: return 0x23;  case 6: return 0x63;  case 7: return 0x37;
    case 8: return 0x17;  case 9: return 0x6f;  case 10: return 0x67; case 11: return 0x13;
    case 12: case 13: return 0x23;
    case 14: return 0x33;
    default: return bits(r, 56, 62);
  }
}
static uint32_t make_inst(uint64_t r) {
  const bool     wide = bits(r, 48, 49) == 0;
  const uint64_t f7   = bits(r, 27, 29) == 0 ? bits(r, 20, 26) : (bits(r, 30, 30) << 5);
  const uint64_t rd   = wide ? bits(r, 4, 8) : bits(r, 4, 6);
  const uint64_t rs1  = wide ? bits(r, 10, 14) : bits(r, 10, 12);
  const uint64_t rs2  = wide ? bits(r, 15, 19) : bits(r, 13, 15);
  return (uint32_t)(pick_op(r) | (rd << 7) | (bits(r, 7, 9) << 12) | (rs1 << 15) | (rs2 << 20) | (f7 << 25));
}

int main(int argc, char** argv) {
  uint64_t cycles = 20000, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--cycles") && i + 1 < argc) cycles = std::strtoull(argv[++i], nullptr, 0);
    else if (!std::strcmp(argv[i], "--seed") && i + 1 < argc) seed = std::strtoull(argv[++i], nullptr, 0);
    else { std::fprintf(stderr, "unknown argument '%s'\n", argv[i]); return 2; }
  }
  Verilated::commandArgs(argc, argv);
  auto* top = new VPipelinedDualIssueCPU;

  uint64_t lfsr = 0x9E3779B97F4A7C15ULL ^ (seed & 0xFFFFFFFFULL);
  uint64_t chk = 0xCBF29CE484222325ULL, last_pc = 0, stores = 0, jumps = 0;
  top->clock = 0;
  for (uint64_t clock = 0; clock < cycles; ++clock) {
    top->reset         = (clock < 2) || (clock >= 3000 && clock < 3003);
    top->io_imem_good  = 1;
    top->io_imem_ready = 1;
    top->io_dmem_good  = 1;
    lfsr = step64(lfsr);
    const uint64_t ra = lfsr;
    lfsr = step64(lfsr);
    const uint64_t rb = lfsr;
    lfsr = step64(lfsr);
    top->io_dmem_readdata    = lfsr;
    top->io_imem_instruction = ((uint64_t)make_inst(rb) << 32) | make_inst(ra);
    top->clock = 0;
    top->eval();
    top->clock = 1;
    top->eval();  // posedge; outputs below are the settled post-edge values, as after `step`
    const uint64_t pc = top->io_imem_address;
    uint64_t sample = pc ^ (top->io_dmem_address << 1) ^ (top->io_dmem_writedata << 3);
    sample += (uint64_t)top->io_dmem_memread + ((uint64_t)top->io_dmem_memwrite << 1) +
              ((uint64_t)top->io_dmem_valid << 2) + ((uint64_t)top->io_dmem_maskmode << 3) +
              ((uint64_t)top->io_dmem_sext << 5) + (uint64_t)top->io_imem_valid;
    chk = (chk ^ sample) * 0x100000001B3ULL;
    if (top->io_dmem_memwrite) ++stores;
    if (pc != last_pc + 4 && pc != last_pc + 8) ++jumps;
    last_pc = pc;
  }
  std::printf("dino rand: cycles=%llu checksum=%llu stores=%llu pc_jumps=%llu pc=%llu\n", (unsigned long long)cycles,
              (unsigned long long)chk, (unsigned long long)stores, (unsigned long long)jumps, (unsigned long long)last_pc);
  delete top;
  return 0;
}
