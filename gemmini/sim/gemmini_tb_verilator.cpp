// Verilator twin of gemmini/sim/gemmini_tb.prp: the same stimulus, the same fold, the same printed line, so
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
    t->io_mesh_a_bits  = bits(lfsr, 0, 32);
    t->io_mesh_b_valid = bits(lfsr, 1, 1);
    t->io_mesh_b_bits  = bits(lfsr, 8, 32);
    t->io_mesh_d_valid = bits(lfsr, 2, 1);
    t->io_mesh_d_bits  = bits(lfsr, 16, 32);
    t->io_mesh_req_valid = bits(lfsr, 3, 1);
    // {tag.id, pe_control.dataflow, pe_control.propagate, pe_control.shift[4:0], a_transpose, bd_transpose,
    //  total_rows[2:0], flush[1:0]}
    t->io_mesh_req_bits = (bits(lfsr, 20, 1) << 14) | (bits(lfsr, 21, 1) << 13) | (bits(lfsr, 22, 1) << 12) |
                          (bits(lfsr, 23, 5) << 7) | (bits(lfsr, 28, 1) << 6) | (bits(lfsr, 29, 1) << 5) |
                          (bits(lfsr, 30, 3) << 2) | bits(lfsr, 33, 2);
    t->io_acc_write_valid = bits(lfsr, 4, 1);
    // {addr[5:0], data[127:0], acc, mask[15:0]}; data = {wr_data_hi, wr_data_lo}
    wset(t->io_acc_write_bits, 145, 6, bits(lfsr, 35, 6));
    wset(t->io_acc_write_bits, 81, 64, lfsr >> 1);  // data[127:64] = lfsr#[1..=63]
    wset(t->io_acc_write_bits, 17, 64, lfsr);       // data[63:0]
    wset(t->io_acc_write_bits, 16, 1, bits(lfsr, 41, 1));
    wset(t->io_acc_write_bits, 0, 16, bits(lfsr, 42, 16));
    t->io_acc_read_req_valid = bits(lfsr, 5, 1);
    // {scale[31:0], addr[5:0], igelu_qb, igelu_qc, iexp_qln2, iexp_qln2_inv (all 0), act[2:0], full, fromDMA}
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

    // io_mesh_resp = {valid, tag.id, data[127:0], total_rows[2:0], last};
    // io_acc_read_resp_bits = {data[127:0], fromDMA, scale[31:0], igelu_qb, igelu_qc, iexp_qln2, iexp_qln2_inv,
    //                          act[2:0], acc_bank_id[1:0]}
    const auto& mr = t->io_mesh_resp;
    const auto& rr = t->io_acc_read_resp_bits;
    obs = t->io_mesh_a_ready;
    obs |= (uint64_t)t->io_mesh_b_ready << 1;
    obs |= (uint64_t)t->io_mesh_d_ready << 2;
    obs |= (uint64_t)t->io_mesh_req_ready << 3;
    obs |= (uint64_t)t->io_acc_write_ready << 4;
    obs |= (uint64_t)t->io_acc_read_req_ready << 5;
    obs |= (uint64_t)t->io_acc_read_resp_valid << 6;
    obs |= wget(mr, 133, 1) << 7;
    obs |= wget(mr, 132, 1) << 8;
    obs |= wget(mr, 0, 1) << 9;
    obs |= wget(mr, 1, 3) << 10;
    obs |= wget(rr, 165, 1) << 13;
    obs |= wget(rr, 2, 3) << 14;
    obs |= wget(rr, 0, 2) << 17;
    obs ^= wget(rr, 133, 32) << 20;
    obs ^= wget(mr, 4, 64);    // resp data[63:0]
    obs ^= wget(mr, 68, 63);   // resp data[126:64]
    obs ^= wget(rr, 166, 64);  // read data[63:0]
    obs ^= wget(rr, 230, 63);  // read data[126:64]

    // Masked to 63 bits so the printed checksum is unambiguously positive.
    sum = ((sum << 1) + obs) & 0x7fffffffffffffffULL;

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;  // the Pyrope side spells this `lfsr#[7..=63]`
    lfsr ^= lfsr << 17;
  }

  t->final();
  std::printf("gemmini: cycles=%llu sum=%llu\n", (unsigned long long)cycles, (unsigned long long)sum);
  delete t;
  return 0;
}
