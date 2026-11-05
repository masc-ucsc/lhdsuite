// Verilator twin of rocket/sim/rocket_tb.prp: the same stimulus, responder, fold and printed line, so the three
// simulators (`lhd sim` on the .prp tree, `lhd sim` on an lg: library read from the .sv, and Verilator on the .sv)
// can be held to ONE checksum. Keep the pair in lockstep and re-pin sim_expect after any change to either file.
//
// Schedule: the Pyrope driver is drive / `step` / read, so two eval()s per cycle (clock=0 settle, clock=1 posedge);
// every read is of the post-step value. Usage:
//   verilator --cc --exe --build --top-module RocketTile -Wno-fatal -DSYNTHESIS -Irocket/verilog \
//       -F rocket/verilog/filelist.f rocket/sim/rocket_tb_verilator.cpp
//   ./obj_dir/VRocketTile --cycles 1000
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "VRocketTile.h"
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
      std::fprintf(stderr, "rocket_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* t = new VRocketTile;

  uint64_t lfsr = 0x123456789abcdefULL;
  uint64_t sum  = 0;
  uint64_t obs  = 0;
  uint8_t  pend = 0, pget = 0, psrc = 0, psize = 0;

  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    t->clock = 0;
    t->reset = (cycle < 4);

    t->auto_hartid_in        = 0;
    t->auto_int_local_in_0_0 = 0;
    t->auto_int_local_in_1_0 = 0;
    t->auto_int_local_in_1_1 = 0;
    t->auto_int_local_in_2_0 = 0;
    t->auto_buffer_in_a_valid        = 0;
    t->auto_buffer_in_a_bits_opcode  = 0;
    t->auto_buffer_in_a_bits_param   = 0;
    t->auto_buffer_in_a_bits_size    = 0;
    t->auto_buffer_in_a_bits_source  = 0;
    t->auto_buffer_in_a_bits_address = 0;
    t->auto_buffer_in_a_bits_mask    = 0;
    t->auto_buffer_in_a_bits_data    = 0;
    t->auto_buffer_in_a_bits_corrupt = 0;
    t->auto_buffer_in_d_ready        = 1;

    t->auto_buffer_out_a_ready        = !pend;
    t->auto_buffer_out_d_valid        = pend;
    t->auto_buffer_out_d_bits_opcode  = pget;
    t->auto_buffer_out_d_bits_param   = 0;
    t->auto_buffer_out_d_bits_size    = psize;
    t->auto_buffer_out_d_bits_source  = psrc;
    t->auto_buffer_out_d_bits_sink    = 0;
    t->auto_buffer_out_d_bits_denied  = 0;
    t->auto_buffer_out_d_bits_data    = (uint32_t)((lfsr >> 16) & 0xffffffffULL);
    t->auto_buffer_out_d_bits_corrupt = 0;
    t->eval();

    t->clock = 1;
    t->eval();

    uint8_t take = pend & t->auto_buffer_out_d_ready;
    uint8_t acpt = (!pend) & t->auto_buffer_out_a_valid;
    if (take) pend = 0;
    if (acpt) {
      pend  = 1;
      pget  = (t->auto_buffer_out_a_bits_opcode == 4) ? 1 : 0;
      psrc  = t->auto_buffer_out_a_bits_source;
      psize = t->auto_buffer_out_a_bits_size;
    }

    obs  = t->auto_buffer_out_a_valid;
    obs |= (uint64_t)t->auto_buffer_out_a_bits_opcode << 1;
    obs |= (uint64_t)t->auto_buffer_out_a_bits_size << 5;
    obs |= (uint64_t)t->auto_buffer_out_d_ready << 9;
    obs |= (uint64_t)t->auto_broadcast_out_insns_0_valid << 10;
    obs |= (uint64_t)t->auto_broadcast_out_insns_0_exception << 11;
    obs |= (uint64_t)t->auto_wfi_out_0 << 12;
    obs |= (uint64_t)t->auto_broadcast_out_insns_0_priv << 13;
    obs |= (uint64_t)t->auto_buffer_out_a_bits_address << 16;
    sum = ((sum << 1) + obs) & 0x7fffffffffffffffULL;
    sum = (sum ^ (uint64_t)t->auto_broadcast_out_insns_0_iaddr) & 0x7fffffffffffffffULL;

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;
    lfsr ^= lfsr << 17;
  }

  t->final();
  std::printf("rocket: cycles=%llu sum=%llu\n", (unsigned long long)cycles, (unsigned long long)sum);
  delete t;
  return 0;
}
