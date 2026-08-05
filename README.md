# lhdsuite

Larger LiveHD tests and benchmarks over real designs, each carried in both
Verilog and Pyrope:

| core | what it is | scale |
| --- | --- | --- |
| `dino/` | dual-issue RISC-V CPU (top `PipelinedDualIssueCPU`) | 17 modules |
| `minion/` | industrial multi-threaded RISC-V core with a vector/tensor unit — VPU, TxFMA, transcendental ROMs, D-cache, TLB (top `minion_top`) | 179 Pyrope files / 146 Verilog modules |

Every scenario runs against **both** cores; see [Cores](#cores) for how a core
is wired in and how to add a third. The suite has two jobs:

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
   export HAGENT_TECH_DIR=$(dirname $(find ~/.ciel -name 'sky130_fd_sc_hd__tt_025C_1v80.lib' | head -1))
   ```

   Any directory containing `sky130_fd_sc_hd__tt_025C_1v80.lib` works.
   `.bazelrc` passes `HAGENT_TECH_DIR` through the test sandbox; tests that
   need it fail with these instructions when it is missing.

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
bazel test //...                                    # everything, both cores
bazel run //bench:show                              # summary of the last results

bazel test //bench:dino                             # ALL scenarios, dino only
bazel test //bench:minion                           # ALL scenarios, minion only

bazel test //bench:minion_synth_incremental --test_output=all
bazel test //bench:dino_lec_bug --test_output=all
```

`//bench:dino` and `//bench:minion` are the per-core suites — that is the way
to run everything for one design. (Each target also carries a `core_<name>`
tag, so `bazel test //... --test_tag_filters=core_minion` selects one core
across a wider pattern.) The cross-core suites `//bench:compile` and
`//bench:sim` run one flow over both designs.

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

Every row below exists once per core — write `//bench:dino_compile_verilog` or
`//bench:minion_compile_verilog`; the `<core>_` prefix is elided in the table.

| target | what it checks / measures |
| --- | --- |
| `compile_verilog` | Verilog → `lg:` via slang; LoC/s, words/s |
| `compile_pyrope` | Pyrope → `lg:` (sibling import discovery); LoC/s, words/s |
| `compile_pyrope_parallel` | per-file separate compilation driven by a **real build system**: `lhd scan` reports every file's imports, `bench/gen_build.py` turns that into a Makefile (one rule per file, prerequisites = its direct imports, pruned to `--top`'s cone), and `make -j` derives the schedule. Dependencies ride in pre-lowered as positional `lg:DIR` inputs, falling back to `ln:DIR` only for packages that emit no lgraph — an `ln:` input is re-elaborated from the AST on every load, so for a `comb` unit that costs as much as recompiling it. `--emit-dir lg:` is transitively closed, so `lg_<top>` is already the complete design library (no link step). The generator also emits a syntax-checked `BUILD.bazel` into the test outputs to show gazelle-style generation; it is never executed. Also demonstrates incrementality: touching one leaf rebuilds only its subtree. Recipes deliberately do NOT clean their emission dirs first, so a rebuild re-emits over the previous run's `ln_`/`lg_`: re-emission has to stay idempotent, and this target must FAIL rather than hide a regression behind an `rm -rf` |
| `synth` | each of the core's colorings (`color_algs`) + `pass abc` on the same design (sky130), timing + QoR (regions/gates/area/max_delay) for each. All run hier=true; the difference is the partitions: flat = one color across the hierarchy (one fused region, best cross-module optimization), synth = per-(module,color) regions. dino runs both; minion runs only `synth` (flat does not fit in memory at 534k nodes) |
| `synth_incremental` | `color synth` + abc over 3 passes; incremental reuse needs the distinct colors/partitions that `color synth` creates (and `color flat` intentionally does not): asserts cache hits on the comment-only pass and a single-region re-synth after a one-line edit |
| `synth_lec_flat` / `synth_lec_synth` | netlist integrity: synthesize twice (2nd run after a comment touch — under `color synth` that netlist is largely cache-CLONED), then `lhd lec --impl lg:netlist --ref lg:design --lib lg:models` proves it against the compiled design (`pass liberty gensim` provides the sky130 cell models; strict, so UNKNOWN fails). Only generated for colorings the core actually runs, so minion has no `synth_lec_flat` |
| `sim_verilog` / `sim_pyrope` | asserted `lhd sim` benchmark: dino runs the real `dino_prog_tb` whole-CPU program for 1M cycles (raised from 20k once livehd's sim cgen stopped routing constant bit slices through `Slop::get_mask_op` and dino went ~9k -> ~383k cycles/s, which put 20k back inside this box's noise floor); minion, which has no working program driver yet, runs its VPU tensor-A register file for 200k. The Verilog side compiles straight to an lgraph library (`--emit-dir lg:`) and sims THAT — `lhd sim` takes `lg:DIR` positionally, so the old detour through `--emit-dir pyrope:` measured the Pyrope front end a second time and put an emitter round trip between the Verilog and the thing being simulated. The library is rooted at the module the driver drives (`sim_tb_unit`), not at the core top: `lhd sim` cgen's *every* graph in the library it is handed, so the whole-core library makes it refuse over modules the testbench never instantiates. **The host C++ compile is reported apart from the simulation**: `lhd sim --setup-only` only writes the driver sources, and `--run-only` rebuilds `drv.bin` on every invocation, so `sim_run_ms` is mostly clang. The bench re-runs that binary itself (best of 3, since a loaded box can stall a short measurement) for `sim_exec_ms`, leaving `sim_cc_ms` as the remainder; `//bench:show` prints both and gives cycles/s with and without the compile. **No VCD in the timed path** (`--set sim.vcd=false`): the tracer used to cost 40-75% of `sim_exec_ms` on dino and vary 2.5x run to run on one unchanged binary, so the number was a tracer stopwatch as much as a simulation one — the writer is still covered, by the untimed whole-top drivers below, which run `--set sim.vcd=true`. The bench pins `--set sim.ninja=false` so `sim_cc_ms` always measures lhd's built-in parallel compile: `lhd sim` otherwise prefers a generated `build.ninja` when ninja is on PATH, which is the right default for a developer's warm edit-sim loop but would make this number depend on the machine (and buys the bench nothing — every target starts from a fresh workdir, so nothing is ever incremental). The two modes are no longer the same C++ (one graph comes from slang, the other from the checked-in Pyrope), so a cycles/s gap between them is now a meaningful comparison of the two front ends rather than a codegen regression. Additional whole-top correctness drivers are reported as `METRIC sim_cpu_top_ok` / `sim_cpu_prog_ok`; a core setting `sim_top_assert` (dino) also GATES on them, one that does not (minion, still blocked by a derived clock the sim cgen cannot fold) reports the metric only |
| `sim_verilator` | the same benchmark under **Verilator**, for cores carrying a C++ twin of their `sim_tb` (today: dino, `dino/sim/dino_prog_tb_verilator.cpp`). Same RTL (`-F filelist.f -DSYNTHESIS`), same three-way time split under the same metric names — `sim_setup_ms` is `verilator --cc --exe`, `sim_cc_ms` is `make -j`, `sim_exec_ms` is the built binary re-run — and neither side traces, so the columns are comparable. Two runs: one at `sim_cycles` so the matched-count columns line up with the rows above, and a longer one (`verilator_cycles`) for the throughput number, because at verilator speeds 20k cycles is over in milliseconds and would mostly measure process startup. It is also a **cross-simulator oracle**: the C++ driver mirrors the Pyrope one's stimulus schedule exactly and is held to the same `sim_marker`/`sim_expect` gates, so the two simulators disagreeing about the design fails a target rather than quietly reporting two numbers (they agree on `done at cycle 506` today). Verilator is optional host state: a machine without it SKIPS, it does not fail |

| `lec` | Pyrope impl ≡ Verilog ref (both pre-compiled to `lg:`; the Verilog side needs its slang options — `-F`/`-DSYNTHESIS` plus the core’s `v_flags`), PROVEN |
| `lec_bug` | the core's `tests/bug1` variant must be REFUTED (dino: the ALU's 32-bit add flipped to subtract; minion: the same flip in `txfma_adder`) |
| `lec_incremental` | cold / identical warm (verdict-cache hits) / comment-touch re-runs |
| `verify` | the core's `verif/<unit>.verify.prp` assert/assume all PROVEN (strict) |
| `verify_incremental` | cold / warm (obligation-cache hits) / comment-touch |

Each test prints `METRIC <name> <value> <unit>` lines (also collected as
`metrics.jsonl` under `bazel-testlogs/bench/<target>/test.outputs/`). Targets
are tagged `exclusive` so timings are never polluted by parallel tests.

The test log itself is deliberately terse — the `CMD` and `METRIC` lines, plus
a short excerpt when a step fails. Each step's FULL stdout/stderr is saved
beside `metrics.jsonl` as `step_<label>.log`, so `--test_output=all` on a
failing target gives you the diagnosis and the file to open next. Two knobs:

```bash
bazel test //bench:minion_lec --test_env=BENCH_VERBOSE=1   # dump step logs inline
bazel test //bench:minion_lec --test_env=BENCH_FAIL_TAIL=40 # longer excerpt
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

Note that minion runs only `pass color synth`: `color flat` fuses the whole
hierarchy into one ABC region, which at 534k nodes projects ~801 GiB and is
refused. That is a per-core `color_algs` knob, not a global change.

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
what a driver accepts (`dino_prog_tb.prp` exposes `cycles`, default 2000).
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
./obj_dir/VPipelinedDualIssueCPU --cycles 20000
```

`dino/sim/dino_prog_tb_verilator.cpp` is a line-by-line twin of
`dino/sim/dino_prog_tb.prp` — same ROM, same asserts, same printed line, and
the same stimulus schedule (the three `eval()`s per cycle reproduce Pyrope's
peek / poke / `step` / peek order, which is why both print `done at cycle
506`). Keep them in lockstep: an edit to the program or the poke order belongs
in both, and the bench gates both on the same strings so a divergence fails a
target.

## Known-failing scenarios

The suite's job is to surface LiveHD gaps, so some targets fail by design
rather than being disabled. Against the pinned lhd, this is now minion-only —
`dino_sim_verilog` used to sit here too, but its `io_in` mismatch turned out to
be suite-side and is fixed (`sim_tb_v`, below):

| target | blocked by |
| --- | --- |
| `minion_lec`, `minion_lec_incremental`, `minion_synth_lec_synth` | **UPDATED 2026-07-31: `minion_lec` is 133/140 proven, 31 trusted, 0 REFUTED, 7 UNKNOWN, exit 7** (was 127/13 UNKNOWN). Five LiveHD bugs were fixed to get there and three of them were SILENT MISCOMPILES, which is what this bench exists to surface: (1) `upass/tolg` probed `pin_map_` with the raw, still-backtick-escaped name in `set_mask_base`, so a conditional partial write to any struct leaf substituted a `0sb?` base and dropped the value the variable was carrying; (2) `pass.prp_writer` folded an expression across a reassignment of a name it reads, so a `function automatic` called once per unrolled loop iteration came out reading the LAST iteration N times (`vpu_trans`: `id_trans_busy_o = ((0 | is_used) | is_used) | …`); (3) `upass/constprop` let a CONST-index read of a comb array fold to the array's declared init, deleting the write — which is how every whole-array copy round-trips, since the Pyrope writer expands one into N const-indexed per-entry stores. Plus the Verilog→Pyrope emission was NONDETERMINISTIC (two regenerations differed in 22 files, and `_sN` uniquing RENAMED generate-loop replicas, so a checked-in Pyrope tree could not be paired against a fresh reference compile), and `pass/lec` gained a whole-array memory decomposition plus box congruence (`vpu_mask`: 1200 s UNKNOWN → PROVEN in 84 ms). The remaining 7 UNKNOWN are three leaves and the four ancestors they block: `vpu_lane` (its `prim_rf_3r2w_preview` holds 2 latch cells + 2 negedge flops, so it must stay a trusted UF box — the fixme-1e latch class, not a translation bug), `intpipe_csr_file` (a single-step CEX on `nxt:reg_scause_pre`), and `minion_dcache_top` (size: 18 collapsed children, all proven). `minion_lec_bug` still catches the injected bug, and dino stays green. See fixme issue 1 "STATUS 2026-07-31 (e)" and §§17-21.<br><br>the LEC encoder now MODELS latches and negedge flops (`pass.single_edge` normalizes them to posedge, and folds a clock gate into a flop enable), so minion runs with **zero latch refusals and zero refutations**. Four independent residuals remain: a memory on a *gated* clock is still refused (`core_top`, in ~1 s — the immediate blocker), four latch-free leaf cones the solver cannot discharge (`vpu_mask` et al.), `intpipe_csr_msgs` needing inductive strengthening, and the 32 defs on the `lec_trust` knob (`bench/defs.bzl`) whose latches live ONE MODULE LEVEL DOWN — normalizing inside a def is not supported yet. `formal.lec.trust` assumes those 32 equal (disclosed, never proven), so 113/140 of the rest prove bottom-up. `minion_lec_incremental` has no separate cause — it dies on its first `lec_cold` step. See fixme issue 1.<br><br>**UPDATED 2026-07-27 (c) — ZERO refutations. `minion_lec` is now 119/140 proven, 31 trusted, 0 REFUTED, 21 UNKNOWN, exit 7** (was 116/31/5-refuted/exit 10). The five refuting blocks were TWO LiveHD bugs, each a single line of misclassification, both in the Verilog->Pyrope direction that this bench exists to police. (1) `upass/prp_writer`: the clock/reset-pin cone walk was seeded from the RAW `*_pin` net set instead of the position-independent-filtered cone, so when the pin ref was ITSELF a `wire` — `wire clkgt:u1` + `clock_pin=ref clkgt`, i.e. every emitted ICG module — the walk STARTED on it and dove through, hoisting a clock gate's whole enable cone above the `always_comb` it reads; Verilog `always_comb` is order-independent but Pyrope is sequential, so the enable folded to a tautological constant. A `reg` clock ref (a divided clock) is the same class and needed the same filter. Fixed `minion_dcache_cache_op_unit_l2` and `minion_frontend_thread_buffer{,_p1}`. (2) `upass/ssa`: a >=3-child (tuple_set) store `arr[i] = v` fell through to a VERBATIM copy, so its index/value operands never followed `rename_map` — a reassigned `mut` reached the store on its stale base name, constprop folded that to the declaration value, DCE deleted the real write. Fixed `minion_dcache_tensor_load{,_p1}`. **Note this corrects fixme 1h, which attributed it to a tolg array-store: the RHS is already wrong in the LNAST that reaches tolg.** Exit 10 -> 7 means the run went from finding a real inequivalence back to the pre-existing UNKNOWN class (6 word-level-cycle refusals, 2 derived-clock, 2 budget), which is what still fails the target. Gated by `//lhd/tests:prp_writer_clock_cone_order_test` (verified to fail without the fix) and three array equiv pairs promoted out of `fixme`.<br><br>**UPDATED 2026-07-27 (b) — after making a struct a BUNDLE everywhere inside LiveHD (both front ends agree; `flat_top_io` packs only the top interface for generated-vs-original Verilog equivalence): `prim_mul_div` now PROVES and the tally improves to **116/140 proven** (was 113), but the walk no longer short-circuits on it, so blocks it used to mask are now reached. Failing blocks went 4 -> 5: `prim_mul_div` FIXED; `minion_dcache_cache_op_unit_l2` unchanged (refutes with BOTH port representations — an independent, real issue); `minion_dcache_tensor_load`(+`_p1`) and `minion_frontend_thread_buffer`(+`_p1`) refute ONLY when bundled and PROVE when both sides are flat, witness `debug_o.gated_clk_ticks(ref=2 impl=1)`. **RESOLVED by falsification: the FLAT comparison was VACUOUS on struct-output fields.** Injecting a deliberate `+2`-instead-of-`+1` bug into that counter and re-running: flat says **PROVEN** (blind), bundled says **REFUTED** (catches it). So flat struct ports were producing FALSE PROVEN on those fields, and bundles-everywhere is *finding* pre-existing bugs rather than causing them — the earlier 113/140 was partly vacuous. The remaining difference is a counter on a GATED clock (`clock_pin=ref clock_gated`, minion_frontend_thread_buffer.prp:45), i.e. the gated-clock modelling residual this table already names, now actually observable. Regenerating the checked-in Pyrope does NOT change any of these. Exit stays 10.<br><br>**UPDATED 2026-07-27 (a) — the top no longer ends UNKNOWN/exit 7; it REFUTES with exit 10, and the cause is NOT a memory.** Root-caused by divide-and-conquer down to a 2-second reproducer (`//lhd/tests:lec_trusted_box_struct_port_test`, fixme-tagged): a **TRUSTED def whose struct ports are a flat bus on the reference side and per-leaf on the implementation side cannot be paired**. `lhd/lhd_kernel_compile.cpp` deliberately gives the graphs flow FLAT struct ports ("that flat lgraph is the LEC reference") and the pyrope flow TUPLE ports, which compile to `base.field` leaves. `pass/lec` bridges that for top-level IO (`query.cpp` "Tuple-leaf <-> flat-bus port bundles" ~:1725), but an internal trusted instance is a BOX whose ports pair purely BY NAME (`encode.hpp` `Comb_box`: `in_ports` is a name-sorted concat layout, `out_fn`/`out_w` are keyed by port name). `din` vs `din.fp`/`din.addr`/`din.thread_id` are disjoint names, so `build_in_ports` (`query.cpp:2266`) unions them into one oversized layout, each side drives only its half, and the box outputs become unrelated free symbols — Unknown at small scale, a false REFUTED at `prim_mul_div` scale (`resp_dest` ref=126 impl=127, differing only in bit 0 = `thread_id`). Proven NOT a front-end bug: `intpipe_mul_div_ctl` LECs PROVEN standalone, and lgcheck proves a netlist regenerated through the emitted Pyrope against the original. FIX: apply the same leaf<->bus normalisation to box instance ports |

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

| knob | dino | minion |
| --- | --- | --- |
| `top` — whole-design top, in both languages | `PipelinedDualIssueCPU` | `minion_top` |
| `unit` — module carrying the verify sidecar + `bug1`/`comment1` (must be in the top's cone) | `ALU` | `txfma_adder` |
| `v_flags` — extra slang options for this core's Verilog | *(none)* | `--relax-enum-conversions --allow-use-before-declare` |
| `sim_tb` / `sim_cycles` — asserted, timed sim benchmark | `dino_prog_tb.prp` / 1,000,000 | `tensora_rf_tb.prp` / 200,000 |
| `sim_tb_unit` — the module `sim_tb` drives, i.e. what it spells in `import("lg:NAME")`; the design supplied before it is rooted HERE, not at `top` | `PipelinedDualIssueCPU` | `vpu_tensora_rf` |
| `sim_tb_v` — MODE=verilog override for `sim_tb` (`""` = one driver for both) | *(none)* | *(none)* |
| `sim_top_tb` / `sim_top_tb_unit` / `sim_top_cycles` — separate whole-top correctness run | `dino_tb.prp` / `PipelinedDualIssueCPU` / 1,000 | `vpu_top_tb.prp` / `vpu_top` / 64 |
| `sim_prog_tb` / `sim_prog_tb_unit` / `sim_prog_cycles` — optional additional program correctness run | *(none; already benchmarked)* | *(none)* |
| `verilator_tb` / `verilator_flags` / `verilator_cycles` — the Verilator comparison (`""` = no `sim_verilator` target for this core) | `dino_prog_tb_verilator.cpp` / *(none)* / 2,000,000 | *(none)* |

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

Both cores use the same shape (`<core>/` = `dino/` or `minion/`):

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
