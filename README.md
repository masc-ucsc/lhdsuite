# lhdsuite

Larger LiveHD tests and benchmarks over real designs — currently the Dino
dual-issue RISC-V CPU in both Verilog (`dino/verilog/`) and Pyrope
(`dino/pyrope/`). The suite has two jobs:

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

One bazel target per scenario, so a single thing can be benchmarked or
debugged in isolation:

```bash
bazel test //...                                    # everything
bazel run //bench:show                              # summary of the last results
bazel test //bench:synth_incremental --test_output=all
bazel test //bench:lec_bug --test_output=all
```

`//bench:show` aggregates the `METRIC` lines from `bazel-testlogs/` — the
last run of each target (bazel cannot make a `run` target execute tests, so
test first, then show; anything never run is listed at the bottom). It also
lists the exact `lhd` command lines each bench executed (every invocation is
logged as a `CMD` line, with paths sanitized to repo-relative form — living
documentation of the flow); pass `--no-cmds` for the compact view:
`bazel run //bench:show -- --no-cmds`.

`.bazelrc` defaults every build to `-c opt` — benchmark numbers from a debug
lhd are unrealistic. Use `-c dbg`/`--config=debug` only when debugging lhd
itself.

| target | what it checks / measures |
| --- | --- |
| `//bench:compile_verilog` | Verilog → `lg:` via slang; LoC/s, words/s |
| `//bench:compile_pyrope` | Pyrope → `lg:` (sibling import discovery); LoC/s, words/s |
| `//bench:compile_pyrope_parallel` | per-file separate compilation: `lhd scan` builds the dependency picture, import-free files compile in parallel (own `ln:`+`lg:` emissions), dependents reuse them via `--in-dir ln:`; the final `lg:` is a complete design library. No big win on a small design — it demonstrates the flow |
| `//bench:synth` | `color flat` AND `color synth` + `pass abc` on the same design (sky130), timing + QoR (regions/gates/area/max_delay) for each. Both run hier=true; the difference is the partitions: flat = one color across the hierarchy (one fused region, best cross-module optimization), synth = per-(module,color) regions |
| `//bench:synth_incremental` | `color synth` + abc over 3 passes; incremental reuse needs the distinct colors/partitions that `color synth` creates (and `color flat` intentionally does not): asserts cache hits on the comment-only pass and a single-region re-synth after a one-line edit |
| `//bench:synth_lec_flat` / `synth_lec_synth` | netlist integrity: synthesize twice (2nd run after a comment touch — under `color synth` that netlist is largely cache-CLONED), then `lhd lec --impl lg:netlist --ref lg:design --lib lg:models` proves it against the compiled design (`pass liberty gensim` provides the sky130 cell models; strict, so UNKNOWN fails) |
| `//bench:sim_verilog` / `sim_pyrope` | hello-world `lhd sim` of a dino StageReg (Verilog side first re-emits through slang as Pyrope); cycles/s, VCD |
| `//bench:lec` | Pyrope impl ≡ Verilog ref (both pre-compiled to `lg:`; the Verilog side needs its slang options `-F`/`-DSYNTHESIS`), PROVEN |
| `//bench:lec_bug` | `dino/tests/bug1` ALU variant must be REFUTED |
| `//bench:lec_incremental` | cold / identical warm (verdict-cache hits) / comment-touch re-runs |
| `//bench:verify` | `dino/verif/ALU.verify.prp` assert/assume all PROVEN (strict) |
| `//bench:verify_incremental` | cold / warm (obligation-cache hits) / comment-touch |

Each test prints `METRIC <name> <value> <unit>` lines (also collected as
`metrics.jsonl` in the test's `outputs.zip` under `bazel-testlogs/`). Targets
are tagged `exclusive` so timings are never polluted by parallel tests.

## The three-pass pattern

Incremental scenarios run passes sharing one `--workdir` (LiveHD's caches —
`abc_cache/`, `formal_cache.json` — live under it):

- **pass 1** — cold: everything is really computed;
- **pass 2** — `dino/tests/comment1` variant (a comment-only touch: nothing
  really changed): incremental caches must hit;
- **pass 3** — a small real edit: either `dino/tests/bug1` (must be caught by
  LEC/formal) or a real-but-correct change (must re-run only what changed).

Variants are checked-in patched copies, applied by overlaying the file onto a
copy of `dino/pyrope/` — so `diff dino/pyrope/ALU.prp dino/tests/bug1/ALU.prp`
shows exactly what a scenario injects (one flipped operator).

## Benchmarking a LiveHD checkout (or your own changes)

The default `MODULE.bazel` pins a top-of-tree LiveHD commit — and that is the
ONLY pin here: livehd is self-contained as a dependency (its iassert/hlop/hhds
siblings ride git pins inside livehd's own `MODULE.bazel`, and
`@livehd//lhd:lhd` stages the `lhd sim` runtime headers in its runfiles). To
run the suite against a local checkout instead, either:

```bash
bazel test //... --override_module=livehd=../livehd
```

or swap the `git_override` in `MODULE.bazel` for the commented
`local_path_override`. Bumping the LiveHD pin is a one-line commit edit.

## Layout

- `dino/verilog/`, `dino/pyrope/` — the design, both languages (top
  `PipelinedDualIssueCPU`; the Pyrope is the LiveHD translation of the same
  RTL).
- `dino/sim/` — simulation drivers (Pyrope `test` blocks).
- `dino/verif/` — formal assert/assume sidecars.
- `dino/tests/<variant>/` — checked-in patched sources for the multi-pass
  scenarios (`bug1`, `comment1`).
- `bench/` — one script family per flow (`compile.sh`, `synth.sh`, `sim.sh`,
  `lec.sh`, `verify.sh`), `MODE`-selected scenarios, shared helpers in
  `common.sh`, targets in `BUILD`.
