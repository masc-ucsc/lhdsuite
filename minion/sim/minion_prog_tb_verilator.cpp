// Line-by-line Verilator twin of minion_prog_tb.prp — same ROM, same poke and
// observe order, so the two simulators must agree instruction for instruction.
// This is the cross-simulator oracle the bench's `verilator_tb` slot wants
// (bench/defs.bzl minion entry), and the reference that turns the .prp's
// hand-derived `retired >= 305` into a measured number.
//
// Packed-struct ports arrive in Verilator as wide bit vectors; the field
// offsets below are derived from the SV struct declarations (first field =
// MSBs) and the pkg parameters:
//   icache_fe_resp_t  (261b) = data[256] pf af cacheable bus_err ecc_err
//                     LSB: ecc=0 bus=1 cacheable=2 af=3 pf=4 data=[260:5]
//   fe_icache_req_t   (58b)  = thread_id[1] vm_status[8] addr[49]; addr=[48:0]
//   trace_encoder_signals_t (144b, R=1, IW=32, AW=49, CW=1, EW=5, PW=2, SW=1)
//                     LSB: min_reset=0 cpu_halted=1 status=2 priv=[4:3]
//                          trap_value=[53:5] interrupt=54 ecause=[59:55]
//                          exception=60 context=61 instr_addr=[110:62]
//                          instr_bus=[142:111] instr_valid=143
//   minion_chicken_bits_t (8b): frontend=bit5 dcache=bit4 vputrans=bit3
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vminion_top.h"
#ifdef MINION_TB_INTERNALS
#include "Vminion_top___024root.h"
#endif
#include "verilated.h"

namespace {

// Read bits [lo, lo+len) (len <= 64) of a Verilator wide signal.
uint64_t get_bits(const uint32_t* w, int lo, int len) {
  uint64_t v = 0;
  for (int i = 0; i < len; ++i) {
    const int b = lo + i;
    v |= static_cast<uint64_t>((w[b >> 5] >> (b & 31)) & 1u) << i;
  }
  return v;
}

// Write bits [lo, lo+len) (len <= 64) of a Verilator wide signal.
void set_bits(uint32_t* w, int lo, int len, uint64_t v) {
  for (int i = 0; i < len; ++i) {
    const int b = lo + i;
    if ((v >> i) & 1u) {
      w[b >> 5] |= 1u << (b & 31);
    } else {
      w[b >> 5] &= ~(1u << (b & 31));
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vminion_top;

  // Same 16-word RV32 ROM as minion_prog_tb.prp:
  //   li x1,100; li x2,0; li x3,0; loop: addi x2,x2,1; addi x3,x3,-1;
  //   bne x2,x1,loop; sw x2,0(x0); sw x3,8(x0); spin: beq x0,x0,spin; nops.
  const uint32_t rom[16] = {0x06400093u, 0x00000113u, 0x00000193u, 0x00110113u,
                            0xFFF18193u, 0xFE111CE3u, 0x00203023u, 0x00303423u,
                            0x00000063u, 0x00000013u, 0x00000013u, 0x00000013u,
                            0x00000013u, 0x00000013u, 0x00000013u, 0x00000013u};

  long cycles = 20000;
  for (int i = 1; i < argc; ++i) {
    long v = 0;
    if (std::sscanf(argv[i], "%ld", &v) == 1 && v > 0) {
      cycles = v;
    }
  }

  long retired = 0, took_exc = 0, done_cycle = 0;
  uint64_t last_pc = 0;
  // The icache contract is FIXED LATENCY, not a next-cycle handshake: the
  // request leaves the frontend at F1 (minion_frontend.sv:44) and the response
  // is sampled at F5 (:48), with the buffer write requiring the response to
  // meet the request's own pipeline slot (thread_buffer.sv:512 f6_req_valid).
  // So a request observed after step(c) must be answered DURING cycle c+4.
  int resp_latency = 5;
  if (const char* e = std::getenv("MINION_TB_LAT")) { resp_latency = std::atoi(e); }
  constexpr int kMaxLat = 16;
  int resp_line_at[kMaxLat];  // -1 = no response scheduled for that slot
  for (int i = 0; i < kMaxLat; ++i) { resp_line_at[i] = -1; }
  int fetch_line = 0;

  dut->clk_i = 0;
  dut->eval();

  for (long clock = 0; clock < cycles; ++clock) {
    // ---- pokes, exactly the .prp's order/values --------------------------
    dut->rst_c_ni = clock >= 4;
    dut->rst_d_ni = clock >= 4;
    dut->rst_w_ni = clock >= 4;
    dut->nsleepin_i = 1;
    dut->enabled_i  = 1;
    dut->te_enable_i     = 1;  // trace-encoder retirement tracking is GATED on this (core_top.sv:545)
    dut->te_thread_sel_i = 0;
    // reset_vector_i (49b wide) stays 0: boot at ROM word [0]
    dut->chicken_bits_i = (1u << 5) | (1u << 4) | (1u << 3);  // frontend, dcache, vputrans

    dut->icache_req_ready_i = 1;
    dut->icache_resp_miss_i = 0;
    dut->icache_fill_done_i = (std::getenv("MINION_TB_FD") != nullptr) ? 1 : 0;

    const int resp_line = resp_line_at[clock % kMaxLat];
    resp_line_at[clock % kMaxLat] = -1;
    dut->icache_resp_valid_i = resp_line >= 0;
    fetch_line = resp_line >= 0 ? resp_line : 0;
    for (int i = 0; i < 9; ++i) {
      dut->icache_resp_i[i] = 0;
    }
    for (int i = 0; i < 8; ++i) {  // data = bits [260:5]
      set_bits(dut->icache_resp_i.data(), 5 + 32 * i, 32, rom[fetch_line * 8 + i]);
    }
    set_bits(dut->icache_resp_i.data(), 2, 1, 1);  // cacheable

    dut->l2_dcache_miss_req_ready_i  = 1;
    dut->l2_dcache_evict_req_ready_i = 1;
    dut->l2_dcache_resp_valid_i      = 0;
    dut->dc_ptw_req_ready_i          = 1;
    dut->ptw_dc_resp_valid_i         = 0;

    // ---- step: one full clock -------------------------------------------
    dut->clk_i = 1;
    dut->eval();
    dut->clk_i = 0;
    dut->eval();

    // ---- observe, all below the step (same as the .prp) ------------------
    if (dut->icache_req_valid_o != 0) {
      // fe_icache_req_t is 58 bits -> a plain QData in Verilator; addr=[48:0].
      const uint64_t addr = dut->icache_req_o & ((1ULL << 49) - 1);
      resp_line_at[(clock + resp_latency) % kMaxLat] = static_cast<int>((addr >> 5) & 1);
    }
    if (clock < 60 && std::getenv("MINION_TB_DEBUG") != nullptr) {
      std::printf("c%ld req_v=%d addr=0x%llx resp_v=%d retired=%ld", clock,
                  static_cast<int>(dut->icache_req_valid_o),
                  static_cast<unsigned long long>(dut->icache_req_o & ((1ULL << 49) - 1)),
                  static_cast<int>(dut->icache_resp_valid_i), retired);
#ifdef MINION_TB_INTERNALS
      auto* r = dut->rootp;
      std::printf(" | f6rq=%d f6rv=%d corereq=%d halt0=%d bwr=%d",
                  static_cast<int>(r->minion_top__DOT__u_core__DOT__u_frontend__DOT__gen_thread_buf__BRA__0__KET____DOT__u_tb__DOT__f6_req_valid),
                  static_cast<int>(r->minion_top__DOT__u_core__DOT__u_frontend__DOT__f6_resp_valid_q),
                  static_cast<int>(r->minion_top__DOT__u_core__DOT__u_frontend__DOT__f0_core_req_valid_i),
                  static_cast<int>(r->minion_top__DOT__u_core__DOT__u_frontend__DOT__gen_thread_buf__BRA__0__KET____DOT__u_tb__DOT__io_halt_i),
                  static_cast<int>(r->minion_top__DOT__u_core__DOT__u_frontend__DOT__gen_thread_buf__BRA__0__KET____DOT__u_tb__DOT__f6_buffer_wr));
#endif
      std::printf("\n");
    }

    const uint32_t* te = dut->trace_encoder_o.data();
    if (get_bits(te, 143, 1) != 0) {  // instr_valid
      ++retired;
      last_pc = get_bits(te, 62, 49);  // instr_addr
      if (retired <= 14 && std::getenv("MINION_TB_DEBUG") != nullptr) {
        std::printf("  ret#%ld @c%ld pc=0x%llx instr=0x%08llx\n", retired, clock,
                    static_cast<unsigned long long>(last_pc),
                    static_cast<unsigned long long>(get_bits(te, 111, 32)));
      }
    }
    if (get_bits(te, 60, 1) != 0 || get_bits(te, 54, 1) != 0) {  // exception | interrupt
      ++took_exc;
      std::printf("  exc @c%ld: exception=%d interrupt=%d cause=0x%llx trap_pc=0x%llx tval=0x%llx\n", clock,
                  static_cast<int>(get_bits(te, 60, 1)), static_cast<int>(get_bits(te, 54, 1)),
                  static_cast<unsigned long long>(get_bits(te, 55, 5)),
                  static_cast<unsigned long long>(get_bits(te, 62, 49)),
                  static_cast<unsigned long long>(get_bits(te, 5, 49)));
    }
    if (done_cycle == 0 && last_pc == 0x20) {
      done_cycle = clock;
    }
  }

  std::printf("minion program: retired=%ld last_pc=0x%llx, done at cycle %ld, exc=%ld\n", retired,
              static_cast<unsigned long long>(last_pc), done_cycle, took_exc);
  const bool ok = took_exc == 0 && retired >= 305 && done_cycle > 0;
  std::printf("%s minion.prog (verilator)\n", ok ? "PASS" : "FAIL");
  dut->final();
  delete dut;
  return ok ? 0 : 1;
}
