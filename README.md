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
| `sim_verilog` / `sim_pyrope` | hello-world `lhd sim` of one small clocked module (dino: a `StageReg`; minion: the VPU tensor-A register file). The Verilog side first re-emits through slang as Pyrope; cycles/s, VCD. One driver serves both modes unless the core sets `sim_tb_v` — dino does, because the Verilog `StageReg`'s `struct packed` port re-emits as a tuple while the checked-in Pyrope declares it flat. Whole-top drivers also run, reported as `METRIC sim_cpu_top_ok` / `sim_cpu_prog_ok`; a core setting `sim_top_assert` (dino) also GATES on them, one that does not (minion, still blocked by a derived clock the sim cgen cannot fold) reports the metric only |
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

## Known-failing scenarios

The suite's job is to surface LiveHD gaps, so some targets fail by design
rather than being disabled. Against the pinned lhd, this is now minion-only —
`dino_sim_verilog` used to sit here too, but its `io_in` mismatch turned out to
be suite-side and is fixed (`sim_tb_v`, below):

| target | blocked by |
| --- | --- |
| `minion_lec`, `minion_lec_incremental`, `minion_synth_lec_synth` | the LEC encoder now MODELS latches and negedge flops (`pass.single_edge` normalizes them to posedge, and folds a clock gate into a flop enable), so minion runs with **zero latch refusals and zero refutations**. Four independent residuals remain: a memory on a *gated* clock is still refused (`core_top`, in ~1 s — the immediate blocker), four latch-free leaf cones the solver cannot discharge (`vpu_mask` et al.), `intpipe_csr_msgs` needing inductive strengthening, and the 32 defs on the `lec_trust` knob (`bench/defs.bzl`) whose latches live ONE MODULE LEVEL DOWN — normalizing inside a def is not supported yet. `formal.lec.trust` assumes those 32 equal (disclosed, never proven), so 113/140 of the rest prove bottom-up. `minion_lec_incremental` has no separate cause — it dies on its first `lec_cold` step. See fixme issue 1.<br><br>**UPDATED 2026-07-27 — the top no longer ends UNKNOWN/exit 7; it REFUTES with exit 10, and the cause is NOT a memory.** Root-caused by divide-and-conquer down to a 2-second reproducer (`//lhd/tests:lec_trusted_box_struct_port_test`, fixme-tagged): a **TRUSTED def whose struct ports are a flat bus on the reference side and per-leaf on the implementation side cannot be paired**. `lhd/lhd_kernel_compile.cpp` deliberately gives the graphs flow FLAT struct ports ("that flat lgraph is the LEC reference") and the pyrope flow TUPLE ports, which compile to `base.field` leaves. `pass/lec` bridges that for top-level IO (`query.cpp` "Tuple-leaf <-> flat-bus port bundles" ~:1725), but an internal trusted instance is a BOX whose ports pair purely BY NAME (`encode.hpp` `Comb_box`: `in_ports` is a name-sorted concat layout, `out_fn`/`out_w` are keyed by port name). `din` vs `din.fp`/`din.addr`/`din.thread_id` are disjoint names, so `build_in_ports` (`query.cpp:2266`) unions them into one oversized layout, each side drives only its half, and the box outputs become unrelated free symbols — Unknown at small scale, a false REFUTED at `prim_mul_div` scale (`resp_dest` ref=126 impl=127, differing only in bit 0 = `thread_id`). Proven NOT a front-end bug: `intpipe_mul_div_ctl` LECs PROVEN standalone, and lgcheck proves a netlist regenerated through the emitted Pyrope against the original. FIX: apply the same leaf<->bus normalisation to box instance ports |

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
| `sim_tb` — asserted sim testbench | `stagereg_tb.prp` | `tensora_rf_tb.prp` |
| `sim_tb_v` — MODE=verilog override for `sim_tb` (`""` = one driver for both) | `stagereg_v_tb.prp` | *(none)* |

**Why a core may need two sim drivers.** The two trees are the same design but
not the same Pyrope. A `struct packed` port re-emits from Verilog as a tuple
port (`io_in:(instruction:u32, pc:u64, isValid:u1)`) while the checked-in
Pyrope tree may declare it flat (`io_in:u97`), and a driver written for one
shape names no field of the other — dino's `StageReg` is exactly that case, so
`sim_tb_v` points MODE=verilog at a twin that drives the tuple leaves and
prints the same packed value (one `sim_expect` gates both). minion's sim unit
has no struct port, so it leaves the knob empty. Fixing this by flattening the
emission (`compile.slang.struct_port_bundles=false`) is deliberately NOT done:
bench scripts do not carry lhd flags that exist only to make a bench pass, and
graph flows keep ports flat anyway, so `sim_verilog` is the suite's only
coverage of tuple ports.

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
