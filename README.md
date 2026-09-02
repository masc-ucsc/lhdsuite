# lhdsuite

Larger LiveHD tests and benchmarks over real designs, each carried in both
Verilog and Pyrope:

| core | what it is | scale |
| --- | --- | --- |
| `dino/` | dual-issue RISC-V CPU (top `PipelinedDualIssueCPU`) | 17 modules |
| `cva6/` | OpenHW Group CVA6 — whole generated Pyrope core (top `cva6`); the Verilog tree remains a tag-comparator cone and is not substituted into the bench | whole core |
| `minion/` | industrial multi-threaded RISC-V core with a vector/tensor unit — VPU, TxFMA, transcendental ROMs, D-cache, TLB (top `minion_top`) | 179 Pyrope files / 146 Verilog modules |
| `picorv32/` | YosysHQ PicoRV32 — a size-optimized RISC-V CPU (top `picorv32_top`, a parameter-pinning wrapper over the vendored `picorv32`). Both languages ARE the same design here. Its verify sidecar is picorv32's *own* `ifdef FORMAL` spec translated, half of it sequential | 2 modules |
| `matched_filter/` | 64-tap radar matched filter, tap chain + registered adder tree (top `matched_filter`) — the loop-machinery benchmark: three source `for` loops of three shapes, hand-written in both languages; see `matched_filter/README.md` | 3 modules |

Every scenario runs against **every** core; see [Cores](#cores) for how a core
is wired in and how to add one. The suite has two jobs:

1. **Check + benchmark LiveHD** (or your own setup): every scenario asserts
   correctness and reports speed metrics, including incremental re-run speed.
2. **Demonstrate the flow**: each script under `bench/` is a readable,
   self-contained example of driving `lhd` — compile, synthesis, simulation,
   LEC, and formal verification.

LiveHD is built **from source as a bazel dependency** (pinned in
`MODULE.bazel`); there is no PATH or prebuilt-binary lookup. `bazel test`
builds `lhd` (and ABC, slang, yosys, cvc5, … underneath) and then runs the
suite against that binary.

## Setup

1. **Bazel** — install [bazelisk](https://github.com/bazelbuild/bazelisk);
   `.bazelversion` pins the bazel release. Nothing else to install: all C++
   dependencies are fetched and built hermetically.

2. **sky130 tech library** — synthesis scenarios need the sky130 Liberty
   file. The recommended installer is
   [ciel](https://github.com/fossi-foundation/ciel):

   ```bash
   pip install ciel
   ciel enable --pdk-family sky130 $(ciel ls-remote --pdk-family sky130 | head -1)
   ```

   Synthesis benchmarks resolve the newest installed version through `ciel`,
   verify that it is also the enabled version, and record its hash. An
   inherited `HAGENT_TECH_DIR` is deliberately ignored so a stale shell
   setting cannot change the library being measured. If several versions are
   installed and release-date metadata is unavailable, or if newest and
   enabled disagree, the benchmark stops and asks for an explicit human
   choice. `.bazelrc` retains the `HAGENT_TECH_DIR` passthrough for CI
   compatibility, but the benchmark replaces its value after resolution.

3. **Verilator** (optional) — the `sim_verilator` scenario compares `lhd sim`
   against Verilator on the same RTL. `brew install verilator` /
   `apt install verilator`; `bench/common.sh` finds it on `PATH` or in the
   usual install prefixes, and `$VERILATOR` overrides that (`.bazelrc` passes
   it through the sandbox). Unlike the tech library this is a *comparison*, not
   a scenario the suite owns, so **a machine without verilator SKIPS the target
   instead of failing it** — the log says so and `//bench:show` prints
   `verilator: SKIPPED`.

## Running

One bazel target per **(core, scenario)**, named `<core>_<scenario>`, so a
single thing can be benchmarked or debugged in isolation:

```bash
bazel test //...                                    # everything, every core
bazel run //bench:show                              # summary of the last results

bazel test //bench:dino                             # ALL scenarios, dino only
bazel test //bench:minion                           # ALL scenarios, minion only
bazel test //bench:cva6                             # ALL scenarios, cva6 only

bazel test //bench:minion_synth_incremental --test_output=all
bazel test //bench:dino_lec_bug --test_output=all
```

`//bench:dino`, `//bench:minion` and `//bench:cva6` are the per-core suites —
that is the way to run everything for one design. (Each target also carries a `core_<name>`
tag, so `bazel test //... --test_tag_filters=core_minion` selects one core
across a wider pattern.) The cross-core suites `//bench:compile` and
`//bench:sim` run one flow over every design.

`//bench:show` aggregates the `METRIC` lines from `bazel-testlogs/` — the
last run of each target (bazel cannot make a `run` target execute tests, so
test first, then show; anything never run is listed at the bottom). It prints
one section per core; restrict it with `--core`:

```bash
bazel run //bench:show -- --core minion
bazel run //bench:show -- --no-cmds        # compact: drop the CMD listing
```

It also lists the exact `lhd` command lines each bench executed (every
invocation is logged as a `CMD` line, with paths sanitized to repo-relative
form — living documentation of the flow).

`.bazelrc` defaults every build to `-c opt` — benchmark numbers from a debug
lhd are unrealistic. Use `-c dbg`/`--config=debug` only when debugging lhd
itself.

Every row below exists once per core — write `//bench:dino_compile_verilog`,
`//bench:minion_compile_verilog` or `//bench:cva6_compile_verilog`; the `<core>_` prefix is elided in the table.

| target | what it checks / measures |
| --- | --- |
| `compile_verilog` | Verilog → `lg:` via slang; LoC/s, words/s |
| `compile_pyrope` | Pyrope → `lg:` (sibling import discovery); LoC/s, words/s |
| `compile_pyrope_parallel` | per-file separate compilation driven by a **real build system**: `lhd scan` reports every file's imports, `bench/gen_build.py` turns that into a Makefile (one rule per file, prerequisites = its direct imports, pruned to `--top`'s cone), and `make -j` derives the schedule. Dependencies ride in pre-lowered as positional `lg:DIR` inputs, falling back to `ln:DIR` only for packages that emit no lgraph — an `ln:` input is re-elaborated from the AST on every load, so for a `comb` unit that costs as much as recompiling it. `--emit-dir lg:` is transitively closed, so `lg_<top>` is already the complete design library (no link step). The generator also emits a syntax-checked `BUILD.bazel` into the test outputs to show gazelle-style generation; it is never executed. Also demonstrates incrementality: touching one leaf rebuilds only its subtree. Recipes deliberately do NOT clean their emission dirs first, so a rebuild re-emits over the previous run's `ln_`/`lg_`: re-emission has to stay idempotent, and this target must FAIL rather than hide a regression behind an `rm -rf` |
| `synth` | each of the core's colorings (`color_algs`) on the same design (sky130), timing + QoR (regions/gates/area/max_delay + OpenTimer sta_delay) for each. `gates`/`area` are PHYSICAL since 2026-08-23: every mapped region weighed by how many times its module is instantiated in the emitted netlist (a `tap` mapped once but built 64 times counts 64x; a body absorbed into its parent counts inside the parent's row); the per-mapped-module sums are `module_gates`/`module_area`. The `synth` coloring is the ONE-SHOT `lhd synth` (compile -> color synth -> abc -> opentimer in one process, per-step ms from lhd's own `phases`); `flat` is the manual `lhd compile` + `pass color flat` + `pass abc` + `pass opentimer` steps, since `lhd synth` always colors with `synth`. Minion alone runs and reports both; every other core reports only partitioned `synth` coloring. |
| `synth_incremental` | `lhd synth` over 3 passes sharing ONE `--workdir` (the compile cache and `abc_cache/` both live under it, on the one `lhd.incremental` switch); incremental reuse needs the distinct colors/partitions that `color synth` creates (and `color flat` intentionally does not): asserts cache hits on the comment-only pass and a single-region re-synth after a one-line edit. The reuse counters come from the envelope's `incremental.{compile,abc}` member (`--stats` prints them) |
| `synth_lec_flat` / `synth_lec_synth` | netlist integrity: synthesize twice (2nd run after a comment touch — under `color synth` that netlist is largely cache-CLONED), then `lhd lec --impl lg:netlist --ref lg:design --lib lg:models` proves it against the compiled design (`pass liberty gensim` provides the sky130 cell models; strict, so UNKNOWN fails). For `lec_synth` the design side is the one-shot's own `W/synth/lg`. Only Minion generates `synth_lec_flat`; all cores generate the `synth` counterpart. |
| `sim_verilog` / `sim_pyrope` | asserted `lhd sim` benchmark: dino and minion run their whole-core program drivers in both languages. CVA6 runs `cva6_prog_tb` on the whole Pyrope core over AXI for 50k cycles and has no `sim_verilog` target because its Verilog tree does not carry that design. Host C++ compilation and simulation are timed separately, and the timed path disables VCD. The CVA6 gate is intentionally live and currently fails on the generated icache; do not replace it with the old tag_cmp smoke. |
| `sim_verilator` | the same benchmark under **Verilator**, for cores carrying a C++ twin of their `sim_tb` (dino, minion, matched_filter, and the three XiangShan blocks that ship a sim driver — `xs_alu`, `xs_rob`, `xs_renametable`). Same RTL, same timing split, and the same marker/data gates make it both a throughput comparison and a cross-simulator oracle. Verilator is optional host state: a machine without it SKIPS rather than failing |

| `lec` | Pyrope impl ≡ Verilog ref (both pre-compiled to `lg:`; the Verilog side needs its slang options — `-F`/`-DSYNTHESIS` plus the core’s `v_flags`), PROVEN |
| `lec_bug` | the core's `tests/bug1` variant must be REFUTED (dino: the ALU's 32-bit add flipped to subtract; minion: the same flip in `txfma_adder`; cva6: way 0's hit ignores the line's valid bit) |
| `lec_incremental` | cold / identical warm (verdict-cache hits) / comment-touch re-runs |
| `verify` | the core's `verif/<unit>.verify.prp` assert/assume all PROVEN (strict). The gate is the per-obligation verdicts in `formal_report.json`, pinned to the assert COUNT the sidecar declares (`--list-tests`): every assert PROVEN *and* as many of them as there should be, so an obligation that stops being generated fails the target instead of shrinking the check |
| `verify_bug` | the formal twin of `lec_bug`: against the core's `tests/bug1` variant the sidecar must REFUTE, with a counterexample trace — proving the sidecar is only half the contract, the other half is that a real bug is caught |
| `verify_temporal` | the core's `verif/<seq_unit>.verify.prp`: SEQUENTIAL properties, relating one cycle to the next with `past`/`stable`, proven at a deeper bound (8). The `unit` sidecars are pure arithmetic and cannot exercise that machinery at all. Only generated for a core declaring `seq_unit` (dino: `StageReg` — load / hold / flush / reset are each a "one cycle after" claim; minion has none yet) |
| `verify_incremental` | cold / warm (obligation-cache hits) / comment-touch |

Each test prints `METRIC <name> <value> <unit>` lines (also collected as
`metrics.jsonl` under `bazel-testlogs/bench/<target>/test.outputs/`). Targets
are tagged `exclusive` so timings are never polluted by parallel tests.

The test log itself is deliberately terse — the `CMD` and `METRIC` lines, one
compact `PROGRESS pass.abc` heartbeat as each synthesis color completes, plus
a short excerpt when a step fails. Each heartbeat names the region/color and
reports cache status, input GE, output gates, and elapsed milliseconds; its
full structured row (area, delay, RSS, and critical endpoint included) remains
in the step's JSONL output. Each step's FULL stdout/stderr is saved beside
`metrics.jsonl` as `step_<label>.log`, so `--test_output=all` on a failing
target gives you the diagnosis and the file to open next. Progress is enabled
by default; set `BENCH_PROGRESS=0` only when a caller needs silent stdout.
Three knobs:

```bash
bazel test //bench:minion_lec --test_env=BENCH_VERBOSE=1   # dump step logs inline
bazel test //bench:minion_lec --test_env=BENCH_FAIL_TAIL=40 # longer excerpt
bazel test //bench:minion_synth --test_env=BENCH_PROGRESS=0 # retain progress only in the full step log
```

Scenario cost scales with the design: everything on dino finishes in seconds,
while minion's proof- and synthesis-heavy scenarios (`lec*`, `synth*`) are
long-running — they carry bazel's `eternal` timeout so a slow proof is not
reported as a spurious failure. Bound them per invocation when you want a
result within a fixed budget:

```bash
bazel test //bench:minion --test_timeout=1800     # give up after 30 min each
```

Measured on an M-series laptop against the pinned lhd, for scale: minion
compiles in 42s from Pyrope and 41s from Verilog; `minion_lec_bug` refutes the
injected bug (with the latch modules trusted, it now sweeps the full design
first, so ~12 min); `minion_lec` proves 110/140 non-trusted defs and trusts 32
latch defs (`formal.lec.trust`, see the Known-failing table), ending UNKNOWN on
the non-latch cones the solver cannot discharge. `minion_synth` is the long
pole at ~12 min (264 regions, 423k gates; `pass abc` alone is 669s and peaks
around 25 GB RSS) — budget accordingly, but no special timeout is needed.

Minion is the sole flat-synthesis comparison point: it runs both `color flat`
and `color synth`. Every other core runs only `color synth`, and the report
does not print an empty flat row for them. This is selected by each core's
`color_algs` entry rather than by special-casing the synthesis script.

### Driving the sim flow by hand

`lhd sim --setup-only` stops after writing the driver: `<workdir>/sim/` is a
self-contained bazel workspace (`MODULE.bazel`, `BUILD`, one `.cpp`/`.hpp` per
module, `drv.cpp`), so the host C++ build is yours to drive — useful when you
want to iterate on the generated code, keep an incremental build across edits,
or just run the simulation more than once:

```bash
./bazel-bin/external/livehd+/lhd/lhd sim --setup-only \
  ./dino/pyrope/PipelinedDualIssueCPU.prp dino/sim/dino_prog_tb.prp --workdir tmp_sim
cd tmp_sim/sim/
bazel build -c opt //...
bazel run   -c opt //:drv
./bazel-bin/drv --help
```

(`./bazel-bin/external/livehd+/lhd/lhd` is the binary this repo's bazel build
produces — `bazel build @livehd//lhd:lhd` if it is not there yet. Any `lhd` on
your PATH works the same way.)

The design comes first, the testbench second; `--workdir` is the only state
(everything below it is regenerable). `//:drv` is the driver binary, and it
takes the arguments `lhd sim` would have forwarded:

```bash
./bazel-bin/drv --list-tests                  # tests + their parameters, as JSON
./bazel-bin/drv --test cpu.prog --cycles 200000
./bazel-bin/drv --result-json out.json        # {test,status,cycle,failing_assert,…}
```

A test parameter is bound by name — `lhd sim --arg cycles=200000` reaches the
binary as `--cycles 200000`, so `--list-tests` is the authoritative list of
what a driver accepts (`dino_prog_tb.prp` exposes `cycles`, default 1000000).
Adding `--set sim.vcd=true` to the `--setup-only` line makes the run dump a VCD.

`lhd sim` without `--setup-only` does this compile itself and then simulates;
`bench/sim.sh` splits the two (`--setup-only`, then `--run-only`) precisely so
the reported time separates the host C++ compile from the simulation.

### Simulating the Verilog side

`lhd sim` accepts `lg:DIR`/`ln:DIR` IR inputs exactly like `lhd compile`, so the
Verilog tree needs no Pyrope round-trip: compile it into a library once, then
hand that library to the testbench.

```bash
./bazel-bin/external/livehd+/lhd/lhd compile verilog --top PipelinedDualIssueCPU \
  --emit-dir lg:lgdb -- -F ./dino/verilog/filelist.f -DSYNTHESIS
./bazel-bin/external/livehd+/lhd/lhd sim lg:lgdb dino/sim/dino_prog_tb.prp --workdir tmp2
```

The design is the positional `lg:lgdb`, the testbench the `.prp` after it — the
same order as the all-Pyrope form above, and `--setup-only` / `--run-only` /
`--arg` / `--set sim.vcd=true` all behave identically. On minion, add that
core's `v_flags` to the slang side (`--relax-enum-conversions
--allow-use-before-declare`); see [Cores](#cores).

What binds the two commands is the testbench's import:

```prp
const cpu = import("lg:PipelinedDualIssueCPU")   // dino/sim/dino_prog_tb.prp
```

`lg:NAME` is a **module name in the library** (the names in `lgdb/library.txt`),
not a path — the `lg:DIR`/`ln:DIR` positionals say where to look. The same
import also resolves against a design compiled from `.prp` sources in the same
run, so ONE testbench drives both trees: `lhd sim ./dino/pyrope/…prp
dino/sim/dino_prog_tb.prp` keeps working unchanged.

`bench/sim.sh`'s `MODE=verilog` does exactly this. It used to go the long way
round (`--emit-dir pyrope:tree`, then sim that tree), which measured the Pyrope
front end a second time and put an emitter round trip between the Verilog and
the thing being simulated.

One caveat the bench encodes: **root the library at the module the testbench
drives, not at the core top.** `lhd sim` cgen's every graph in the library it
is handed, so `lhd sim lg:<whole minion_top library> tensora_rf_tb.prp` refuses
over `vpu_ctrl` and `intpipe_csr_file` — neither anywhere near the tensor RF —
while `--top vpu_tensora_rf` compiles in 63 ms and simulates. That is what the
`sim_tb_unit` / `sim_top_tb_unit` knobs in `bench/defs.bzl` are for.

### Comparing against Verilator

`//bench:<core>_sim_verilator` runs the same program on the same Verilog under
Verilator, split into the same three timed steps. By hand:

```bash
verilator --cc --exe --build -j 0 --top-module PipelinedDualIssueCPU \
  -Wno-fatal -DSYNTHESIS -F dino/verilog/filelist.f \
  dino/sim/dino_prog_tb_verilator.cpp
./obj_dir/VPipelinedDualIssueCPU --cycles 1000000
```

`dino/sim/dino_prog_tb_verilator.cpp` is a line-by-line twin of
`dino/sim/dino_prog_tb.prp` — same ROM, same asserts, same printed line, and
the same stimulus schedule (the three `eval()`s per cycle reproduce Pyrope's
drive / read / `step` / read order, which is why both print `done at cycle
506`). Keep them in lockstep: an edit to the program or the drive order belongs
in both, and the bench gates both on the same strings so a divergence fails a
target.

Minion follows the same pairing with `minion_prog_tb_verilator.cpp` and
`minion_prog_tb.prp`, driving `minion_top` for the whole-core program workload.

The XiangShan blocks pair the same way — `xs_<block>_tb.prp` with
`xs_<block>_tb_verilator.cpp`. Their `sim_cycles` is chosen so that VERILATOR
spends 1-2 s simulating (25M for `Alu`, 25k for `Rob`, 40k for
`RenameTableWrapper`), and `verilator_cycles` is set equal to it, which makes
the matched run the throughput run and skips the second long leg — at those
counts neither simulator is reporting its own ~16-19 ms process startup, and
`lhd sim` and Verilator can be read cycles/s against cycles/s on the same work.
One difference matters when reading their numbers: these drivers assert no
golden value in source (they cannot reach the datapath — see the header of
`xs_alu_tb.prp`), so the ONLY statement that the simulators agree about the
block is that all three print the same `sum=` checksum, which is what
`sim_expect` pins at the matched count. A divergence there is a bug in one of
them, and building the twins surfaced two:

* **`wrap` on a `u64` can leave a NEGATIVE representative of the value**, which
  made `lfsr >> 7` an ARITHMETIC shift and the Pyrope stimulus diverge from a
  plain `uint64_t` xorshift64 at cycle 4. The drivers now spell that shift as
  the bit slice `lfsr#[7..=63]`, the same logical shift under either reading —
  do not change it back to `>> 7`.
* **X-fill is not the same on both sides.** `lhd sim` draws the power-on bits of
  a reset-free flop from the run's seeded PRNG; Verilator is 2-state and
  zero-fills. `Rob` has three such flops and their bits reach `io_enq_isEmpty`,
  so its checksum moved with `--seed` and never matched Verilator. `xs_rob`
  therefore carries `sim_sets: --set sim.unknown_zero=true`, which is the fair
  setting for the comparison (holding X-uncertainty is work Verilator does not
  do at all) and also the one that makes lhd's own number honest — the drawn
  bits defeat constant folding, and lhd goes from 6.1k to 15.2k cycles/s with
  them zeroed, i.e. from 2.5x slower than Verilator to a dead heat.

## Known-failing scenarios

The suite's job is to surface LiveHD gaps, so some targets fail by design
rather than being disabled. Against the pinned lhd that is the two `minion_lec`
rows, the asserted `cva6_sim_pyrope` / `cva6_sim_incremental` program runs,
the four `picorv32` rows below,
and — added 2026-08-21 — `genprp_minion` plus the two
xiangshan genprp rows (`genprp_xs_enqentry_4`, `genprp_xs_tracebuffer`).
`dino_sim_verilog` has left this table: its `io_in` mismatch turned out to be
suite-side and is fixed (`sim_tb_v`, below). CVA6's cross-language LEC targets
are no longer generated: the benchmark top is the whole Pyrope core and the
vendored Verilog tree contains only the unrelated tag-comparator cone.

| target | blocked by |
| --- | --- |
| `picorv32_sim_verilog`, `picorv32_sim_pyrope` | **`lhd sim` never issues picorv32's store.** The driver runs a RISC-V program and reads the result back architecturally, through the program's own `sw`. Under `lhd sim` no write strobe is ever driven — `mem_wstrb` stays 0 for the whole run, on BOTH the Verilog and the Pyrope side, so the readback gate fails. The RTL is fine and an independent simulator says so: `picorv32/sim/picorv32_min_tb.v` is a 3-instruction version of the same program with the same one-cycle-latency memory model, and **Icarus Verilog on the identical sources prints `c=21 a=256 instr=0 wstrb=15 wdata=5`** — the store, with the right address and data. That file carries the one-line repro command; it is an oracle, not a bazel target. Two further divergences sit underneath and are worth separating when fixing: `lhd sim` on the *Verilog* lgraph at least keeps fetching (0,4,8,12,…) while the *Pyrope* one stalls after two fetches, so the emitter has a second, independent defect on top of the shared missing-store one |
| `picorv32_lec` | **`lhd lec` cannot give picorv32 an UNBOUNDED proof.** It exits 0 but reports *`PASS(6)` equivalent for 6 cycles from reset (exhaustive over inputs; deeper cycles not checked)*, and the gate correctly refuses that: every other core's LEC returns an unbounded PROVEN through the flop-cut inductive miter. Here the 16 cones all discharge (`16/16 PROVEN by abc in 35 ms`) yet the top still falls back to a 6-cycle bounded verdict. Since picorv32 holds reset for **22** cycles, those 6 checked cycles lie entirely INSIDE reset, so the pass says almost nothing about the running CPU. Do NOT loosen the gate to accept a bounded verdict — the gate is the only thing distinguishing a real equivalence proof from a short simulation |
| `picorv32_lec_bug` | the same bounded window, seen from the other side: `bug1` makes an instruction fetch drive a write strobe (`mem_wstrb = 0` -> `= 1`), and LEC PROVES the bugged design equivalent because the difference first appears at the CPU's first fetch, around cycle 23 — outside the 6-cycle window. Unlike the cva6 case this is not a false PROVEN: lec is explicit that deeper cycles are unchecked. The bug is real and the formal side catches it once it can see past reset (measured: PROVEN at `formal.bound=2`, REFUTED at 8), which is what the per-core `verify_bound` knob is for |
| `cva6_sim_pyrope`, `cva6_sim_incremental` | **The generated `cva6/pyrope/cva6_icache.prp` mistranslates every fetch address, so the core never retires an instruction.** `cva6_prog_tb.prp` is now the main asserted benchmark, not an informational auxiliary metric: it drives the whole core over AXI with a real RISC-V program and stays red until the generated core executes it correctly. Do not weaken its architectural assertions or replace it with the old tag_cmp smoke. |
| `minion_lec`, `minion_lec_incremental`, `minion_synth_lec_synth` | **UPDATED 2026-07-31: `minion_lec` is 133/140 proven, 31 trusted, 0 REFUTED, 7 UNKNOWN, exit 7** (was 127/13 UNKNOWN). Five LiveHD bugs were fixed to get there and three of them were SILENT MISCOMPILES, which is what this bench exists to surface: (1) `upass/tolg` probed `pin_map_` with the raw, still-backtick-escaped name in `set_mask_base`, so a conditional partial write to any struct leaf substituted a `0sb?` base and dropped the value the variable was carrying; (2) `pass.prp_writer` folded an expression across a reassignment of a name it reads, so a `function automatic` called once per unrolled loop iteration came out reading the LAST iteration N times (`vpu_trans`: `id_trans_busy_o = ((0 | is_used) | is_used) | …`); (3) `upass/constprop` let a CONST-index read of a comb array fold to the array's declared init, deleting the write — which is how every whole-array copy round-trips, since the Pyrope writer expands one into N const-indexed per-entry stores. Plus the Verilog→Pyrope emission was NONDETERMINISTIC (two regenerations differed in 22 files, and `_sN` uniquing RENAMED generate-loop replicas, so a checked-in Pyrope tree could not be paired against a fresh reference compile), and `pass/lec` gained a whole-array memory decomposition plus box congruence (`vpu_mask`: 1200 s UNKNOWN → PROVEN in 84 ms). The remaining 7 UNKNOWN are three leaves and the four ancestors they block: `vpu_lane` (its `prim_rf_3r2w_preview` holds 2 latch cells + 2 negedge flops, so it must stay a trusted UF box — the fixme-1e latch class, not a translation bug), `intpipe_csr_file` (a single-step CEX on `nxt:reg_scause_pre`), and `minion_dcache_top` (size: 18 collapsed children, all proven). `minion_lec_bug` still catches the injected bug, and dino stays green. See fixme issue 1 "STATUS 2026-07-31 (e)" and §§17-21.<br><br>the LEC encoder now MODELS latches and negedge flops (`pass.single_edge` normalizes them to posedge, and folds a clock gate into a flop enable), so minion runs with **zero latch refusals and zero refutations**. Four independent residuals remain: a memory on a *gated* clock is still refused (`core_top`, in ~1 s — the immediate blocker), four latch-free leaf cones the solver cannot discharge (`vpu_mask` et al.), `intpipe_csr_msgs` needing inductive strengthening, and the 32 defs on the `lec_trust` knob (`bench/defs.bzl`) whose latches live ONE MODULE LEVEL DOWN — normalizing inside a def is not supported yet. `formal.lec.trust` assumes those 32 equal (disclosed, never proven), so 113/140 of the rest prove bottom-up. `minion_lec_incremental` has no separate cause — it dies on its first `lec_cold` step. See fixme issue 1.<br><br>**UPDATED 2026-07-27 (c) — ZERO refutations. `minion_lec` is now 119/140 proven, 31 trusted, 0 REFUTED, 21 UNKNOWN, exit 7** (was 116/31/5-refuted/exit 10). The five refuting blocks were TWO LiveHD bugs, each a single line of misclassification, both in the Verilog->Pyrope direction that this bench exists to police. (1) `upass/prp_writer`: the clock/reset-pin cone walk was seeded from the RAW `*_pin` net set instead of the position-independent-filtered cone, so when the pin ref was ITSELF a `wire` — `wire clkgt:u1` + `clock_pin=ref clkgt`, i.e. every emitted ICG module — the walk STARTED on it and dove through, hoisting a clock gate's whole enable cone above the `always_comb` it reads; Verilog `always_comb` is order-independent but Pyrope is sequential, so the enable folded to a tautological constant. A `reg` clock ref (a divided clock) is the same class and needed the same filter. Fixed `minion_dcache_cache_op_unit_l2` and `minion_frontend_thread_buffer{,_p1}`. (2) `upass/ssa`: a >=3-child (tuple_set) store `arr[i] = v` fell through to a VERBATIM copy, so its index/value operands never followed `rename_map` — a reassigned `mut` reached the store on its stale base name, constprop folded that to the declaration value, DCE deleted the real write. Fixed `minion_dcache_tensor_load{,_p1}`. **Note this corrects fixme 1h, which attributed it to a tolg array-store: the RHS is already wrong in the LNAST that reaches tolg.** Exit 10 -> 7 means the run went from finding a real inequivalence back to the pre-existing UNKNOWN class (6 word-level-cycle refusals, 2 derived-clock, 2 budget), which is what still fails the target. Gated by `//lhd/tests:prp_writer_clock_cone_order_test` (verified to fail without the fix) and three array equiv pairs promoted out of `fixme`.<br><br>**UPDATED 2026-07-27 (b) — after making a struct a BUNDLE everywhere inside LiveHD (both front ends agree; `flat_top_io` packs only the top interface for generated-vs-original Verilog equivalence): `prim_mul_div` now PROVES and the tally improves to **116/140 proven** (was 113), but the walk no longer short-circuits on it, so blocks it used to mask are now reached. Failing blocks went 4 -> 5: `prim_mul_div` FIXED; `minion_dcache_cache_op_unit_l2` unchanged (refutes with BOTH port representations — an independent, real issue); `minion_dcache_tensor_load`(+`_p1`) and `minion_frontend_thread_buffer`(+`_p1`) refute ONLY when bundled and PROVE when both sides are flat, witness `debug_o.gated_clk_ticks(ref=2 impl=1)`. **RESOLVED by falsification: the FLAT comparison was VACUOUS on struct-output fields.** Injecting a deliberate `+2`-instead-of-`+1` bug into that counter and re-running: flat says **PROVEN** (blind), bundled says **REFUTED** (catches it). So flat struct ports were producing FALSE PROVEN on those fields, and bundles-everywhere is *finding* pre-existing bugs rather than causing them — the earlier 113/140 was partly vacuous. The remaining difference is a counter on a GATED clock (`clock_pin=ref clock_gated`, minion_frontend_thread_buffer.prp:45), i.e. the gated-clock modelling residual this table already names, now actually observable. Regenerating the checked-in Pyrope does NOT change any of these. Exit stays 10.<br><br>**UPDATED 2026-07-27 (a) — the top no longer ends UNKNOWN/exit 7; it REFUTES with exit 10, and the cause is NOT a memory.** Root-caused by divide-and-conquer down to a 2-second reproducer (`//lhd/tests:lec_trusted_box_struct_port_test`, fixme-tagged): a **TRUSTED def whose struct ports are a flat bus on the reference side and per-leaf on the implementation side cannot be paired**. `lhd/lhd_kernel_compile.cpp` deliberately gives the graphs flow FLAT struct ports ("that flat lgraph is the LEC reference") and the pyrope flow TUPLE ports, which compile to `base.field` leaves. `pass/lec` bridges that for top-level IO (`query.cpp` "Tuple-leaf <-> flat-bus port bundles" ~:1725), but an internal trusted instance is a BOX whose ports pair purely BY NAME (`encode.hpp` `Comb_box`: `in_ports` is a name-sorted concat layout, `out_fn`/`out_w` are keyed by port name). `din` vs `din.fp`/`din.addr`/`din.thread_id` are disjoint names, so `build_in_ports` (`query.cpp:2266`) unions them into one oversized layout, each side drives only its half, and the box outputs become unrelated free symbols — Unknown at small scale, a false REFUTED at `prim_mul_div` scale (`resp_dest` ref=126 impl=127, differing only in bit 0 = `thread_id`). Proven NOT a front-end bug: `intpipe_mul_div_ctl` LECs PROVEN standalone, and lgcheck proves a netlist regenerated through the emitted Pyrope against the original. FIX: apply the same leaf<->bus normalisation to box instance ports |

| `genprp_minion` | **does not reach lec: step `gen` exits 7 with `unsupported-driver-order` on `rr16_f6a_h`** (`minion/verilog/txfma_f6.sv:219`) — "a driver reads that net and also writes it, before any driver has written it", i.e. the generate-loop reduction-tree pattern `--reader slang` cannot order (its own hint names `lzc.sv` / `rr_arb_tree.sv` and suggests `--reader yosys-slang`). Re-measured 2026-08-21. This CORRECTS the older note that had it regenerating cleanly and then refuting at `prim_rst_sync`: that reading came from log text, because `verif/genprp.sh` used to `exit 0` on any failing step (its `step()`
captured `$?` inside an `if ! ...` branch, where it is always 0; fixed 2026-08-21,
see the comment on `step()`), so the target was falsely GREEN and never reported a verdict at all |
| `genprp_xs_enqentry_4` | **`inou.slang` dies with `std::bad_alloc` in step `gen`.** Reproducible on an idle 64 GB box, where it reaches **34.4 GB RSS at ~47s** before dying (under parallel load it dies earlier, at 17.1 GB / 55s — the wall moves, the failure does not). The design is small: 275 KB of `.sv` that emits ~1056 Pyrope lines. Siblings `EnqEntry` and `EnqEntry_18` die identically, so the whole 15-module `EnqEntry` family is unreachable. The one that survives, `EnqEntryVecMem`, still peaks at **24.7 GB** for 1038 emitted lines — so this is a front-end memory blowup on the family, not one pathological module. `genprp_xs_enqentryvecmem` is deliberately wired next to it as the canary |
| `genprp_xs_tracebuffer` | **the GENERATOR creates a false combinational cycle.** `lec` encodes the Verilog reference fine and then refuses the implementation: `impl encode failed: operand of 'get_mask_4184' has no encodable driver (combinational cycle?)`, with a `WORD-LEVEL CYCLE` whose every hop is inside the emitted `gen/TraceBuffer.prp` (`:333 -> :417 -> :416 -> :414 -> :403 -> :389 -> :417`). Exit 7, ~3s, one module, no imports — the cheapest reproducer in the tree for this class. `fpsqrt_r16_block` fails the same way (3.6s, 4 files). Contrast `Reduction`, which reports `ref encode failed` on the **Verilog** side — that one is an encoder limit, NOT prp_writer, and is not wired up. Same family as the word-level-cycle refusals already named in the `minion_lec` row |

These are LiveHD-side issues, not suite configuration — the natural follow-up
task now that the bench exists. Everything that *is* a suite concern (choosing
tops and units that live in the right cone, tolerating package-only leaves
that emit no lgraph) is already handled.

`compile_pyrope_parallel` passes but is still ~4x SLOWER than the monolithic
`compile_pyrope`, and that gap is LiveHD-side too. `pass.formal` (`mode:fast`,
on by default at O1) re-proves every graph in the library on every invocation,
imports included — so separate compilation pays it once per file over that
file's whole closure, where the monolithic compile pays it once over the whole
design. Measured on minion: `intpipe_csr_file` 32.9s -> 0.67s with
`compile.formal.mode=none`, `core_top` 36.0s -> 1.0s, the whole monolithic
design 43.4s -> 5.1s. LiveHD already has a formal verdict cache
(`lhd/formal_cache.cpp`), but it is wired only into `lhd lec` / `lhd formal`;
`pass/formal/pass_formal.cpp` never consults it. Caching or skipping
already-proven imported graphs is what would make the parallel flow win. Do NOT
"fix" this by turning formal off in the bench — that would make the two rows
measure different work.

## The three-pass pattern

Incremental scenarios run passes sharing one `--workdir` (LiveHD's caches —
`abc_cache/`, `formal_cache.json` — live under it):

- **pass 1** — cold: everything is really computed;
- **pass 2** — the core's `tests/comment1` variant (a comment-only touch:
  nothing really changed): incremental caches must hit;
- **pass 3** — a small real edit: either `tests/bug1` (must be caught by
  LEC/formal) or a real-but-correct change (must re-run only what changed).

For `synth_incremental` the gate is **time re-mapped, not hit count**: pass 2
must re-synthesize at most half the wall time the cold map spent (the
`remapped` column in `//bench:show`, from pass.abc's per-region `miss_ms`). A
hit *count* is not a speedup — minion once reported 199 of 264 regions hitting
and a 1.0x speedup, because the regions that missed held ~all the mapping time.
The gate also fails outright on any `store-failed` region (one the cache could
not snapshot, so it re-runs ABC forever — a livehd bug, distinct from the
principled `uncacheable` refusals a region digest makes by design).

Variants are checked-in patched copies, applied by overlaying the file onto a
copy of the core's `pyrope/` tree — so a plain `diff` shows exactly what a
scenario injects (one flipped operator):

```bash
diff dino/pyrope/ALU.prp           dino/tests/bug1/ALU.prp
diff minion/pyrope/txfma_adder.prp minion/tests/bug1/txfma_adder.prp
```

## Cores

A core is a directory with a `BUILD` exposing seven filegroups (`verilog`,
`verilog_filelist`, `pyrope`, `pyrope_top`, `sim`, `verif`, `tests`) plus one
entry in the `CORES` table in `bench/defs.bzl`. That entry names the module
each scenario targets:

| knob | dino | minion | cva6 | matched_filter |
| --- | --- | --- | --- | --- |
| `top` — whole-design top (`pyrope_only` may omit cross-language legs) | `PipelinedDualIssueCPU` | `minion_top` | `cva6` (Pyrope-only) | `matched_filter` |
| `unit` — module carrying the verify sidecar + `bug1`/`comment1` (must be in the top's cone) | `ALU` | `txfma_adder` | `alu` | `tap` |
| `v_flags` — extra slang options for this core's Verilog | *(none)* | `--relax-enum-conversions --allow-use-before-declare` | `--single-unit` | *(none)* |
| `sim_tb` / `sim_cycles` — asserted, timed sim benchmark | `dino_prog_tb.prp` / 1,000,000 | `minion_prog_tb.prp` / 100,000 | `cva6_prog_tb.prp` / 50,000 | `matched_filter_tb.prp` / 5,000,000 |
| `sim_tb_unit` — the module `sim_tb` drives, i.e. what it spells in `import("lg:NAME")`; the design supplied before it is rooted HERE, not at `top` | `PipelinedDualIssueCPU` | `minion_top` | `cva6` | `matched_filter` |
| `sim_tb_v` — MODE=verilog override for `sim_tb` (`""` = one driver for both) | *(none)* | *(none)* | *(none)* | *(none)* |
| `sim_top_tb` / `sim_top_tb_unit` / `sim_top_cycles` — separate whole-top correctness run | `dino_tb.prp` / `PipelinedDualIssueCPU` / 1,000 | `vpu_top_tb.prp` / `vpu_top` / 64 | *(none)* | *(none)* |
| `sim_prog_tb` / `sim_prog_tb_unit` / `sim_prog_cycles` — optional additional correctness run | *(none; program already benchmarked)* | `tensora_rf_tb.prp` / `vpu_tensora_rf` / 100,000 | *(none)* | *(none)* |
| `verilator_tb` / `verilator_flags` / `verilator_cycles` — the Verilator comparison (`""` = no `sim_verilator` target for this core) | `dino_prog_tb_verilator.cpp` / *(none)* / 2,000,000 | `minion_prog_tb_verilator.cpp` / *(none)* / 200,000 | *(none)* | `matched_filter_tb_verilator.cpp` / *(none)* / 20,000,000 |

**Why a core may need two sim drivers.** The two trees are the same design but
need not be the same Pyrope. A `struct packed` port re-emits from Verilog as a
tuple port (`io_in:(instruction:u32, pc:u64, isValid:u1)`); if the checked-in
Pyrope tree declares that same port flat (`io_in:u97`), a driver written for
one shape names no field of the other, and `sim_tb_v` points MODE=verilog at a
twin that drives the tuple leaves and prints the same packed value (one
`sim_expect` gates both). dino's former `StageReg` microbenchmark used to be
exactly that case. It no longer is: `dino/pyrope/` is regenerated from
`dino/verilog/`, so the tuple port is now the shape on BOTH sides; the knob
stays for the next core that needs it. Note
that a tree regeneration can therefore RETIRE this knob (as here) or newly
require it; a `sim_pyrope` failing with "unknown field ... on instance" is the
symptom. Fixing this by flattening the
emission (`compile.slang.struct_port_bundles=false`) is deliberately NOT done:
bench scripts do not carry lhd flags that exist only to make a bench pass, and
graph flows keep ports flat anyway, so `sim_verilog` is the suite's only
coverage of tuple ports. (`MODE=verilog` no longer re-emits Pyrope, but it
still sims the *slang* lgraph, whose struct ports are bundles — so that
coverage is unchanged; only the round trip through `.prp` is gone.)

**minion's slang options.** Its RTL assigns enums from plain bits and refers
to identifiers above their declaration, so the Verilog front-end needs
`--relax-enum-conversions --allow-use-before-declare` on top of the shared
`-F filelist.f -DSYNTHESIS`. `minion/verilog/intpipe_csr_file.sv` `` `include ``s
eight generated `intpipe_csr_file_auto_*.svh` files; those resolve relative to
the including file, so **no `-I` is required** — but they are not compiled
directly, so they are absent from `filelist.f` while still being globbed into
`//minion:verilog` so they reach the test sandbox.

Equivalent by hand:

```bash
lhd compile verilog --top minion_top --emit-dir lg:out -- \
  -F minion/verilog/filelist.f -DSYNTHESIS \
  --relax-enum-conversions --allow-use-before-declare
```

**cva6's scope.** The benchmark is the whole generated Pyrope core (top
`cva6`). Its vendored Verilog directory is still only the `tag_cmp` cone from
[openhwgroup/cva6](https://github.com/openhwgroup/cva6), so CVA6 does not
generate `compile_verilog`, `sim_verilog`, or cross-language `lec` targets;
substituting that cone would measure a different design. Synthesis and the AXI
program simulation use the full hierarchy. Formal uses its integer `alu` and
proves ADD/SUB, including a live mutant-refutation leg; directly encoding the
whole top currently refuses an unrelated word-level cycle in the FPU.
`tag_cmp_wrap.sv` remains local cone collateral because standalone tag_cmp type
parameters collapse without the wrapper's concrete cache-line bindings.

## Benchmarking a LiveHD checkout (or your own changes)

The default `MODULE.bazel` pins a top-of-tree LiveHD commit — and that is the
ONLY pin here: livehd is self-contained as a dependency (its iassert/hlop/hhds
siblings ride git pins inside livehd's own `MODULE.bazel`, and
`@livehd//lhd:lhd` stages the `lhd sim` runtime headers in its runfiles). To
run the suite against a local checkout instead, either:

```bash
bazel test //... --override_module=livehd=../livehd
```

or swap between `git_override` and `local_path_override` in `MODULE.bazel`.
`MODULE.bazel` currently uses `local_path_override` on `../livehd` (its HEAD
is ahead of the pushed `origin/master`); swap back to a `git_override` pin
once those commits are pushed. Bumping a pin is a one-line commit edit.

## Layout

Every core uses the same shape (`<core>/` = `dino/`, `minion/` or `cva6/`):

- `<core>/verilog/`, `<core>/pyrope/` — the design in both languages (the
  Pyrope is the LiveHD translation of the same RTL). `verilog/filelist.f` is
  the slang `-F` source list.
- `<core>/sim/` — simulation drivers (Pyrope `test` blocks).
- `<core>/verif/` — formal assert/assume sidecars.
- `<core>/tests/<variant>/` — checked-in patched sources for the multi-pass
  scenarios (`bug1`, `comment1`).
- `<core>/BUILD` — the seven filegroups the bench targets consume.
- `bench/` — one script family per flow (`compile.sh`, `synth.sh`, `sim.sh`,
  `lec.sh`, `verify.sh`), `MODE`-selected scenarios, shared helpers in
  `common.sh`, the per-core `CORES` table and target generator in `defs.bzl`,
  targets in `BUILD`.

The bench scripts are core-agnostic: they read the design through `CORE_*`
environment variables (`CORE_TOP`, `CORE_V_FLAGS`, `CORE_UNIT`, `CORE_SIM_TB`,
…) that `bench/defs.bzl` sets per target — the contract is documented at the
top of `bench/common.sh`.
