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
  `sim_verilator.sh`, `lec.sh`, `verify.sh`), shared helpers in `common.sh`,
  the `CORES` table and target generator in `defs.bzl`, targets in `BUILD`.
  `gen_build.py` turns an `lhd scan` result into the Makefile (and an
  illustrative `BUILD.bazel`) that drives `compile_pyrope_parallel`.
  A new script must be `chmod +x` — bazel refuses to stage a non-executable
  `sh_test` src ("file ... is not executable").

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
  `bazel-testlogs/`. A non-lhd command that is part of the flow gets the same
  line via `log_cmd` (only `sim.sh`'s re-run of the driver binary today).
- **A timed step must time ONE thing.** Twice now: (1) `lhd sim --run-only`
  host-compiles the generated driver before simulating, and on these designs
  that clang++ is 5-10s against a simulation of ~1s — so `sim_run_ms` read as
  "simulation" was really a clang stopwatch, and the two sim MODEs differed
  2.5x while emitting byte-identical C++; `sim.sh` re-runs the built `drv.bin`
  to separate `sim_cc_ms` from `sim_exec_ms`. (2) The timed leg used to bake a
  VCD in, and the writer cost 40-75% of `sim_exec_ms` on dino with a 0.36s /
  0.91s spread on ONE unchanged binary — so `sim.sh` now runs
  `--set sim.vcd=false` and the untimed whole-top drivers carry the VCD
  coverage. Before believing a bench gap between two modes, check whether the
  thing that differs is even in the measured interval.
- **`lhd sim` cgen's EVERY graph in the library it is given.** So an `lg:` sim
  input must be rooted at the module the testbench drives, not at the core top:
  handing it the whole minion_top library makes it refuse over `vpu_ctrl` and
  `intpipe_csr_file`, neither of them in the tensor RF's cone. That is what
  `sim_tb_unit` / `sim_top_tb_unit` in `defs.bzl` pin down, and why every sim
  driver names its DUT as `import("lg:NAME")` with the design supplied as the
  positional before it (one driver then serves a `.prp` tree and an `lg:`
  library unchanged).
- **Verilator is a comparison, not a scenario the suite owns.** `sim_verilator`
  SKIPS (exit 0, `METRIC verilator_present 0`) when verilator is absent — do
  not turn it into a hard failure the way `require_tech_dir` is. Its C++ driver
  is a twin of the core's Pyrope one and is held to the same
  `sim_marker`/`sim_expect` gates, which makes it a cross-simulator oracle:
  when the two disagree, one of them has a codegen bug. Keep the pair in
  lockstep — the stimulus schedule especially (three `eval()`s per cycle
  reproduce peek / poke / `step` / peek; "simplifying" it to the usual two-eval
  clock toggle shifts `done at cycle N` by one and silently decouples the two
  benchmarks).
- Bench targets are tagged `exclusive` so timings stay clean — keep that for
  new targets.
- If you change a design under `<core>/pyrope/`, check whether that core's
  `<core>/tests/` variants (patched copies of single files) need the same
  change.
- `minion/verilog/*.svh` are `include`d by `intpipe_csr_file.sv`, never
  compiled directly: they are absent from `filelist.f` but globbed into
  `//minion:verilog` so they reach the test sandbox. They resolve relative to
  the including file, so no `-I` is needed.
- **`filelist.f` lists only what `--top`'s cone reaches.** It is the slang `-F`
  list, so an entry that nothing instantiates is compiled and then discarded —
  pure front-end cost with no effect on any emitted graph. Before adding one,
  check it is reachable; before removing one, confirm the emitted library keeps
  the SAME graph set (compare `--emit-dir lg:` file lists — content bytes differ
  run to run, so diff the names, not the bodies).
- **The checked-in `<core>/pyrope/` tree is regenerated MANUALLY, never by a
  bench target.** No target rewrites it: `bench/sim.sh` emits Pyrope only into a
  per-run scratch `tree/`. Regenerating is a deliberate, reviewed act — the
  emitter's line order and slang's nondeterministic `_sN` replica naming make
  the diff churn even when nothing changed semantically. Recipe:

  ```bash
  lhd compile verilog --top <CORE_TOP> --emit-dir pyrope:<core>/pyrope --workdir w \
      -- -F <core>/verilog/filelist.f -DSYNTHESIS <v_flags>
  ```

  Then LEC the result against the Verilog side before committing. `manifest.json`
  is NOT required in `minion/pyrope/` — `//minion:BUILD` globs it with
  `allow_empty`, so its absence is intended, not a pending chore.

## Known-failing targets — do not "fix" the suite

Some targets fail because of LiveHD gaps, not suite misconfiguration. See the
"Known-failing scenarios" table in `README.md` for the current list (both
`minion_lec*`).
Before changing a testbench, a gate, or a `CORES` entry to make one of these
pass, check that table — fixing them belongs in livehd.

The converse also happens: `minion_synth*` used to fail because the suite
asked for `pass color flat` on a 534k-node design, which no machine can map
flat. That was fixed here, via the per-core `color_algs` knob. `dino_sim_verilog`
was the same shape: a testbench that named a port the re-emitted tree does not
have, fixed with the per-core `sim_tb_v` knob. So check which side the fault is
on before assuming either.

Sim targets are gated on a *data* value (`CORE_SIM_EXPECT`), not just on the
"hello world" line, because a sim that runs but computes the wrong value would
otherwise pass. Never loosen that gate to make a target green.

Never add an `lhd` option to a bench script to make that bench pass. Flattening
the Verilog re-emission (`--set compile.slang.struct_port_bundles=false`) would
have made `dino_sim_verilog` green without touching anything, and that is
exactly the wrong fix: if a testbench names a signal the design does not have,
fix the testbench; if the signal connection itself is wrong, fix livehd.
