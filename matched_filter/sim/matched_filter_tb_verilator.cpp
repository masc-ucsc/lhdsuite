// Verilator twin of matched_filter_tb.prp. Besides matching its stimulus and
// checksum, this independently checks the first 4096 cycles against a direct
// software model of the quantized dot product and six-stage result latency.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>

#include "Vmatched_filter.h"
#include "verilated.h"

namespace {
constexpr int kSize = 64;
constexpr int kLog2Size = 6;
constexpr int kMultWidth = 4;
constexpr uint64_t kCheckCycles = 4096;

int32_t sign_extend(uint32_t bits, int width) {
  const uint32_t sign = 1U << (width - 1);
  return static_cast<int32_t>((bits ^ sign) - sign);
}

int32_t quantized_product(int8_t x, int8_t ref) {
  if (kMultWidth >= 8) {
    const int32_t full = static_cast<int32_t>(x) * static_cast<int32_t>(ref);
    const uint32_t bits = static_cast<uint16_t>(full) >> (16 - kMultWidth);
    return sign_extend(bits, kMultWidth);
  } else {
    const uint32_t x_bits = static_cast<uint8_t>(x) >> (8 - kMultWidth);
    const uint32_t ref_bits = static_cast<uint8_t>(ref) >> (8 - kMultWidth);
    const int32_t narrow = sign_extend(x_bits, kMultWidth) *
                           sign_extend(ref_bits, kMultWidth);
    const uint32_t bits = (static_cast<uint32_t>(narrow) >> kMultWidth) &
                          ((1U << kMultWidth) - 1U);
    return sign_extend(bits, kMultWidth);
  }
}
}  // namespace

int main(int argc, char** argv) {
  uint64_t cycles = 1000;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--cycles") == 0 && i + 1 < argc) {
      cycles = std::strtoull(argv[++i], nullptr, 10);
    } else if (std::strncmp(argv[i], "--cycles=", 9) == 0) {
      cycles = std::strtoull(argv[i] + 9, nullptr, 10);
    } else if (std::strcmp(argv[i], "--help") == 0) {
      std::printf("usage: %s [--cycles N]\n", argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "matched_filter_tb_verilator: unknown argument '%s'\n", argv[i]);
      return 2;
    }
  }

  Verilated::commandArgs(argc, argv);
  auto* top = new Vmatched_filter;
  uint64_t lfsr = 0x123456789abcdefULL;
  uint64_t sum = 0;
  std::array<int8_t, kSize> x_taps{};
  std::array<int8_t, kSize> ref_taps{};
  std::deque<int32_t> expected_pipe;

  top->clock = 0;
  top->reset = 1;
  top->ref_load = 0;
  top->x = 0;
  top->ref_in = 0;
  top->eval();

  for (uint64_t clk = 0; clk < cycles; ++clk) {
    const bool reset = clk < 2;
    const bool ref_load = clk >= 2 && clk < 66;
    const int8_t ref_in = static_cast<int8_t>(lfsr & 0xffULL);
    const int8_t x = static_cast<int8_t>((lfsr >> 8) & 0xffULL);

    // The first adder stage samples the pre-edge tap values.
    int32_t expected_sum = 0;
    for (int i = 0; i < kSize; ++i)
      expected_sum += quantized_product(x_taps[i], ref_taps[i]);

    top->reset = reset;
    top->ref_load = ref_load;
    top->ref_in = static_cast<uint8_t>(ref_in);
    top->x = static_cast<uint8_t>(x);
    top->eval();
    top->clock = 1;
    top->eval();
    top->clock = 0;
    top->eval();

    if (reset || ref_load) {
      expected_pipe.clear();
    } else {
      expected_pipe.push_back(expected_sum);
    }
    const bool expected_valid = expected_pipe.size() >= kLog2Size;
    if (clk < kCheckCycles) {
      if (static_cast<bool>(top->y_valid) != expected_valid) {
        std::fprintf(stderr, "matched_filter: y_valid mismatch at cycle %llu\n",
                     (unsigned long long)clk);
        return 3;
      }
      if (expected_valid) {
        const uint32_t expected_bits = static_cast<uint32_t>(expected_pipe.front()) & 0x3ffU;
        const uint32_t actual_bits = static_cast<uint32_t>(top->y) & 0x3ffU;
        if (actual_bits != expected_bits) {
          std::fprintf(stderr,
                       "matched_filter: y mismatch at cycle %llu: got 0x%x expected 0x%x\n",
                       (unsigned long long)clk, actual_bits, expected_bits);
          return 4;
        }
      }
    }
    if (expected_valid)
      expected_pipe.pop_front();

    if (top->y_valid) {
      const uint64_t y = static_cast<uint64_t>(top->y) & 0x3ffULL;
      sum = ((sum << 1) + y) & 0x7fffffffffffffffULL;
    }

    if (reset) {
      x_taps.fill(0);
      ref_taps.fill(0);
    } else {
      for (int i = kSize - 1; i > 0; --i) {
        x_taps[i] = x_taps[i - 1];
        if (ref_load)
          ref_taps[i] = ref_taps[i - 1];
      }
      x_taps[0] = x;
      if (ref_load)
        ref_taps[0] = ref_in;
    }

    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 7;
    lfsr ^= lfsr << 17;
  }

  std::printf("matched_filter: cycles=%llu sum=%llu\n",
              (unsigned long long)cycles, (unsigned long long)sum);
  top->final();
  delete top;
  return 0;
}
