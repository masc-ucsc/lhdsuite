// Verilator twin of gemmini/Mesh8/sim/gemmini_tb.prp (8x8 mesh): the same stimulus, the same fold, the same printed line, so
// //bench:gemmini_sim_verilator can be read metric against metric with the lhd sim targets, and the three
// simulators (lhd sim on the .prp tree, lhd sim on an lg: library from the .sv, Verilator) must print the SAME
// checksum (sim_expect). Keep the pair in lockstep: an edit to the xorshift, the driven ports, the observed outputs
// or the fold order must land in BOTH files, and re-pin sim_expect.
//
// DUT: GemminiTPU itself (bench/sim_verilator.sh verilates the core top). Its packed-struct ports are packed and
// unpacked here exactly as the flat-port wrapper GemminiSimTop (sim/GemminiSimTop.prp, verilog/GemminiSimTop.sv,
// LEC-proven equal to each other) does for the lhd sim drivers.
// Schedule: the Pyrope driver is drive / step / read with no read above its step, so two eval()s reproduce it
// (clock=0 settle with this cycle's inputs, clock=1 posedge == step; reads see the post-edge value), as in
// xs_rob_tb_verilator.cpp.
//
// Usage (see bench/sim_verilator.sh for the benched form):
//   verilator --cc --exe --build --top-module GemminiTPU -Wno-fatal -DSYNTHESIS \
//       -Igemmini/verilog -F gemmini/verilog/filelist.f gemmini/sim/gemmini_tb_verilator.cpp
//   ./obj_dir/VGemminiTPU --cycles 1000

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VGemminiTPU.h"
#include "verilated.h"

static inline uint64_t bits(uint64_t v, int lo, int n) { return (v >> lo) & ((n == 64) ? ~0ULL : ((1ULL << n) - 1)); }

// Bit-field access on a Verilator wide port (32-bit words, LSB first).
template <typename W> static void wset(W& w, int lo, int n, uint64_t v) {
  for (int i = 0; i < n; ++i) {
    const int b = lo + i;
    const uint32_t m = 1u << (b % 32);
    if ((v >> i) & 1) w[b / 32] |= m; else w[b / 32] &= ~m;
  }
}
template <typename W> static uint64_t wget(const W& w, int lo, int n) {
  uint64_t v = 0;
  for (int i = 0; i < n; ++i) v |= (uint64_t)((w[(lo + i) / 32] >> ((lo + i) % 32)) & 1) << i;
  return v;
}

int main(int argc, char** argv) {
  uint64_t cycles = 1000;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--cycles") && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 0);
    } else if (!std::strcmp(argv[i], "--help") || !std::strcmp(argv[i], "-h")) {
      std::printf("usage: %s [--cycles N]\n", argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "gemmini_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* t = new VGemminiTPU;

  uint64_t lfsr = 0x123456789abcdefULL;
  uint64_t sum  = 0;
  uint64_t obs  = 0;

  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    t->clock = 0;
    t->reset = (cycle < 4);

    t->io_mesh_a_valid = bits(lfsr, 0, 1);
    t->io_mesh_a_bits  = lfsr;
    t->io_mesh_b_valid = bits(lfsr, 1, 1);
    t->io_mesh_b_bits  = lfsr >> 1;
    t->io_mesh_d_valid = bits(lfsr, 2, 1);
    t->io_mesh_d_bits  = lfsr >> 2;
    t->io_mesh_req_valid = bits(lfsr, 3, 1);
    t->io_mesh_req_bits = (bits(lfsr, 20, 1) << 15) | (bits(lfsr, 21, 1) << 14) | (bits(lfsr, 22, 1) << 13) |
                          (bits(lfsr, 23, 5) << 8) | (bits(lfsr, 28, 1) << 7) | (bits(lfsr, 29, 1) << 6) |
                          (bits(lfsr, 30, 4) << 2) | bits(lfsr, 34, 2);
    t->io_acc_write_valid = bits(lfsr, 4, 1);
    wset(t->io_acc_write_bits, 289, 6, bits(lfsr, 35, 6));
    wset(t->io_acc_write_bits, 225, 64, lfsr >> 3);  // data[255:192] = lfsr#[3..=63]
    wset(t->io_acc_write_bits, 161, 64, lfsr >> 2);  // data[191:128]
    wset(t->io_acc_write_bits, 97, 64, lfsr >> 1);   // data[127:64]
    wset(t->io_acc_write_bits, 33, 64, lfsr);        // data[63:0]
    wset(t->io_acc_write_bits, 32, 1, bits(lfsr, 41, 1));
    wset(t->io_acc_write_bits, 0, 32, bits(lfsr, 24, 32));
    t->io_acc_read_req_valid = bits(lfsr, 5, 1);
    wset(t->io_acc_read_req_bits, 139, 32, bits(lfsr, 0, 32));
    wset(t->io_acc_read_req_bits, 133, 6, bits(lfsr, 44, 6));
    wset(t->io_acc_read_req_bits, 5, 128, 0);
    wset(t->io_acc_read_req_bits, 2, 3, bits(lfsr, 50, 3));
    wset(t->io_acc_read_req_bits, 1, 1, bits(lfsr, 53, 1));
    wset(t->io_acc_read_req_bits, 0, 1, bits(lfsr, 54, 1));
    t->io_acc_read_resp_ready = bits(lfsr, 6, 1);
    t->eval();  // settle with this cycle's inputs

    t->clock = 1;
    t->eval();  // posedge == step(); outputs now hold the post-step value

    const auto& mr = t->io_mesh_resp;
    const auto& rr = t->io_acc_read_resp_bits;
    obs = t->io_mesh_a_ready;
    obs |= (uint64_t)t->io_mesh_b_ready << 1;
    obs |= (uint64_t)t->io_mesh_d_ready << 2;
    obs |= (uint64_t)t->io_mesh_req_ready << 3;
    obs |= (uint64_t)t->io_acc_write_ready << 4;
    obs |= (uint64_t)t->io_acc_read_req_ready << 5;
    obs |= (uint64_t)t->io_acc_read_resp_valid << 6;
    obs |= wget(mr, 262, 1) << 7;   // valid
    obs |= wget(mr, 261, 1) << 8;   // tag.id
    obs |= wget(mr, 0, 1) << 9;     // last
    obs ^= wget(mr, 1, 4) << 10;    // total_rows
    obs |= wget(rr, 165, 1) << 13;  // fromDMA
    obs |= wget(rr, 2, 3) << 14;    // act
    obs |= wget(rr, 0, 2) << 17;    // acc_bank_id
    obs ^= wget(rr, 133, 32) << 20; // scale
    for (int k = 0; k < 4; ++k) obs ^= wget(mr, 5 + 64 * k, 63);    // resp data word k, low 63 bits
    for (int k = 0; k < 4; ++k) obs ^= wget(rr, 166 + 64 * k, 63);  // read data word k, low 63 bits

    sum = ((sum << 1) + obs) & 0x7fffffffffffffffULL;

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;  // the Pyrope side spells this `lfsr#[7..=63]`
    lfsr ^= lfsr << 17;
  }

  t->final();
  std::printf("gemmini8: cycles=%llu sum=%llu\n", (unsigned long long)cycles, (unsigned long long)sum);
  delete t;
  return 0;
}
