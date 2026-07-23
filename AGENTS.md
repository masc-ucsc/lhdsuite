# Agent notes for lhdsuite

Larger LiveHD tests and benchmarks over real designs, each in Verilog and
Pyrope: **dino** (dual-issue RISC-V CPU) and **minion** (industrial
multi-threaded RISC-V core with a vector/tensor unit). See `README.md` for the
full picture — setup, target table, the `CORES` knobs, and the three-pass
incremental pattern.

## Commands

```bash
bazel test //...                                       # run everything, both cores
bazel test //bench:dino                                # ALL scenarios, one core
bazel test //bench:minion
bazel test //bench:<core>_<scenario> --test_output=all # one scenario
bazel run //bench:show                                 # summary of last results
bazel run //bench:show -- --core minion                # ...one core only
```

- Every target is named `<core>_<scenario>`; `//bench:<core>` is the per-core
  suite (targets also carry a `core_<name>` tag for `--test_tag_filters`).
- LiveHD is built from source as a bazel dependency (pinned in
  `MODULE.bazel`); there is no PATH/prebuilt lookup. To test a local
  checkout: `bazel test //... --override_module=livehd=../livehd`.
- Builds default to `-c opt` (benchmark numbers from a debug lhd are
  unrealistic); use `--config=debug` only when debugging lhd itself.
- Synthesis targets need `HAGENT_TECH_DIR` pointing at a sky130 Liberty
  directory (see README setup); they fail with instructions if unset.

## Layout

Both cores share one shape (`<core>/` = `dino/` or `minion/`):

- `<core>/verilog/`, `<core>/pyrope/` — the design in both languages;
  `verilog/filelist.f` is the slang `-F` source list.
- `<core>/sim/` — simulation drivers; `<core>/verif/` — formal sidecars.
- `<core>/tests/<variant>/` — checked-in patched sources overlaid for
  multi-pass scenarios (`bug1` must be caught, `comment1` must cache-hit).
- `<core>/BUILD` — seven filegroups: `verilog`, `verilog_filelist`, `pyrope`,
  `pyrope_top`, `sim`, `verif`, `tests`.
- `bench/` — one script per flow (`compile.sh`, `synth.sh`, `sim.sh`,
  `lec.sh`, `verify.sh`), shared helpers in `common.sh`, the `CORES` table and
  target generator in `defs.bzl`, targets in `BUILD`.

## Conventions

- **Bench scripts are core-agnostic.** Never hardcode a module or file name in
  `bench/*.sh` — read it from the `CORE_*` env contract documented at the top
  of `common.sh` (`CORE_TOP`, `CORE_V_FLAGS`, `CORE_UNIT`, `CORE_SIM_TB`, …).
  Per-core values live in the `CORES` table in `bench/defs.bzl`; adding a core
  is one entry there plus a `BUILD` with the seven filegroups.
- A core's `unit` (verify sidecar + `bug1`/`comment1` variants) must sit
  inside its `top`'s cone, so the LEC and synthesis scenarios both see the
  `bug1` edit. Per-core slang options go in `v_flags`.
- Every bench prints `METRIC <name> <value> <unit>` lines and logs each lhd
  invocation as a `CMD` line; `//bench:show` aggregates both from
  `bazel-testlogs/`.
- Bench targets are tagged `exclusive` so timings stay clean — keep that for
  new targets.
- If you change a design under `<core>/pyrope/`, check whether that core's
  `<core>/tests/` variants (patched copies of single files) need the same
  change.
- `minion/verilog/*.svh` are `include`d by `intpipe_csr_file.sv`, never
  compiled directly: they are absent from `filelist.f` but globbed into
  `//minion:verilog` so they reach the test sandbox. They resolve relative to
  the including file, so no `-I` is needed.

## Known-failing targets — do not "fix" the suite

Some targets fail because of LiveHD gaps, not suite misconfiguration. See the
"Known-failing scenarios" table in `README.md` for the current list
(`dino_sim_verilog`, `minion_compile_pyrope_parallel`, both `minion_lec*`).
Before changing a testbench, a gate, or a `CORES` entry to make one of these
pass, check that table — fixing them belongs in livehd.

The converse also happens: `minion_synth*` used to fail because the suite
asked for `pass color flat` on a 534k-node design, which no machine can map
flat. That was fixed here, via the per-core `color_algs` knob. So check which
side the fault is on before assuming either.

Sim targets are gated on a *data* value (`CORE_SIM_EXPECT`), not just on the
"hello world" line, because a sim that runs but computes the wrong value would
otherwise pass. Never loosen that gate to make a target green.
