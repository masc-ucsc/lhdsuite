# gemmini/Mesh8

The same standalone Gemmini TPU core as `gemmini/`, regenerated with an 8x8
systolic mesh (64 PEs, 256-bit accumulator rows, 64x256 SRAM). It is the size
point for the loop cleanups: the 4x4 and 8x8 emits differ only in sizes, so
the same cleanups apply, and the raw emit grows with the mesh while the loops
do not.

In the bench as core `gemmini8` (`bench/defs.bzl`); all 14 `gemmini8_*` targets
pass on kaffirlime.

## Layout and status (2026-11-06, lhd c53e1728c)

| Dir | Contents | Status |
|---|---|---|
| `verilog/` | `GemminiTPU.sv` (15 modules) + `GemminiSimTop.sv` (flat-port sim wrapper) | Chisel 6.2.0 emit of `/mada/users/frabieik/gemmini_tpu` with `GEMMINI_MESH=8` (`Top.scala` reads the mesh size from that env var, default 4) |
| `pyrope/` | raw emit, `lhd compile verilog --top GemminiTPU`, 7,945 lines | PROVEN-full vs the Verilog in 2 s (`mem_64x256` trusted) |
| `pyrope2/` | 11 modules cleaned, 2,623 lines (-67%) | GemminiTPU top PROVEN-full vs the Verilog in 186 s (lhd 7ab162cd7); each module PROVEN-full vs raw and vs the Verilog |
| `sim/` | `gemmini_tb.prp`, `GemminiSimTop.prp`, `gemmini_tb_verilator.cpp` | same checksum from lhd sim (pyrope, pyrope2, Verilog) and Verilator |

| Module | raw | pyrope2 | How |
|---|---|---|---|
| Mesh | 3,339 | 1,260 | 64 Tiles in one row/col loop; `gen_mesh.py` (below) from the 4x4 cleanup. Ports and per-tile families are arrays (`io_in_a:[8]U8`, one entry per row/column), as in Jose's 4x4 change (6e3136b). The loop is the same as at 4x4; the rest is the 512 scalar registers (declaration + write-back) that LEC needs to pair with the Verilog flops |
| Queue1_AccumulatorReadResp | 2,376 | 31 | one-entry flow queue rewritten from its semantics |
| MeshWithDelays | 945 | 785 | `gen_mwd.py` from the 4x4 hand rewrite; skew-chain registers keep their emitted names, and the 45 de-skew registers for valid/last/id of columns 1..6 (nothing reads them) are dropped |
| AlwaysOutTransposer | 350 | 86 | `gen_transposer.py`: the 64 PE instances declared bottom-right first, so no forward wires; no loop |
| AccumulatorMem | 146 | 79 | port of the 4x4 cleanup (256-bit data, 32-bit mask) |
| PE_64 | 134 | 44 | same as 4x4 PE_16 |
| TagQueue | 118 | 38 | entry loop; entries are 8 bits (total_rows is 4 bits at 8x8) |
| Queue6_TagWithIdAndTotalRows | 84 | 39 | port of the 4x4 cleanup |
| TwoPortSyncMem | 88 | 16 | 32 byte-mask lanes in one loop |
| GemminiTPU | 142 | 46 | as 4x4 |
| Tile | 40 | 16 | as 4x4 |

Left raw: the memories, PE and MacUnit.

The generators live in `/mada/users/frabieik/pyro_scratch/gemmini8/gen/`, and
each one run with N=4 reproduces the 4x4 `gemmini/pyrope2/` file byte for byte:

- `gen_mesh.py <raw Mesh.prp> <4x4 pyrope2/Mesh.prp> 8`
- `gen_mwd.py <raw MeshWithDelays.prp> 8` (register names come from the raw emit)
- `gen_transposer.py 8 <out>`

## Simulation

Run `drv.bin` with `--init-zero --set sim.unknown_zero=true`. The 8x8 has
registers with no initializer whose power-on bits reach the outputs. Without
`--init-zero` the checksum changes with `--seed`, and passing the flags only to
`lhd sim --setup-only/--run-only` does not carry them into a later bare
`drv.bin` run. In the bench, `bench/sim.sh` forwards `lhd.seed`,
`sim.init_zero` and `sim.unknown_zero` from the core's `sim_sets` to the timed
`drv.bin` run, and `gemmini8` sets both `init_zero` and `unknown_zero`.

25k cycles: `sum=3185508839202413007` from Verilator, lhd sim on `pyrope/`,
lhd sim on `pyrope2/` and lhd sim on the Verilog.

Speed from the bench run (kaffirlime, lhd c53e1728c, 25k cycles):

| Target | cycles/s |
|---|---|
| lhd sim `pyrope/` | 62.3k |
| lhd sim `pyrope2/` | 625 |
| lhd sim Verilog | 76.0k |
| Verilator | 47.3k |

Synthesis (`gemmini8_synth`): 1,458,735 gates, 11.7 mm2.

The Mesh loop alone makes lhd sim about 100x slower (a standalone run of the
final tree gives 1.15k cycles/s; the bench number is lower). That is the same
loop codegen issue as the 4x4 (case20), and it grows with the mesh: ~9x at 4x4.

2026-11-09, lhd 7ab162cd7 (Jose's loop-sim fixes), standalone, 25k cycles, same
checksum: `pyrope/` 115k cycles/s; `pyrope2/` with packed Mesh ports 13.2k, with
array Mesh ports 27.6k (~4x slower than raw, from ~100x). At 16x16 the array
ports did not help (101 vs 118 cycles/s) and the Mesh LEC timed out at 1 h, so
`Mesh16/` keeps the packed form (`gen_mesh_packed.py`, `gen_mwd_packed.py`).
