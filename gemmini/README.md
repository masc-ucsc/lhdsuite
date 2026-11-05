# gemmini

ucb-bar Gemmini (Chisel DNN accelerator generator) as a standalone TPU-like
core: a 4x4 systolic mesh of PEs (8-bit inputs, 32-bit accumulators,
`Mesh` -> `Tile` -> `PE_16`/`MacUnit`), `MeshWithDelays` (input skew,
transposer, tag queue) and `AccumulatorMem` (64x128 two-port SRAM), without the
RoCC/rocket-chip front end. The non-RISC-V, loop-rich design of the suite.

## Layout and status (2026-11-05)

| Dir | Contents | Status |
|---|---|---|
| `verilog/` | `GemminiTPU.sv` (15 modules, 4,425 lines) | Chisel 6.2.0 emit of the standalone extraction in `/mada/users/frabieik/gemmini_tpu` (`sbt "runMain gemmini.Top"`); rocket-chip/hardfloat/Diplomacy replaced by local stubs |
| `pyrope/` | 15 modules, `lhd compile verilog --top GemminiTPU` + `manifest.json` (lhd d088d9039, 3,865 lines) | PROVEN-full vs the Verilog in 1.5 s with `mem_64x128` trusted (see LEC) |
| `pyrope2/` | Loop-cleaned Pyrope; starts as a copy of `pyrope/` | Folds to come: the 4x4 `Tile` instance grid in `Mesh`, `Queue1_AccumulatorReadResp`, the transposer |
| `sim/`, `verif/`, `tests/` | empty | No sim driver yet |

## Bench results (2026-11-05, lhd d088d9039, kaffirlime)

| Target | Result |
|---|---|
| `gemmini_compile_verilog` / `_pyrope` / `_pyrope2` | PASSED: 0.56 s / 0.61 s / 0.61 s |
| `gemmini_compile_incremental` | PASSED: cold 576 ms, comment touch 74 ms, one-line edit 481 ms |
| `gemmini_lec_incremental` | PASSED: ~1.1 s full/cold/warm |
| `gemmini_synth` | PASSED in 133 s: 358,088 gates, 2.89 mm2, 34.0 ns |
| `gemmini_synth_incremental` | PASSED in 394 s (edit: one `MacUnit` output inverted) |

## LEC notes

The emitted 64x128 accumulator SRAM (`mem_64x128`) does not discharge in
30 min, and it takes `TwoPortSyncMem` and the top with it; everything else
(mesh, PEs, MACs, transposer, queues) proves. The bench trusts that one def
(`lec_trust`), which the verdict discloses ("PROVEN under 1 trusted def").

```bash
(cd gemmini/pyrope2 && lhd compile GemminiTPU.prp --top GemminiTPU --set compile.upass.inline=false --emit-dir lg:/tmp/impl)
(cd gemmini/verilog && lhd compile verilog --top GemminiTPU --emit-dir lg:/tmp/ref -- -F filelist.f -DSYNTHESIS)
lhd lec --impl lg:/tmp/impl --ref lg:/tmp/ref --top GemminiTPU --set formal.effort=proof --set formal.lec.trust=mem_64x128
```

## Sizes

The mesh size is a Chisel parameter in `gemmini_tpu` (4x4 here); 8x8 or 16x16
are a regeneration away.
