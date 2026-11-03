# rocket

Rocket-chip `TinyConfig` (small config) in Verilog and Pyrope. Used as a whole,
loop-rich RISC-V design bigger than Dino, to iterate on LiveHD loops (sim,
synth, LEC), and as a second data point for the ASPLOS27 frontend-cost
measurement (Chisel cold frontend 13.2 s, `asplos27/experiments/frontend_cost_rocket/`).

## Layout and status (2026-11-03)

| Dir | Contents | Status |
|---|---|---|
| `verilog/` | 217 `.sv` modules (~162k LOC) for the whole SoC, plus `plusarg_reader.v`, `SimDTM.{v,cc}`, `vsrc/` | Complete. `filelist.f` lists only the RocketTile cone (36 modules); `filelist_rtl.f` / `filelist_synth.f` are the firtool lists for the whole SoC |
| `pyrope/` | 37 modules: the RocketTile cone, emitted by `lhd compile verilog --top RocketTile` + `manifest.json` | Regenerated 2026-11-03 with lhd `d088d9039`; PROVEN-full vs the Verilog (25/25 defs, 22 s) |
| `pyrope2/` | 201 hand-cleaned / loop-form modules (older emit, Pyrope 3.1) | Top layer RocketTile+Rocket LEC-PROVEN vs `.sv` (1aeaa9c, 2026-10-22). Loop folds so far: TLDebugModuleInner (PROVEN), TLFIFOFixer family (PROVEN), CSRFile `reg_pmp` arrays (NCE vs `.sv`) |
| `sim/`, `verif/`, `tests/` | empty | No sim driver or verify sidecar yet |

`BUILD` exposes `:verilog`, `:verilog_filelist`, `:pyrope`, `:pyrope_top`
(RocketTile), `:sim`, `:verif`, `:tests`. The bench entry
(`core_benches("rocket")` in `bench/BUILD`, `CORES["rocket"]` in
`bench/defs.bzl`) is synth-only for now.

## Why the RocketTile cone, not the whole SoC

- `ExampleRocketSystem` lowers to lg, but Pyrope emission refuses 5 modules
  with `prp-writer-clock-as-data` (clocks routed through child modules as
  wires). With `prp_writer.debug=true` the emit passes, but the emitted Pyrope
  fails to compile (`fcall-arg-kind`, `TilePRCIDomain.prp:92`). Repro:
  `pyro_scratch/jose_repro_20261102/case4_rocket_clock_as_data/run.sh <lhd>`.
- `TestHarness` needs `SimDTM` (DPI).

## LEC notes

To LEC `pyrope2/` Rocket vs the Verilog: compile the Verilog with
`-DSYNTHESIS` (slang rejects `$error`/`$fatal` in CSRFile/PlusArgTimeout
otherwise), stub `plusarg_reader` (`out = DEFAULT`), and run `lhd lec` with
`--set formal.strict=false` (PlusArgTimeout has no observable output on
either side).

## How the Verilog was produced

```bash
docker exec xs_timing bash -c '
  cd /code/workspace/repo/rocket-chip
  mill "emulator[freechips.rocketchip.system.TestHarness,freechips.rocketchip.system.TinyConfig].mfccompiler.rtls"
'
# then docker cp .../compile.dest/. lhdsuite/rocket/verilog/
```

Source image `mascucsc/hagent-xiangshan:latest` (id `fd3de6983641`),
extracted 2026-08-29.

## Top-level hierarchy

- `TestHarness.sv` (366 LOC): emulator top (needs SimDTM)
- `ExampleRocketSystem.sv` (2600 LOC): SoC
- `RocketTile.sv` (3991 LOC): core + L1 I/D caches + PTW (bench top)
- `Rocket.sv` (7336 LOC): the CPU core

## Next

1. Sim driver + verify sidecar so `rocket` runs the full bench, not only synth.
2. Loop cleanup of the big modules (Rocket, CSRFile, DCache, ICache, TLB, PTW,
   PMPChecker) with an LEC per step.
3. Unblock the whole-SoC Pyrope emission (clock-as-data, case4 above).
