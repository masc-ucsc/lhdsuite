// Verilator twin of boom/sim/boom_tb.prp: the same stimulus, the same TileLink-C responder, the same fold and the
// same printed line, so the two simulators can be compared metric for metric and must agree on the checksum.
// The boot line 0x10000..0x1003f returns the same fixed RV64 loop as the Pyrope driver. Keep the pair in lockstep (see rocket/sim/rocket_tb_verilator.cpp for the two-eval schedule). Usage:
//   verilator --cc --exe --build --top-module BoomTile -Wno-fatal -DSYNTHESIS -Iboom/verilog \
//       -F boom/verilog/filelist.f boom/sim/boom_tb_verilator.cpp
//   ./obj_dir/VBoomTile --cycles 1000

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VBoomTile.h"
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
      std::fprintf(stderr, "boom_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* t = new VBoomTile;

  uint64_t lfsr = 0x123456789abcdefULL;
  uint64_t sum = 0, obs = 0;
  uint8_t dv = 0, dop = 0, dsize = 0, dsrc = 0, dleft = 0, dbeats = 0, dprog = 0;
  static const uint64_t prog[4] = {0x01F0909300100093ULL, 0x002181B30000B103ULL, 0x040080930030B423ULL, 0x00000013FF1FF06FULL};
  uint8_t aleft = 0, ap = 0, apop = 0, apsize = 0, apsrc = 0, apbeats = 0, approg = 0;
  uint8_t cleft = 0, rp = 0, rpsize = 0, rpsrc = 0;

  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    t->clock = 0;
    t->reset = (cycle < 4);

    t->auto_hartid_in = 0;
    t->auto_int_local_in_0_0 = 0;
    t->auto_int_local_in_1_0 = 0;
    t->auto_int_local_in_1_1 = 0;
    t->auto_int_local_in_2_0 = 0;
    t->auto_int_local_in_3_0 = 0;

    const uint8_t aready = !(ap | rp | dv), cready = !rp;
    t->auto_buffer_out_a_ready = aready;
    t->auto_buffer_out_b_valid = 0;
    t->auto_buffer_out_b_bits_opcode = 0;
    t->auto_buffer_out_b_bits_param = 0;
    t->auto_buffer_out_b_bits_size = 0;
    t->auto_buffer_out_b_bits_source = 0;
    t->auto_buffer_out_b_bits_address = 0;
    t->auto_buffer_out_b_bits_mask = 0;
    t->auto_buffer_out_b_bits_data = 0;
    t->auto_buffer_out_b_bits_corrupt = 0;
    t->auto_buffer_out_c_ready = cready;
    t->auto_buffer_out_d_valid = dv;
    t->auto_buffer_out_d_bits_opcode = dop;
    t->auto_buffer_out_d_bits_param = 0;
    t->auto_buffer_out_d_bits_size = dsize;
    t->auto_buffer_out_d_bits_source = dsrc;
    t->auto_buffer_out_d_bits_sink = 0;
    t->auto_buffer_out_d_bits_denied = 0;
    const uint8_t beat = (uint8_t)(dbeats - dleft);
    t->auto_buffer_out_d_bits_data = dprog ? (beat < 4 ? prog[beat] : 0x0000001300000013ULL) : lfsr;
    t->auto_buffer_out_d_bits_corrupt = 0;
    t->auto_buffer_out_e_ready = 1;
    t->eval();

    t->clock = 1;
    t->eval();

    if (dv & t->auto_buffer_out_d_ready) {
      dleft = (uint8_t)(dleft - 1);
      if (dleft == 0) dv = 0;
    }
    if (t->auto_buffer_out_c_valid & cready) {
      uint8_t cop = t->auto_buffer_out_c_bits_opcode, csz = t->auto_buffer_out_c_bits_size;
      if (cleft == 0) cleft = (cop == 7 && csz >= 3) ? (uint8_t)(1u << (csz - 3)) : 1;
      cleft = (uint8_t)(cleft - 1);
      if (cleft == 0 && (cop == 6 || cop == 7)) {
        rp = 1;
        rpsize = csz;
        rpsrc = t->auto_buffer_out_c_bits_source;
      }
    }
    if (t->auto_buffer_out_a_valid & aready) {
      uint8_t op = t->auto_buffer_out_a_bits_opcode, sz = t->auto_buffer_out_a_bits_size;
      if (aleft == 0) aleft = (op <= 1 && sz >= 3) ? (uint8_t)(1u << (sz - 3)) : 1;
      aleft = (uint8_t)(aleft - 1);
      if (aleft == 0) {
        ap = 1;
        apsize = sz;
        apsrc = t->auto_buffer_out_a_bits_source;
        approg = ((t->auto_buffer_out_a_bits_address >> 6) & 0x3ffffff) == 0x400;
        apbeats = ((op == 4 || op == 6) && sz >= 3) ? (uint8_t)(1u << (sz - 3)) : 1;
        apop = op == 4 ? 1 : op == 6 ? 5 : op == 7 ? 4 : 0;
      }
    }
    if (dv == 0) {
      if (rp) {
        dv = 1; dop = 6; dsize = rpsize; dsrc = rpsrc; dleft = 1; dbeats = 1; dprog = 0; rp = 0;
      } else if (ap) {
        dv = 1; dop = apop; dsize = apsize; dsrc = apsrc; dleft = apbeats; dbeats = apbeats; dprog = approg; ap = 0;
      }
    }

    obs = t->auto_buffer_out_a_valid;
    obs |= (uint64_t)t->auto_buffer_out_a_bits_opcode << 1;
    obs |= (uint64_t)t->auto_buffer_out_a_bits_size << 4;
    obs |= (uint64_t)t->auto_buffer_out_d_ready << 8;
    obs |= (uint64_t)t->auto_buffer_out_c_valid << 9;
    obs |= (uint64_t)t->auto_buffer_out_c_bits_opcode << 10;
    obs |= (uint64_t)t->auto_buffer_out_e_valid << 13;
    obs |= (uint64_t)t->auto_buffer_out_a_bits_address << 16;
    sum = ((sum << 1) + obs) & 0x7fffffffffffffffULL;
    sum = (sum ^ (uint64_t)t->auto_buffer_out_c_bits_address) & 0x7fffffffffffffffULL;

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;
    lfsr ^= lfsr << 17;
  }

  t->final();
  std::printf("boom: cycles=%llu sum=%llu\n", (unsigned long long)cycles, (unsigned long long)sum);
  delete t;
  return 0;
}
