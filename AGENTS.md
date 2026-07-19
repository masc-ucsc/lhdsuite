# Agent notes for lhdsuite

Larger LiveHD tests and benchmarks over real designs (the Dino dual-issue
RISC-V CPU, in Verilog and Pyrope). See `README.md` for the full picture —
setup, target table, and the three-pass incremental pattern.

## Commands

```bash
bazel test //...                                 # run everything
bazel test //bench:<target> --test_output=all    # one scenario
bazel run //bench:show                           # summary of last results
```

- LiveHD is built from source as a bazel dependency (pinned in
  `MODULE.bazel`); there is no PATH/prebuilt lookup. To test a local
  checkout: `bazel test //... --override_module=livehd=../livehd`.
- Builds default to `-c opt` (benchmark numbers from a debug lhd are
  unrealistic); use `--config=debug` only when debugging lhd itself.
- Synthesis targets need `HAGENT_TECH_DIR` pointing at a sky130 Liberty
  directory (see README setup); they fail with instructions if unset.

## Layout

- `dino/verilog/`, `dino/pyrope/` — the design in both languages (top module
  `PipelinedDualIssueCPU`).
- `dino/sim/` — simulation drivers; `dino/verif/` — formal sidecars.
- `dino/tests/<variant>/` — checked-in patched sources overlaid for
  multi-pass scenarios (`bug1` must be caught, `comment1` must cache-hit).
- `bench/` — one script per flow (`compile.sh`, `synth.sh`, `sim.sh`,
  `lec.sh`, `verify.sh`), shared helpers in `common.sh`, targets in `BUILD`.

## Conventions

- Every bench prints `METRIC <name> <value> <unit>` lines and logs each lhd
  invocation as a `CMD` line; `//bench:show` aggregates both from
  `bazel-testlogs/`.
- Bench targets are tagged `exclusive` so timings stay clean — keep that for
  new targets.
- If you change the design under `dino/pyrope/`, check whether the
  `dino/tests/` variants (patched copies of single files) need the same
  change.
