// Verilator twin of bitcoin_mine_tb.prp: same work items, same drive / step /
// read schedule and the same per-cycle checksum fold, so the two must print
// the same line. On top of the fold it recomputes every work item's golden
// nonce with a software SHA256d (below) and fails on any disagreement: the
// pinned checksum is then backed by an independent model of the miner, not
// only by two simulators agreeing.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vbitcoin_top.h"
#include "verilated.h"

namespace {

constexpr int kLanes = 4;  // NENGINES pinned by verilog/bitcoin_top.v

// --- software SHA-256 (FIPS 180-4), only what SHA256d of a header needs ----
constexpr uint32_t kK[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

void compress(uint32_t h[8], const uint8_t blk[64]) {
  uint32_t w[64];
  for (int t = 0; t < 16; ++t) {
    w[t] = uint32_t{blk[4 * t]} << 24 | uint32_t{blk[4 * t + 1]} << 16 |
           uint32_t{blk[4 * t + 2]} << 8 | blk[4 * t + 3];
  }
  for (int t = 16; t < 64; ++t) {
    const uint32_t s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
    const uint32_t s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
    w[t] = w[t - 16] + s0 + w[t - 7] + s1;
  }
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
  for (int t = 0; t < 64; ++t) {
    const uint32_t t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + kK[t] + w[t];
    const uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

// SHA-256 of a message of at most 119 bytes (two blocks), digest big-endian.
void sha256(const uint8_t *msg, size_t len, uint8_t out[32]) {
  uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  uint8_t buf[128] = {};
  std::memcpy(buf, msg, len);
  buf[len] = 0x80;
  const size_t blocks = len + 9 <= 64 ? 1 : 2;
  const uint64_t bits = uint64_t{len} * 8;
  for (int i = 0; i < 8; ++i) buf[blocks * 64 - 1 - i] = uint8_t(bits >> (8 * i));
  for (size_t b = 0; b < blocks; ++b) compress(h, buf + 64 * b);
  for (int i = 0; i < 8; ++i) {
    for (int j = 0; j < 4; ++j) out[4 * i + j] = uint8_t(h[i] >> (24 - 8 * j));
  }
}

// The miner's acceptance test: header bytes 76..79 hold `nonce` big-endian
// (block bits [415:384]); the SHA256d digest read as a LITTLE-endian integer
// must be <= target. `target` is 32 bytes, most significant first.
bool hits(const uint8_t hdr[80], uint32_t nonce, const uint8_t target[32]) {
  uint8_t m[80], h1[32], h2[32];
  std::memcpy(m, hdr, 80);
  for (int j = 0; j < 4; ++j) m[76 + j] = uint8_t(nonce >> (24 - 8 * j));
  sha256(m, 80, h1);
  sha256(h1, 32, h2);
  for (int i = 0; i < 32; ++i) {   // compare h2[31] (most significant) down
    if (h2[31 - i] != target[i]) return h2[31 - i] < target[i];
  }
  return true;
}

// The golden nonce the miner reports: lane g tries base + g + kLanes*r, every
// lane spends the same cycles per trial, so the winner is the first round with
// any hit and, within it, the lowest lane.
uint32_t expected_golden(const uint8_t hdr[80], uint32_t base, const uint8_t target[32]) {
  for (uint32_t r = 0;; ++r) {
    for (uint32_t g = 0; g < kLanes; ++g) {
      const uint32_t n = base + g + kLanes * r;
      if (hits(hdr, n, target)) return n;
    }
  }
}

void hex_bytes(const char *hex, uint8_t *out, int n) {
  for (int i = 0; i < n; ++i) {
    unsigned v;
    std::sscanf(hex + 2 * i, "%2x", &v);
    out[i] = uint8_t(v);
  }
}

// A byte string (most significant first) onto a Verilator wide port (word 0 =
// bits [31:0]).
template <typename W>
void drive(W &port, const uint8_t *bytes, int nbytes) {
  for (int w = 0; w < nbytes / 4; ++w) {
    const uint8_t *p = bytes + nbytes - 4 - 4 * w;
    port[w] = uint32_t{p[0]} << 24 | uint32_t{p[1]} << 16 | uint32_t{p[2]} << 8 | p[3];
  }
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t cycles = 20000;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--cycles") == 0 && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 10);
    } else {
      std::fprintf(stderr, "usage: %s [--cycles N]\n", argv[0]);
      return 2;
    }
  }

  uint8_t genesis[80], genesis_target[32], easy_target[32];
  hex_bytes("0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27a"
            "c72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c",
            genesis, 80);
  hex_bytes("00000000ffff0000000000000000000000000000000000000000000000000000", genesis_target, 32);
  std::memset(easy_target, 0xff, 32);
  easy_target[0] = 0x0f;

  Vbitcoin_top dut;
  uint64_t job = 0, phase = 0, job_start = 0, genesis_nonce = 0, genesis_cycle = 0;
  uint64_t longest = 0, nonce_fold = 0, sum = 0, mismatches = 0;
  uint8_t hdr[80];
  const uint8_t *target = genesis_target;
  uint32_t base = 0;
  for (uint64_t cycle = 0; cycle < cycles; ++cycle) {
    std::memcpy(hdr, genesis, 80);
    if (job == 0) {
      target = genesis_target;
      base = 0x1dac2b7c - 5;
    } else {
      // header bits [95:64] = bytes 68..71 (the timestamp), XOR the job number
      for (int j = 0; j < 4; ++j) hdr[68 + j] ^= uint8_t(job >> (24 - 8 * j));
      target = easy_target;
      base = uint32_t(job * 0x9e3779b9ULL);
    }
    dut.clk = 0;
    dut.reset_n = phase >= 2;
    dut.start = phase == 2;
    drive(dut.header, hdr, 80);
    drive(dut.target, target, 32);
    dut.nonce_base = base;
    dut.eval();
    dut.clk = 1;
    dut.eval();
    dut.clk = 0;
    dut.eval();
    const uint64_t found = dut.found, golden = dut.golden_nonce;
    sum = (sum * 31 + found + (uint64_t{dut.busy} << 1) + (golden << 2)) & 0x7fffffffffffffffULL;
    if (phase < 3) {
      if (phase == 2) job_start = cycle;
      ++phase;
    } else if (found) {
      const uint32_t want = expected_golden(hdr, base, target);
      if (golden != want) {
        if (mismatches++ < 5) {
          std::fprintf(stderr, "job %llu: miner reported 0x%08llx, software SHA256d says 0x%08x\n",
                       static_cast<unsigned long long>(job), static_cast<unsigned long long>(golden), want);
        }
      }
      if (job == 0) {
        genesis_nonce = golden;
        genesis_cycle = cycle;
      }
      if (cycle - job_start > longest) longest = cycle - job_start;
      nonce_fold = (nonce_fold * 31 + golden) & 0x7fffffffffffffffULL;
      ++job;
      phase = 0;
    }
  }
  dut.final();
  std::printf("bitcoin mine: genesis=%llu at cycle %llu jobs=%llu longest=%llu nonces=%llu of %llu sum=%llu\n",
              static_cast<unsigned long long>(genesis_nonce), static_cast<unsigned long long>(genesis_cycle),
              static_cast<unsigned long long>(job), static_cast<unsigned long long>(longest),
              static_cast<unsigned long long>(nonce_fold), static_cast<unsigned long long>(cycles),
              static_cast<unsigned long long>(sum));
  if (genesis_nonce != 0x1dac2b7c || job <= 1 || mismatches != 0) {
    std::fprintf(stderr, "FAIL bitcoin.mine: genesis=0x%08llx jobs=%llu mismatches=%llu\n",
                 static_cast<unsigned long long>(genesis_nonce), static_cast<unsigned long long>(job),
                 static_cast<unsigned long long>(mismatches));
    return 1;
  }
  std::puts("PASS bitcoin.mine (verilator)");
  return 0;
}
