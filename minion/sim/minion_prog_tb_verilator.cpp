// Line-by-line Verilator twin of minion_prog_tb.prp — same ROM, same poke and
// observe order. Both sides must sustain retirement inside the active loop;
// exact retire-count equality remains a separate phase-alignment oracle.
//
// THE STIMULUS SCHEDULE, and why it is not the usual two-eval toggle. `lhd sim`
// lowers the Pyrope `tick` body to  drive(all inputs); step(); read(outputs),
// where `step` is settle -> commit -> settle. Every poke in minion_prog_tb.prp
// sits ABOVE the `step` and every read BELOW it, so the twin is:
//     clk_i = 0; eval()   settle the design on the inputs just driven (this is
//                         also where the previous iteration's clk 1->0 edge
//                         lands, for the design's negedge flops)
//     clk_i = 1; eval()   the posedge == step(); afterwards the outputs hold
//                         the post-edge value, which is the post-step read
// This file used to do the reverse (clk=1 eval, clk=0 eval, then observe), so
// it observed AFTER a negedge that the Pyrope side had not taken yet — a
// one-edge skew that makes `retired` and `done at cycle N` incomparable. See
// AGENTS.md: keep the pair in lockstep, the stimulus schedule especially.
//
// MATCHED TO THE .prp, not to what merely runs. Three pokes here are the .prp's
// values and are NOT knobs to twiddle when a run misbehaves — a divergence in
// any of them silently turns the oracle into two unrelated experiments:
//   * chicken_bits_i = 0 — all three clock-gate *disables* are 0, i.e. the
//     frontend/dcache/vputrans clock gates are ENABLED (the .prp used to set
//     them to 1; it no longer does). MEASURED 2026-08-09, both values, both
//     simulators: the retire trace is IDENTICAL cycle for cycle. That is the
//     differential the .prp's old comment asked for and it comes out clean —
//     with the gates open and with them closed the core retires the same
//     instructions at the same cycles, so `lhd sim`'s fold of a clock-gate
//     enable into a flop enable is functionally correct on this design. (It
//     also means this bit cannot be the knob that explains an lhd-vs-verilator
//     divergence; do not reach for it when one appears.)
//   * icache_fill_done_i = 1 — unconditional, as in the .prp.
//   * te_enable_i / te_thread_sel_i are hoisted out of the tick loop in the
//     .prp because they are constant; driving them every cycle here is the
//     same stimulus.
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
#include <cstring>

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

  // Same always-active loop as minion_prog_tb.prp, duplicated in both lines.
  const uint32_t rom[16] = {0x00110113u, 0x00318193u, 0x00314233u, 0x002202B3u,
                            0x40328333u, 0x002303B3u, 0xFE0114E3u, 0x00000013u,
                            0x00110113u, 0x00318193u, 0x00314233u, 0x002202B3u,
                            0x40328333u, 0x002303B3u, 0xFE0114E3u, 0x00000013u};

  // Argument shape of the driver `lhd sim` generates (`--arg cycles=N` reaches
  // drv.bin as `--cycles N`), so bench/sim_verilator.sh can hand both binaries
  // the same flags. Unknown flags are an ERROR rather than a silent default:
  // this used to sscanf every argv and take the first number, so `--cycles
  // 500000` worked only by accident and a typo'd flag would have benchmarked
  // the 100000-cycle default while reporting the count that was asked for.
  long cycles = 100000;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--cycles") && i + 1 < argc) {
      cycles = std::strtol(argv[++i], nullptr, 0);
    } else if (!std::strcmp(argv[i], "--help") || !std::strcmp(argv[i], "-h")) {
      std::printf("usage: %s [--cycles N]\n", argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "minion_prog_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  long retired = 0, took_exc = 0;
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
    // All three clock-gate DISABLE bits at 0 == the gates are enabled, matching
    // the .prp. (It used to set them, and this file used to mirror that.)
    dut->chicken_bits_i = 0;  // frontend=bit5, dcache=bit4, vputrans=bit3

    dut->icache_req_ready_i = 1;
    dut->icache_resp_miss_i = 0;
    dut->icache_fill_done_i = 1;

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
    // settle on the inputs just driven (and take the 1->0 edge left by the
    // previous iteration), then the posedge. See the schedule note at the top:
    // observing AFTER a trailing clk=0 eval, as this used to, reads one negedge
    // ahead of what the Pyrope `step` has settled.
    dut->clk_i = 0;
    dut->eval();
    dut->clk_i = 1;
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
      // Behind the debug env, not unconditional: the .prp counts exceptions
      // silently, and a per-exception line here would put thousands of lines
      // between the two simulators' otherwise identical output.
      if (std::getenv("MINION_TB_DEBUG") != nullptr) {
        std::printf("  exc @c%ld: exception=%d interrupt=%d cause=0x%llx trap_pc=0x%llx tval=0x%llx\n", clock,
                    static_cast<int>(get_bits(te, 60, 1)), static_cast<int>(get_bits(te, 54, 1)),
                    static_cast<unsigned long long>(get_bits(te, 55, 5)),
                    static_cast<unsigned long long>(get_bits(te, 62, 49)),
                    static_cast<unsigned long long>(get_bits(te, 5, 49)));
      }
    }
  }

  // Byte-for-byte the .prp's `puts`, INCLUDING last_pc in decimal — Pyrope's
  // `{}` formats an integer in base 10, and a hex spelling here would make the
  // two simulators disagree on a line that is supposed to be diffable (and
  // would break a `sim_expect` gate written against either one).
  std::printf("minion program: retired=%ld last_pc=%llu, active through cycle %ld\n", retired,
              static_cast<unsigned long long>(last_pc), cycles);
  // The .prp's two activity assertions, verbatim. took_exc stays reported only
  // under MINION_TB_DEBUG because it is not part of the throughput validity gate.
  const bool ok = retired >= 100 && last_pc < 32;
  if (std::getenv("MINION_TB_DEBUG") != nullptr) {
    std::printf("  (debug) exc=%ld\n", took_exc);
  }
  std::printf("%s minion.prog (verilator)\n", ok ? "PASS" : "FAIL");
  dut->final();
  delete dut;
  return ok ? 0 : 1;
}
