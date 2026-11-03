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
| `pyrope2/` | Loop-cleaned Pyrope. The 37 RocketTile-cone modules were rebased onto the current emit (d080e5f, 2026-11-03); the other 164 files are the old whole-SoC emit (lowercase `u` types) and do NOT compile with current lhd | RocketTile from `pyrope2/` PROVEN-full vs the Verilog cone (~30 s) after every step. Done: CSRFile pyroA-E (2146 -> 1311 lines, -39%): `csr_exists` address OR -> hpm/pmp loops, dead CSR-decode bit temps, PMP regs -> `reg_pmp_<f>:[8]` arrays, `pmpMask` loop, PMP CSR write side -> loops |
| `sim/`, `verif/`, `tests/` | empty | No sim driver or verify sidecar yet |

`BUILD` exposes `:verilog`, `:verilog_filelist`, `:pyrope`, `:pyrope_top`
(RocketTile), `:sim`, `:verif`, `:tests`. The bench entry
(`core_benches("rocket")` in `bench/BUILD`, `CORES["rocket"]` in
`bench/defs.bzl`) is synth-only for now.

## Bench results (2026-11-03, lhd d088d9039, mada4)

| Target | Result |
|---|---|
| `rocket_compile_verilog` | PASSED: 41,723 LoC in 2.6 s |
| `rocket_compile_pyrope` | PASSED: 9,885 LoC in 2.0 s |
| `rocket_lec_incremental` | PASSED: full/cold/warm/touch ~73 s each (`formal.effort=test`; the PROVEN-full proof is the 22 s run above) |
| `rocket_synth` | PASSED in 622 s: 1.33M gates, 12.2 mm², 46.0 ns, 17 GB peak RSS |
| `rocket_synth_incremental` | PASSED: cold 629 s; comment touch 61 s (11/11 region hits); one-line ALU edit 190 s (10/11 hits) |

- Coloring is lopsided: 2 of the 11 regions hold 2.95M GE (99.7%), and one
  takes 434 s, so an edit inside them saves almost nothing. A smaller
  `color_max_ge` (as on `xs_backend`) is a possible follow-up.
- livehd d088d9039 does not build with gcc 16 (`rapidjson/stringbuffer.h`,
  `-Werror=stringop-overflow`). On mada4 run the bench with
  `--copt=-Wno-error=stringop-overflow --host_copt=-Wno-error=stringop-overflow`.

## Why the RocketTile cone, not the whole SoC

- `ExampleRocketSystem` lowers to lg, but Pyrope emission refuses 5 modules
  with `prp-writer-clock-as-data` (clocks routed through child modules as
  wires). With `prp_writer.debug=true` the emit passes, but the emitted Pyrope
  fails to compile (`fcall-arg-kind`, `TilePRCIDomain.prp:92`). Repro:
  `pyro_scratch/jose_repro_20261102/case4_rocket_clock_as_data/run.sh <lhd>`.
- `TestHarness` needs `SimDTM` (DPI).

## LEC notes

`pyrope2/` RocketTile vs the Verilog cone needs no stubs or extra flags:

```bash
(cd rocket/pyrope2 && lhd compile RocketTile.prp --top RocketTile --set compile.upass.inline=false --emit-dir lg:/tmp/impl)
(cd rocket/verilog && lhd compile verilog --top RocketTile --emit-dir lg:/tmp/ref -- -F filelist.f -DSYNTHESIS)
lhd lec --impl lg:/tmp/impl --ref lg:/tmp/ref --top RocketTile --set formal.effort=proof
```

Each cleanup step is also LEC'd module-level against the previous step and
against the module's `.sv` before it is committed (one commit per step).

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
2. Loop cleanup of the big modules, ranked by `lhd pyrope style`: CSRFile
   (in progress), then RocketTile, DCache, PTW, ShiftQueue, PMPChecker, Rocket,
   with an LEC per step.
3. Unblock the whole-SoC Pyrope emission (clock-as-data, case4 above).
