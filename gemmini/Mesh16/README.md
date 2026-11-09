# gemmini/Mesh16

The same standalone Gemmini TPU core as `gemmini/` and `gemmini/Mesh8/`,
regenerated with a 16x16 systolic mesh (256 PEs, 512-bit accumulator rows,
64x512 SRAM). It is the third size point: the raw emit grows with the mesh,
and the cleaned tree is produced from the raw emit by generators, not by hand.

In the bench as core `gemmini16` (`bench/defs.bzl`, marked `slow`). 12 of its 14
targets pass on kaffirlime. `gemmini16_synth` and `gemmini16_synth_incremental`
fail in LiveHD: the bit-blasted 64x512 accumulator memory takes 1,779 s in ABC
against the 900 s per-region limit (see the known-failing table in the top
README).

## Layout and status (2026-11-06, lhd c53e1728c)

| Dir | Contents | Status |
|---|---|---|
| `verilog/` | `GemminiTPU.sv` (15 modules) + `GemminiSimTop.sv` (flat-port sim wrapper) | Chisel 6.2.0 emit of `/mada/users/frabieik/gemmini_tpu` with `GEMMINI_MESH=16` |
| `pyrope/` | raw emit, `lhd compile verilog --top GemminiTPU`, 22,819 lines | PROVEN-full vs the Verilog in 5 s (`mem_64x512` trusted) |
| `pyrope2/` | 11 modules cleaned, 8,290 lines (-64%) | GemminiTPU top PROVEN-full vs the Verilog in 580 s; each module PROVEN-full vs raw and vs the Verilog |
| `sim/` | `gemmini_tb.prp`, `GemminiSimTop.prp`, `gemmini_tb_verilator.cpp` | same checksum from lhd sim (pyrope, pyrope2, Verilog) and Verilator; the wrapper `.prp` is PROVEN-full vs its `.sv` |

| Module | raw | pyrope2 | How |
|---|---|---|---|
| Mesh | 13,323 | 4,713 | `gen_mesh_packed.py`: 256 Tiles in one row/col loop; the rest is the 2,048 scalar registers LEC pairs with the Verilog flops |
| Queue1_AccumulatorReadResp | 3,744 | 31 | `gen_small.py` |
| MeshWithDelays | 3,341 | 2,705 | `gen_mwd_packed.py`; the skew-chain registers keep their emitted names |
| AlwaysOutTransposer | 1,310 | 278 | `gen_transposer.py` |
| TwoPortSyncMem | 152 | 16 | `gen_small.py` |
| AccumulatorMem | 146 | 79 | `gen_small.py` |
| GemminiTPU | 142 | 46 | `gen_small.py` |
| PE_256 | 134 | 44 | `gen_small.py` |
| TagQueue | 118 | 38 | `gen_small.py` |
| Queue6_TagWithIdAndTotalRows | 84 | 39 | `gen_small.py` |
| Tile | 40 | 16 | `gen_small.py` |

Left raw: the memories (`mem_64x512`, `ram_6x9`), PE and MacUnit.

How to regenerate (generators in `/mada/users/frabieik/pyro_scratch/gemmini8/gen/`;
each one, run with N=4 or N=8, reproduces the committed 4x4 / 8x8 file byte
for byte):

```bash
python3 gen_small.py      pyrope 16 pyrope2      # Tile, PE_256, queues, memories wrapper, AccumulatorMem, GemminiTPU
python3 gen_mesh_packed.py pyrope/Mesh.prp Mesh4_packed.prp 16 > pyrope2/Mesh.prp   # template: git show 6e3136b~1:gemmini/pyrope2/Mesh.prp
python3 gen_mwd_packed.py  pyrope/MeshWithDelays.prp 16 > pyrope2/MeshWithDelays.prp
python3 gen_transposer.py 16 pyrope2/AlwaysOutTransposer.prp
python3 gen_simtop.py     16 sim                 # wrapper, driver, Verilator twin
```

LEC: the Mesh block alone takes ~500 s of every LEC that contains it (Mesh,
MeshWithDelays, GemminiTPU, the top). As at the smaller sizes, `req`'s
unobservable bits and the read queue's RAM are left out of the obligation on
both sides.

## Simulation

The wrapper ports are all <= 64 bits: the 128-bit A/B/D rows are two words,
the 512-bit accumulator rows eight. Run `drv.bin` with
`--init-zero --set sim.unknown_zero=true`, as at 8x8.

The bench runs 2k cycles (`sum=439173468031777837`), not 25k: `sim_pyrope2`
has to fit the gated run plus three timed re-runs in the 15-min `long` timeout,
and at 5k the gated run alone took 378 s. At 2k the other simulators' timings
are mostly process startup (bench: pyrope 6.3k, Verilog 10.2k, Verilator 6.0k,
pyrope2 24.8 cycles/s). At 5k all four give `sum=4616705506188618455`.

Speed (kaffirlime, 5k cycles, standalone run): lhd sim `pyrope/` 22.9k
cycles/s, Verilog 37.6k, Verilator 8.1k, and `pyrope2/` **22 cycles/s**. The
Mesh loop's sim slowdown (case20) keeps growing with the mesh: ~30x at 4x4,
~100x at 8x8, ~1000x at 16x16.

Mesh16 keeps packed Mesh ports. The array-port form (`gen_mesh.py`/`gen_mwd.py`, used at 4x4 and
8x8) gave no sim gain here on lhd 7ab162cd7 (101 vs 118 cycles/s at 5k) and its Mesh LEC timed out at 1 h.
