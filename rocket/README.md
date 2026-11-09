# rocket

Rocket-chip `TinyConfig` (small config) in Verilog and Pyrope. Used as a whole,
loop-rich RISC-V design bigger than Dino, to iterate on LiveHD loops (sim,
synth, LEC), and as a second data point for the ASPLOS27 frontend-cost
measurement (Chisel cold frontend 13.2 s, `asplos27/experiments/frontend_cost_rocket/`).

## Layout and status (2026-11-09)

| Dir | Contents | Status |
|---|---|---|
| `verilog/` | 217 `.sv` modules (~162k LOC) for the whole SoC, plus `plusarg_reader.v`, `SimDTM.{v,cc}`, `vsrc/` | Complete. `filelist.f` lists only the RocketTile cone (36 modules); `filelist_rtl.f` / `filelist_synth.f` are the firtool lists for the whole SoC |
| `pyrope/` | 37 modules: the RocketTile cone, emitted by `lhd compile verilog --top RocketTile` + `manifest.json` | Regenerated 2026-11-03 with lhd `d088d9039`; PROVEN-full vs the Verilog (25/25 defs, 22 s) |
| `pyrope2/` | Loop-cleaned Pyrope. The 37 RocketTile-cone modules were rebased onto the current emit (d080e5f, 2026-11-03); the other 164 files are the old whole-SoC emit (lowercase `u` types) and do NOT compile with current lhd | Cone 9,885 -> 7,700 lines (-22%). RocketTile from `pyrope2/` PROVEN-full vs the Verilog cone after every step; each step also LEC'd per module vs the previous step and vs its `.sv` |
| `sim/` | `rocket_tb.prp` (free-running driver: one-deep TileLink responder answering with LFSR data, checksum of the outputs) + `rocket_tb_verilator.cpp` (Verilator twin) | Same checksum from lhd sim and Verilator (500k cycles, `sum=4760450083537923318`) |
| `verif/`, `tests/` | empty | No verify sidecar yet |

`BUILD` exposes `:verilog`, `:verilog_filelist`, `:pyrope`, `:pyrope_top`
(RocketTile), `:pyrope2`, `:sim`, `:verif`, `:tests`. The bench entry
(`core_benches("rocket")` in `bench/BUILD`, `CORES["rocket"]` in
`bench/defs.bzl`) runs compile, synth, LEC and sim, including
`rocket_compile_pyrope2` and `rocket_sim_pyrope2`.

## Cleanups in `pyrope2/` (lines, raw emit -> cleaned)

| Module | raw | pyrope2 | What |
|---|---|---|---|
| CSRFile | 2,146 | 972 | `csr_exists` compare OR -> hpm/pmp loops; dead decode temps; PMP registers -> `reg_pmp_<f>:[8]` arrays; PMP mask, CSR write and read sides -> loops; temps inlined |
| RocketTile | 1,554 | 1,294 | 126 alias wires collapsed |
| Rocket | 1,486 | 1,152 | zero pre-declarations sunk, empty ifs and single-use temps inlined; register `_r` renamed `r_` (see Simulation) |
| DCache | 1,629 | 1,446 | TileLink byte mask and the 4 atomics select chains |
| PTW | 810 | 772 | 8 per-entry PMP blocks -> loop |
| ShiftQueue | 302 | 270 | per-entry write-data muxes -> loop |
| Frontend | 134 | 120 | empty ifs, temps, dead wires |
| PMPChecker | 142 | 34 | 8-entry priority search -> loop |
| TLB_1 | 99 | 57 | 36 dead definitions; 6 identity OptimizationBarrier instances folded |

Not done: the RocketTile PMP-array fold (its hierarchical LEC times out,
jose_repro case18); RVCExpander's table fold was dropped because it doubled the
line count.

## Bench results (2026-11-03, lhd d088d9039, mada4; sim targets 2026-11-05 on kaffirlime)

| Target | Result |
|---|---|
| `rocket_compile_verilog` | PASSED: 41,723 LoC in 2.6 s |
| `rocket_compile_pyrope` | PASSED: 9,885 LoC in 2.0 s |
| `rocket_lec_incremental` | PASSED: full/cold/warm/touch ~73 s each (`formal.effort=test`; the PROVEN-full proof is the 22 s run above) |
| `rocket_synth` | PASSED in 622 s: 1.33M gates, 12.2 mm², 46.0 ns, 17 GB peak RSS |
| `rocket_synth_incremental` | PASSED: cold 629 s; comment touch 61 s (11/11 region hits); one-line ALU edit 190 s (10/11 hits) |
| `rocket_compile_pyrope2` | PASSED: 7,700 LoC in 2.0 s |
| `rocket_sim_pyrope2` / `rocket_sim_verilator` | PASSED: 152k / 263k cycles/s (lhd c53e1728c) |
| `rocket_sim_pyrope` / `rocket_sim_verilog` / `rocket_sim_incremental` | KNOWN FAIL: register `_r` (case11, see Simulation) |

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

## Simulation

- The raw emit and the Verilog carry a register named `_r`
  (RocketCore.scala:1117). It collides with the `_r` parameter of the
  generated `dump_state()`/`load_state()`, so their sim driver does not compile
  (jose_repro case11). `pyrope2/` renames it `r_`, so only
  `rocket_sim_pyrope2` runs in the bench.
- Measured standalone at 500k cycles (best of 3, kaffirlime, same checksum):

  | lhd | raw tree (`_r` renamed) | `pyrope2/` |
  |---|---|---|
  | c53e1728c | 377k cycles/s | 223k cycles/s (41% slower) |
  | 7ab162cd7 (2026-11-08) | 377k cycles/s | does not build (case22) |

- The 41% comes mostly from CSRFile's PMP registers as `reg [8]` arrays: lhd
  sim modelled each as a memory with pending writes and bounds checks
  (case19).
- On 7ab162cd7 the cleaned tree's C++ fails to compile in `stage_write` for
  CSRFile's `mut pmpCfgWen:[8]U1` (case22, sent to Jose 2026-11-08). Re-measure
  once it is fixed.

## Next

1. Re-measure `pyrope2/` sim once case22 is fixed, and check whether case19
   (array registers slower than scalars) is gone too.
2. More loop cleanup by `lhd pyrope style` rank
   (`pyro_scratch/rocket_style/RANKING.md`): DCache (207 of 1,629 lines in
   loop-like blocks) and PTW (95 of 810) are only lightly touched; 27 of the 37
   modules have no loop findings.
3. A verify sidecar.
4. Unblock the whole-SoC Pyrope emission (clock-as-data, case4 above).
