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
| `pyrope2/` | 8 modules cleaned, 3,140 lines (-60%) | PROVEN-full vs the Verilog in 74 s; each module PROVEN-full vs raw and vs the Verilog |
| `sim/` | `gemmini_tb.prp`, `GemminiSimTop.prp`, `gemmini_tb_verilator.cpp` | same checksum from lhd sim (pyrope, pyrope2, Verilog) and Verilator |

| Module | raw | pyrope2 | How |
|---|---|---|---|
| Mesh | 3,339 | 1,257 | 64 Tiles in one row/col loop; `gen_mesh.py` (below) from the 4x4 cleanup. The loop is the same as at 4x4; the rest is the 512 scalar registers (declaration + write-back) that LEC needs to pair with the Verilog flops |
| Queue1_AccumulatorReadResp | 2,376 | 31 | one-entry flow queue rewritten from its semantics |
| AccumulatorMem | 146 | 79 | port of the 4x4 cleanup (256-bit data, 32-bit mask) |
| PE_64 | 134 | 44 | same as 4x4 PE_16 |
| TagQueue | 118 | 38 | entry loop; entries are 8 bits (total_rows is 4 bits at 8x8) |
| Queue6_TagWithIdAndTotalRows | 84 | 39 | port of the 4x4 cleanup |
| TwoPortSyncMem | 88 | 16 | 32 byte-mask lanes in one loop |
| Tile | 40 | 16 | as 4x4 |

Left raw: MeshWithDelays (945; the 4x4 cleanup is a hand rewrite with no loop
and its skew chains grow to hundreds of named registers), AlwaysOutTransposer
(350; loop forms do not LEC, see the 4x4 notes), GemminiTPU, the memories.

`gen_mesh.py` lives in `/mada/users/frabieik/pyro_scratch/gemmini8/gen/`:
`gen_mesh.py <raw Mesh.prp> <4x4 pyrope2/Mesh.prp> 8`. Run with `4` on the 4x4
raw emit, it reproduces `gemmini/pyrope2/Mesh.prp`.

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

Speed from the bench run (kaffirlime, 25k cycles):

| Target | cycles/s |
|---|---|
| lhd sim `pyrope/` | 62.3k |
| lhd sim `pyrope2/` | 652 |
| lhd sim Verilog | 76.0k |
| Verilator | 50.3k |

Synthesis (`gemmini8_synth`): 1,458,735 gates.

The Mesh loop alone makes lhd sim about 100x slower (an earlier standalone run
gave 122k vs 1.2k cycles/s). That is the same loop codegen issue as the 4x4
(case20), and it grows with the mesh: 16x at 4x4.
