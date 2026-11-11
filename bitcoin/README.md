# bitcoin

A SHA256d proof-of-work miner: given an 80-byte block header, a difficulty
target and a base nonce, `NENGINES` lanes search interleaved nonces for one
whose double-SHA256 digest, read as a little-endian integer, is at or below
the target. The suite pins `NENGINES = 4` (`verilog/bitcoin_top.v`).

```
bitcoin_top            suite wrapper: NENGINES = 4
+- bitcoin             split the header into two SHA-256 blocks, NENGINES lanes,
   |                   lowest-index lane reports its golden nonce
   +- bitcoin_engine       one lane: step the nonce, run SHA256d, compare
      +- bitcoin_sha256d   init(block_a) -> next(block_b + nonce) -> init(pad(H1))
      |  +- sha256_core    secworks SHA-256 compression core
      |     +- sha256_k_constants   round constants K[t]
      |     +- sha256_w_mem         16-word message-schedule window
      +- bitcoin_compare   byte-reverse the digest, unsigned <= target
```

## Sources and licenses

- `verilog/bitcoin.v`, `bitcoin_engine.v`, `bitcoin_sha256d.v`,
  `bitcoin_compare.v`: **LogikBench** (Zero ASIC Corporation, author Andreas
  Olofsson), `logikbench/benchmarks/large/bitcoin/rtl/`, from
  <https://github.com/masc-ucsc/logikbench> (fork of
  <https://github.com/zeroasiccorp/logikbench>) at commit
  `5bfe889e6861be431b180702406b34fee2e214bc`. MIT License, see
  [LICENSE](LICENSE).
- `verilog/sha256_core.v`, `sha256_w_mem.v`, `sha256_k_constants.v`:
  **secworks/sha256** by Joachim Strömbergson
  (<https://github.com/secworks/sha256>, commit
  `837c5cc396f001d18f2c765721c585716eb439ae`), as vendored by LogikBench under
  `logikbench/benchmarks/blocks/sha256/rtl/`. BSD 2-Clause, see
  [LICENSE.sha256](LICENSE.sha256). LogikBench's bitcoin pulls these in as a
  dependency fileset; they are copied here so the core is self-contained.
  secworks' register-bus top (`sha256.v`) is not used and not vendored.

The seven files are copied verbatim except for one change: the reset is
synchronous. Upstream's flops are `always @(posedge clk or negedge reset_n)`;
here they are `always @(posedge clk)`, with the same `if (!reset_n)` branch
(in `bitcoin_engine.v`, `bitcoin_sha256d.v`, `sha256_core.v` and
`sha256_w_mem.v`; `sha256_core.v`'s comment says so too). Every simulation
here holds reset across clock edges, so the results are unchanged, and the
synchronous reset lets the Pyrope write `w_mem`'s reset as a plain loop (see
the simulation section). The only hand-written Verilog is
`verilog/bitcoin_top.v`, which pins `NENGINES` (upstream defaults to 128, about
1.3M cells: 128 identical lanes add simulation and compile cost but no
coverage).

The genesis-block test vector (header, target, winning nonce `0x1dac2b7c`)
comes from LogikBench's `testbench/test_bitcoin_smoke.v`, and that block is
S. Nakamoto's 2009 Bitcoin genesis block.

## Layout

| Path | Contents |
| --- | --- |
| `verilog/` | the vendored RTL, the wrapper, and `filelist.f` (slang `-F`) |
| `pyrope/` | hand-cleaned Pyrope translation, one file per Verilog module |
| `pyrope2/` | the Pyrope target: same top and ports, reworked where it simulates better (see below) |
| `sim/bitcoin_mine_tb.prp` | timed `lhd sim` benchmark (genesis block + mining stream) |
| `sim/bitcoin_mine_tb_verilator.cpp` | its Verilator twin, with a software SHA256d oracle |
| `verif/bitcoin_engine.verify.prp` | lane-protocol sidecar (the CORES `unit`, `verify_bound` 4) |
| `verif/sha256_core.verify.prp` | sequential sidecar (the CORES `seq_unit`) |
| `verif/bitcoin_compare.verify.prp` | target-check properties; no bench scenario runs it (see its header) |

## The Pyrope translation

Unlike most cores here, `pyrope/` is not raw `--emit-dir pyrope:` output. The
raw emission (1127 lines) proves `PROVEN-full` against the Verilog. The tree
here is a rewrite of it in loops and named state, kept clean under
`lhd pyrope style` and formatted with `lhd pyrope fmt -i --mode human` (which
sorts ports by name and puts long port lists one per line):

- `sha256_k_constants`: a 64-entry `comptime` table, written as eight rows
  joined with `++` so the formatter keeps one row per line, indexed by the
  round.
- `sha256_w_mem`: a 16-word `reg` array (`ordering="old"`, the Verilog
  non-blocking view). Load and slide are one `for` loop with one write per
  slot; the reset is a second loop that writes zeros.
- `sha256_core`: `wv`/`hv` read the working variables and the digest as
  tuples. Their next values `wv_nx`/`hv_nx` are built by loops (IV load, the
  round's shift `(a, ..., h) = (t1 + t2, a, b, c, d + t1, e, f, g)`, digest
  fold) and written back once. `a_reg..h_reg` and `H0_reg..H7_reg` stay one
  register each, named as in the Verilog. A `reg` array lowers to a memory,
  and `lhd lec` cannot pair a memory, or a packed vector, with the Verilog's
  scalar flops; even a 4x8 shift register then stops at `PROVEN-bounded(6)`.
  A tuple-typed `reg` would be the loop-friendly alternative, but LiveHD
  miscompiles it today (see Known-failing). The `// prp-style-allow
  likely-unrolled-loop` on `H0_reg..H7_reg` records that choice.
- `bitcoin_compare`: the byte reversal is one loop.
- `bitcoin`: the lanes are a `for` loop over `bitcoin_engine` instances,
  with the lowest-index arbitration folded into the loop.
- FSM states are enums with the Verilog's encodings. Control signals are
  `Bool`; only `bitcoin_top`'s ports stay `U1`, as in the Verilog.

### `pyrope2/`: the Pyrope target

`pyrope/` follows the Verilog module by module. `pyrope2/` is the same design with the same top and
the same ports on every module, free to be written the way that simulates well. So far one module
differs:

- `bitcoin_compare`: no 256-bit value is built. The little-endian integer's word `j` is digest word
  `j` (H0 first) with its four bytes swapped, so the eight words are compared most significant
  first, each read straight out of `hash` and `target`. `pyrope/` reverses the 32 bytes into a
  256-bit `le` first (one lane write per trip) and then compares 256 bits.

Checks (lhd at `../livehd`, 2026-11-10): `pyrope2/bitcoin_compare.prp` vs `verilog/bitcoin_compare.v`
with `formal.effort=proof` is `PROVEN-full`; the `bitcoin_compare` sidecar proves on it as on
`pyrope/`; `bitcoin_mine_tb` prints the same line (genesis nonce, job count, checksum) for both
trees.

Still wide in both trees, and the next candidates: the digest (`sha256_core.digest`, `h1`,
`hash_reg`: eight words carried as one `U256`) and the blocks (`block_a`, `block_b`, `core_block`:
sixteen words as one `U512`, re-sliced by `sha256_w_mem`).

### Equivalence status (lhd at `../livehd`, 2026-11-07)

| Check | Verdict |
| --- | --- |
| `sha256_core` cleaned vs Verilog | `PROVEN-full` |
| `bitcoin_top` cleaned vs Verilog, compiled with `--set compile.unroll=true` and the 20-pair lane map below | `PROVEN-full` (3 s) |
| `bitcoin_top` cleaned vs Verilog, default compile, `formal.effort=proof` | `PROVEN-bounded(6)` |
| `//bench:bitcoin_lec` (default effort) | `TESTED-sampled` (passes; not a proof) |
| `//bench:bitcoin_lec_bug` (bug1: `busy` drops in ST_WAIT) | `REFUTED-cex` |
| `sha256_core` sidecar, `bitcoin_compare` sidecar | `PROVEN-full` (inductive) |
| `bitcoin_engine` sidecar at bound 4 / with bug1 | `PROVEN-bounded(4)` (`busy_until_found` inductive) / `REFUTED-cex` |

The `unit` is `bitcoin_engine`, not `bitcoin_compare`. A compare bug reaches
`bitcoin_top` only when the first double hash finishes, about 200 cycles in,
and a from-reset LEC never looks that far. The first bug1 (`<=` -> `<` in the
compare) went undetected by `lec_bug` (`TESTED-sampled`), although the
compare sidecar refuted it. The lane's `busy` shows at the top within a few
cycles. Reset holds 17 cycles and a lane needs 3 more to reach ST_WAIT, so
bug1 still PROVES at the default `bound=2`; it refutes at 3, hence
`verify_bound` 4.

The default-compile LEC is bounded because the lanes are a rolled loop. Its
single replicated `lane` instance does not pair by name with the Verilog's
`lane_N_u_eng`. The full proof needs the loop unrolled, which names the
lanes `lane__liN`, plus an explicit map:

```bash
lhd compile verilog --top bitcoin_top --emit-dir lg:ref.lg -- -F verilog/filelist.f -DSYNTHESIS
lhd compile pyrope/bitcoin_top.prp --top bitcoin_top --emit-dir lg:impl.lg --set compile.unroll=true
M=; for g in 0 1 2 3; do for r in nonce d_start state found_reg golden_reg; do
  M="$M,u_miner.lane_${g}_u_eng.$r=u_miner.lane__li$g.$r"; done; done
lhd lec --impl lg:impl.lg --ref lg:ref.lg --top bitcoin_top \
    --set formal.effort=proof --set "formal.lec.match=${M#,}"
```

## Simulation benchmark

`sim/bitcoin_mine_tb.prp` runs a stream of work items. Each item holds reset
for 2 cycles, pulses `start`, and mines until `found`:

1. Work item 0 is the real genesis block at its real difficulty, seeded 5
   nonces below the winner. Lane 1 finds `0x1dac2b7c` (497822588) at cycle
   412. This checks SHA256d, the little-endian compare and the arbitration
   against a value computed outside the suite.
2. Each later item XORs the work-item number into the header timestamp (bits
   [95:64], the way miners roll ntime) and mines against an easy target (top
   four bits zero, a 1-in-16 hit per trial).

Every cycle folds `found`, `busy` and `golden_nonce` into
`sum = (sum * 31 + obs) & (2^63 - 1)`. Every register has a reset, so no
`sim.init_zero`/`unknown_zero` knob is needed. The Verilator twin folds the
same values. It also recomputes every work item's expected golden nonce with
a software SHA256d (the first round with a hit, lowest lane within it) and
fails on any mismatch.

At the benchmark's 4M cycles (4349 work items) all three simulators print
the same line:

```
bitcoin mine: genesis=497822588 at cycle 412 jobs=4349 longest=5945 nonces=5321654734756578181 of 4000000 sum=5631022400016222101
```

`sim_exec_ms` from `bazel test //bench:bitcoin` at the 4M cycles (best of 3,
lhd at livehd 64f318177, 2026-11-07, quiet box):

| Simulator, 4M cycles | `sim_exec_ms` | host C++ |
| --- | --- | --- |
| `lhd sim` on `pyrope/` (`bitcoin_sim_pyrope`) | 1559 | 3144 |
| `lhd sim` on the Verilog (`bitcoin_sim_verilog`) | 618 | 2868 |
| Verilator 5.054 (`bitcoin_sim_verilator`) | 575 | 1348 |

Standalone best-of-7 at 4M cycles: 1.33 s for `pyrope/`, against 1.80 s for
the same tree with upstream's asynchronous reset. The cleaned tree is about
2.5x slower than the Verilog of the same design; at 1M cycles it takes
335 ms, the raw emission 234 ms. Each of these alone made `pyrope/` faster
(1M cycles, best of 5 or 7, timed side by side):

- Giving `w_mem` one write per slot instead of separate shift and load write
  groups: 604 to 464 ms. In the tree.
- Writing `w_mem`'s reset as an explicit `if not reset_n` loop instead of
  declaring it on the `reg`: 452 to 335 ms (-26%). In the tree. It needs
  the synchronous reset; with the upstream asynchronous reset the explicit
  write is not equivalent to the Verilog. Making the reset synchronous while
  keeping it declared changes nothing (462 ms). Writing the core's scalar
  resets explicitly too is slower than leaving them declared (361 ms).
- Unrolling the lane loop by hand: 604 to 492 ms. Not applied: the loop is
  what keeps `NENGINES` generic.

The last two are lhd sim costs: a memory with a declared reset, and a rolled
loop of stateful instances.

## Known-failing

`//bench:bitcoin_compile_pyrope_parallel` fails in LiveHD, not in the suite.
A `comb` whose rolled loop writes bit-slices of a `mut` carry
(`bitcoin_compare`'s `le`) compiles from source. Imported pre-lowered through
`ln:`, as the per-file Makefile does, it fails with
`upass.tolg: unresolved reference 'le'`. Minimal reproducer:

```pyrope
// rev.prp:  lhd compile rev.prp --emit-dir ln:ln_rev
pub comb rev(hash:U16) -> (r:U16) {
  mut le:U16 = 0
  for i in 0..<2 {
    le#[i * 8..+8] = hash#[(1 - i) * 8..+8]
  }
  r = le
}
// top.prp:  lhd compile top.prp ln:ln_rev --top top --emit-dir lg:o   -> fails
//           lhd compile top.prp --top top --emit-dir lg:o             -> passes
const rev = import("rev.rev")
pub mod top(a:U16) -> (o:U16@[0]) {
  o = rev(hash=a)
}
```

### LiveHD defects that shaped the translation

These are not suite targets; they are why `sha256_core` keeps scalar
registers and why a clean compile still prints warnings.

- A tuple-typed `reg` miscompiles. LEC against two scalar `U32` registers
  is `REFUTED-cex`: `o` reads a single bit of `h.b`.

  ```pyrope
  pub mod t2(clk:Clock, reset_n:Reset, d:U32, en:Bool) -> (o:U32@[]) {
    reg h = (mut a:U32 = 0, mut b:U32 = 0)
    if en {
      h = (a=d, b=h.a)
    }
    o = h.b
  }
  ```

  The positional form, `reg h:(_:U32, _:U32) = (0, 0)` with `h[i] = x`, is
  rejected instead: the elements get the range `[0, 0]`.
- `onehot-deferred` warnings: `pass.formal` cannot prove the exclusivity of
  the one-hot mux a runtime index into a constant table becomes once the
  table has more than 8 entries (`comptime const T = [...16 values]`, then
  `o = T[i]` with `i:U4`). It is left as a runtime check. Every compile of
  this tree prints three of these. The one on `sha256_k_constants` is that
  table. The ones on `bitcoin_sha256d` and `bitcoin_engine` are not reduced
  yet: neither module has a table, and the same 4-state `match` in a small
  module compiles without the warning.

## Running

```bash
bazel test //bench:bitcoin                              # every scenario
bazel test //bench:bitcoin_sim_pyrope --test_output=all
lhd sim pyrope/bitcoin_top.prp sim/bitcoin_mine_tb.prp --arg cycles=100000
```
