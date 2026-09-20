#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vcva6_oracle.h"
#include "verilated.h"
int main(int argc, char** argv) {
  unsigned cycles = 50000;
  if (argc == 3 && std::strcmp(argv[1], "--cycles") == 0) {
    cycles = std::strtoul(argv[2], nullptr, 10);
  } else if (argc != 1) {
    return 2;
  }
  if (cycles < 1000) {
    return 2;
  }
  Vcva6_oracle   d;
  const uint32_t rom[]
      = {0x00000093, 0x00000113, 0x00000193, 0x00000213, 0x00000293, 0x00000313, 0x00000393, 0x00000413, 0x00000493, 0x00000513,
         0x00000593, 0x00000613, 0x00000693, 0x00000713, 0x00000793, 0x00000813, 0x00000893, 0x00000913, 0x00000993, 0x00000A13,
         0x00000A93, 0x00000B13, 0x00000B93, 0x00000C13, 0x00000C93, 0x00000D13, 0x00000D93, 0x00000E13, 0x00000E93, 0x00000F13,
         0x00000F93, 0x06400093, 0x00110113, 0xFFF18193, 0xFE111CE3, 0x10000537, 0x00253023, 0x00353423, 0x5A500593, 0x00B53823,
         0x00120213, 0x002242B3, 0x00328333, 0x404303B3, 0x00121413, 0x00245493, 0xFE9FF06F, 0x00000013, 0x00000013, 0x00000013,
         0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013, 0x00000013,
         0x00000013, 0x00000013, 0x00000013, 0x00000013};
  unsigned rbeats = 0, rid = 0, awid = 0, bpend = 0, got = 0, retired = 0, nexc = 0, done = 0;
  uint64_t raddr = 0, waddr = 0, st0 = 0, st8 = 0, st16 = 0;
  d.clk_i = 0;
  d.eval();
  for (unsigned c = 0; c < cycles; ++c) {
    d.rst_ni      = c >= 8;
    uint64_t beat = 0x0000001300000013ull;
    if (raddr >= 0x80000000 && raddr < 0x80000100) {
      unsigned idx = ((raddr - 0x80000000) >> 2) & 0x3e;
      beat         = uint64_t(rom[idx]) | (uint64_t(rom[idx + 1]) << 32);
    }
    d.ar_ready = rbeats == 0;
    d.r_valid  = rbeats != 0;
    d.r_id     = rid;
    d.r_data   = beat;
    d.r_last   = rbeats == 1;
    d.aw_ready = 1;
    d.w_ready  = 1;
    d.b_valid  = bpend != 0;
    d.b_id     = awid;
    d.eval();
    d.clk_i = 1;
    d.eval();
    d.clk_i = 0;
    d.eval();
    if (rbeats == 0) {
      if (d.ar_valid) {
        rbeats = d.ar_len + 1;
        raddr  = d.ar_addr;
        rid    = d.ar_id;
      }
    } else if (d.r_ready) {
      --rbeats;
      raddr += 8;
    }
    if (d.aw_valid) {
      waddr = d.aw_addr;
      awid  = d.aw_id;
    }
    if (d.w_valid) {
      if (waddr == 0x10000000) {
        st0  = d.w_data;
        got |= 1;
      }
      if (waddr == 0x10000008) {
        st8  = d.w_data;
        got |= 2;
      }
      if (waddr == 0x10000010) {
        st16  = d.w_data;
        got  |= 4;
      }
      waddr += 8;
      if (d.w_last) {
        bpend = 1;
      }
    }
    if (bpend && d.b_ready) {
      bpend = 0;
    }
    retired += (d.commit_ack & 1) + ((d.commit_ack >> 1) & 1);
    nexc    += d.ex_valid;
    if (!done && got == 7) {
      done = c;
    }
  }
  printf("cva6 oracle: got=%u st0=%llu st8=%lld st16=%llu retired=%u exceptions=%u done=%u\n",
         got,
         (unsigned long long)st0,
         (long long)st8,
         (unsigned long long)st16,
         retired,
         nexc,
         done);
  return got != 7 || st0 != 100 || st8 != uint64_t(-100) || st16 != 0x5a5 || nexc;
}
