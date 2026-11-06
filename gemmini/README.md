# gemmini

ucb-bar Gemmini (Chisel DNN accelerator generator) as a standalone TPU-like
core: a 4x4 systolic mesh of PEs (8-bit inputs, 32-bit accumulators,
`Mesh` -> `Tile` -> `PE_16`/`MacUnit`), `MeshWithDelays` (input skew,
transposer, tag queue) and `AccumulatorMem` (64x128 two-port SRAM), without the
RoCC/rocket-chip front end. The non-RISC-V, loop-rich design of the suite.

## Layout and status (2026-11-06, lhd c53e1728c)

| Dir | Contents | Status |
|---|---|---|
| `verilog/` | `GemminiTPU.sv` (15 modules, 4,425 lines) + `GemminiSimTop.sv` (flat-port sim wrapper) | Chisel 6.2.0 emit of the standalone extraction in `/mada/users/frabieik/gemmini_tpu` (`sbt "runMain gemmini.Top"`); rocket-chip/hardfloat/Diplomacy replaced by local stubs |
| `pyrope/` | 15 modules, `lhd compile verilog --top GemminiTPU` + `manifest.json` (3,865 lines) | PROVEN-full vs the Verilog with `mem_64x128` trusted (see LEC) |
| `pyrope2/` | 11 modules cleaned, 1,175 lines (-70%) | GemminiTPU top PROVEN-full vs the Verilog in 8 s; each module PROVEN-full vs the previous step and vs the Verilog |
| `sim/` | `gemmini_tb.prp`, `GemminiSimTop.prp`, `gemmini_tb_verilator.cpp` | same checksum from lhd sim (pyrope, pyrope2, Verilog) and Verilator |
| `Mesh8/` | the same core regenerated with an 8x8 mesh | see `Mesh8/README.md` |

| Module | raw | pyrope2 | How |
|---|---|---|---|
| Queue1_AccumulatorReadResp | 1,692 | 31 | one-entry flow queue rewritten from its semantics |
| Mesh | 843 | 394 | 16 Tiles in one row/col loop; the rest is the scalar registers LEC pairs with the Verilog flops |
| MeshWithDelays | 371 | 305 | hand rewrite, no loop (skew-chain registers keep their emitted names) |
| AccumulatorMem | 146 | 79 | named the pipelined-write fields and hazards |
| PE_16 | 134 | 44 | one rounding shift inlined (a `comb` helper here cost 18% sim) |
| TagQueue | 118 | 38 | entry loop |
| AlwaysOutTransposer | 110 | 38 | PE instances declared bottom-right first, so no forward wires; no loop (loop and reg-array forms only reach PROVEN-bounded) |
| Queue6_TagWithIdAndTotalRows | 84 | 39 | named pointers and full/empty |
| TwoPortSyncMem | 56 | 16 | byte-mask lanes in one loop |
| GemminiTPU | 142 | 46 | direct port wiring instead of packing and unpacking through wide vectors |
| Tile | 40 | 16 | direct wiring |

Left raw: the memories (`mem_64x128`, `ram_6x7`), PE and MacUnit (already
small).

Simulation: the bench runs 25k cycles (`sum=6362616511205422611`); the
standalone check is 200k cycles (`sum=8485392126227624009`). The `Mesh` loop
makes lhd sim of `pyrope2/` about 9x slower than `pyrope/` (case20, a loop
codegen issue reported to Jose; it grows to ~100x at 8x8).

## Bench results (2026-11-06, lhd c53e1728c, kaffirlime)

All 14 `gemmini_*` targets pass.

| Target | Result |
|---|---|
| `gemmini_sim_pyrope` / `_pyrope2` / `_verilog` / `_verilator` | 263k / 28.7k / 236k / 71.0k cycles/s |
| `gemmini_synth` | 358,088 gates, 2.89 mm2, 34.0 ns |
| `gemmini_synth_incremental` | PASSED in 360 s (edit: one `MacUnit` output inverted) |
| compile, compile_incremental, lec_incremental, sim_incremental | PASSED |

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

The mesh size is a Chisel parameter in `gemmini_tpu`: `Top.scala` reads
`GEMMINI_MESH` (default 4). The 8x8 lives in `Mesh8/`; 16x16 is a
regeneration away, and the `gen_*.py` scripts in
`/mada/users/frabieik/pyro_scratch/gemmini8/gen/` produce its Mesh,
MeshWithDelays and transposer cleanups from the raw emit.
