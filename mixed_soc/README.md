# Mixed Rocket / BOOM / Gemmini SoC

The design instantiates **12 Rocket tiles, four BOOM tiles, and one full 16×16 Gemmini
accelerator** on a shared **6×3 mesh**, with one external gateway. The checked-in
[Pyrope glue](pyrope/MixedSocTop.prp) imports the existing
[Rocket](../rocket/pyrope2/RocketTile.prp), [BOOM](../boom/pyrope2/BoomTile.prp), and
[Gemmini](../gemmini/Mesh16/pyrope2/GemminiTPU.prp) trees: the maintained `pyrope2/`
version of each core, which is the source for `lhd sim`, `lhd synth` and the floorplan.
The cores' original Verilog (`rocket/verilog`, `boom/verilog`, `gemmini/Mesh16/verilog`)
is only staged for the Verilator comparison. The checksums of the `pyrope/` and
`pyrope2/` closures are identical (cycle-exact; checked at 12,000 cycles). There are no copied CPU
or accelerator implementations in this package. Custom adapters bridge their
TileLink ports and Gemmini accumulator interfaces to the shared request/response
network. All instances remain in the design when only a subset is enabled.

The `scripts/` directory holds the simulation runners, source generators,
shared topology, and floorplan generator/validator. Simulation drivers stay in
`sim/`, and design glue stays in `pyrope/` and `rtl/`.

### Tile configurations

The concrete `MixedSocTop` uses the `selected` record in
[TileProfiles.prp](pyrope/TileProfiles.prp). The default `uniform` preset
matches the pinned RTL. Set `selected = heterogeneous` to give Rocket tiles
1 and 2 early-out multipliers and BOOM tiles 13 and 14 four slow entries in
each memory and integer ALU issue queue. A parent can also bind its own
16-entry record to `mixed_soc<Tiles>`. Each tile owns its register state.

The supported Rocket option is `mulEarlyOut` on the RV32 radix-256
multiplier. BOOM supports per-queue `numSlowEntries` with eight entries and
one physical dispatch lane. The compiler checks each queue against the core
width. This workload exercises connectivity. Separate tests check multiplier
latency and the cycle when dispatch backpressure begins.

From lhdsuite, run both presets, both unit tests and the invalid-width control:

```sh
python3 mixed_soc/scripts/check_profiles.py --lhd ../livehd/bazel-bin/lhd/lhd
```

For Bazel runs below, add `--override_module=livehd=../livehd` while the
suite's pinned LiveHD predates package-relative imports and record bindings.

### Matched Pyrope and Verilator simulation

```sh
bazel test //bench:mixed_soc_sim_pyrope
bazel test //bench:mixed_soc_sim_verilator
# Both, or equivalently //mixed_soc:sim_test:
bazel test //bench:mixed_soc
bazel run //bench:show -- --core mixed_soc
```

LiveHD is built from the suite's source dependency, as for other cores. Verilator
is optional: its target reports `METRIC verilator_present 0` and skips when absent.
Use `VERILATOR` to select an installed executable and `LHD_BENCH_JOBS` to bound
compiler parallelism. The targets run exclusively to keep benchmark timing useful.

The two [drivers](sim/mixed_soc_tb.prp) share a generated schedule
([C++ twin](sim/mixed_soc_tb_verilator.cpp), [generator](scripts/gen_sim.py)). The host
first writes eight pairs of distinct branch destinations into row 60 of the real
Gemmini accumulator memory through the mesh. Then **Rocket0, Rocket3, BOOM0,
and BOOM2 perform the connectivity test** (working mask `0x5009`). All 16 CPUs
leave reset together after the preload (`core_enable=0xffff`); the other 12
execute `park: wfi; j park` with interrupts held low. They remain ordinary
clocked instances and are not held in reset.
Each active CPU fetches its own tiny program, loads its pointer from the Gemmini
accumulator, and branches to its unique destination. Assertions require all four
landing/destination fetches, require reset-vector fetches from all 16 CPUs, and catch
incorrect packet origins, routing, and addresses. The fixed run continues for
**36,000 cycles**, including the CPUs' final self loops. While the CPUs run, the host
also drives the **16×16 systolic mesh** through the window's registers (below): it
enables automatic write-back, pushes a 16-row request with sixteen A/B/D row pushes,
then reads STATUS, the eight words of a mesh result and four accumulator rows the mesh
filled. The mesh is therefore live logic in both simulation and synthesis: the earlier
glue tied the mesh inputs to zero, so synthesis removed the whole mesh. The drivers
fold the host's reads of the mesh into `mesh=` and the accumulator rows into `acc=`;
both must be nonzero. The mesh and accumulator results depend on the TPU computing,
so a dropped mesh, a stale read path or a lost write-back fails the run.

Both drivers fold observed transfers on every cycle with
`sum = (sum * 31 + obs) & (2^63 - 1)`. The
Pyrope and C++ drivers agreed at 12,000, 36,000 and 360,000 cycles.
`run_sim.py` checks the pinned workload checksums at these lengths and compares
the entire signature in compare mode. Zero-filled power-on state is used by both.

LiveHD setup writes native DUT and testbench objects under `lhd/sim/`.
`lhd_simrt`, built beside `lhd`, runs those objects.
`sim_setup_ms` measures the complete LiveHD build and `sim_exec_ms` measures
execution. Verilator reports `verilator_cc_ms` and `verilator_exec_ms`.
To retain logs, reuse a build, compare another length, or run both directly:

```sh
python3 mixed_soc/scripts/run_sim.py compare --lhd ../livehd/bazel-bin/lhd/lhd \
  --work /tmp/mixed-soc-sim -j 8
```

`--cycles N` changes both simulators together; default-count runs require the
pinned checksum, and compare mode requires equality at every length. This runner
keeps imported package directories intact instead of flattening them into a
standalone core's scratch tree; the `//bench:` targets use this runner and keep the usual benchmark names.

To collect **host** user-space instructions, CPU cycles, and IPC, append
`--host-perf` to the direct comparison command. Only the simulator executables
are profiled; generation and compilation stay outside the counter interval.
`sim_exec_host_instructions`, `sim_exec_host_cycles`, `sim_exec_host_ipc` and the
corresponding `verilator_exec_host_*` metrics come from a grouped
`perf stat -e '{cycles:u,instructions:u}'` measurement. The raw CSVs remain in
`--work`. This optional mode includes perf launcher overhead in its wall time;
the counters cover the child simulator, including initialization and teardown.
It requires access to Linux performance counters; the runner fails explicitly
before building when access is denied. The development host currently has
`perf_event_paranoid=3`, so no host instruction-count or IPC result is available
from this session. Wall times above were measured without perf.

The [SystemVerilog glue](rtl/soc.sv) implements the same network and ports.
`scripts/generate_rtl.py` assembles a temporary Verilator input from the original vendor
files, qualifying conflicting Chisel module names only in that build directory.
No vendor RTL is checked in here. To regenerate Pyrope glue deliberately:

```sh
python3 mixed_soc/scripts/regenerate_pyrope.py --lhd ../livehd/bazel-bin/lhd/lhd \
  --work /tmp/mixed-soc-regenerate
python3 mixed_soc/scripts/gen_sim.py
```

The recipe retains only glue, imports the existing core trees, and generates the
Pyrope XY mesh from [topology.py](scripts/topology.py). Re-run the matched simulation
after regeneration. Rocket and BOOM retain their own sibling module names in Pyrope.

### Additional connectivity regressions

```sh
python3 mixed_soc/scripts/simulate.py mesh --work /tmp/mixed-connectivity
python3 mixed_soc/scripts/simulate.py system --work /tmp/mixed-connectivity
bazel test //mixed_soc:topology_test //mixed_soc:mesh_sim //mixed_soc:system_sim
```

These older, untimed Verilator tests cover all 324 ordered endpoint pairs and
18-way gateway contention, and all 16 CPUs branching through Gemmini pointers.
They also check the eight accumulator lanes, byte masks, response stalls, CTL
read-back, read-only and write-only registers, and denied host accesses. Their explicit targets need Verilator installed.

The gateway exposes `mem_req`/`mem_rsp` for external memory and
`host_req`/`host_rsp` for MMIO. The network tags packets with the physical tile
ID; the vendored CPUs' one-bit hart ID cannot identify all 16 copies. The single
Gemmini (tile 16) owns the 8 KiB window `0x18000..0x19fff` ([acc.sv](rtl/acc.sv)):

| Offset | Contents |
| --- | --- |
| `0x0000..0x0fff` | the real 64×512-bit accumulator, 64 rows of 64 bytes, eight 64-bit lanes per row, byte-masked puts and gets |
| `0x1000..0x1028` | A, B, D staging: the put of the high word pushes `{hi, lo}` (16 int8 or int32 lanes) to the mesh port |
| `0x1030` REQ | put: mesh request (tag, dataflow, propagate, shift, transposes, total rows, flush) |
| `0x1038` CTL | put/get: `[0]` write every mesh result into the accumulator at the next row, `[1]` accumulate, `[2]` restart the row counter |
| `0x1040` STATUS | get: result waiting, its tag, rows and last flag, a lost-result flag, the next automatic row |
| `0x1080..0x10b8` | the waiting mesh result, eight 64-bit words; reading the last frees it |

Automatic write-back lands one cycle after the result, from the held copy, so the
TPU's inputs never depend on its outputs. Other CPU memory traffic goes to the gateway.
The request and response lanes each admit one packet at a time with registered
XY hops and round-robin injection. This is a connectivity fixture, not a
coherent shared-memory manager.

### Floorplan

| Family | Instances | Modeled logic cells per instance | Colors per instance | SRAMs per instance |
| --- | ---: | ---: | ---: | ---: |
| Rocket | 12 | 5,000,000 | 160 | 6 |
| BOOM | 4 | 18,000,000 | 600 | 16 |
| Gemmini PE | 256 (one 16×16 accelerator) | 1,000,000 | 32 | 1 |
| Fabric router | 18 | 12,000 | 1 | 0 |

Total: 388,216,000 modeled logic cells, 12,530 colors, 392 SRAMs. Populations
are capacity-test parameters (the real 16×16 Gemmini is about 6M gates plus SRAMs; the
modeled 1M cells per PE deliberately overstates it). Each SRAM is one physical object. The generator
allocates one object per color or SRAM, records crossing nets, and gives the
gateway four named terminals on the block's right edge. The terminal positions
are in DBU. The gateway's home chunk can sit inside the floorplan: its boundary
contact and the external pin are reported separately in `sweep.json`.

Build the planner in the LiveHD checkout you want to measure:

```sh
# In LiveHD:
bazel build -c opt //pass/place:fp_plan_summary
# In lhdsuite, set PLANNER to that built binary:
python3 mixed_soc/scripts/floorplan.py --planner "$PLANNER" --out mixed_soc_runs
```

The runner starts a fresh process for each of 1, 2, 4, 8 and 16 decimal GB,
validates the saved plans, and writes `sweep.json`, the five metadata bundles,
and `color_graph.json`. The reported load and plan times exclude export; peak RSS is
reported both through planning and after export. These are planner measurements.
It also reports crossing-net count and the sum of Manhattan distances between
connected chunk centers, a placement-quality proxy before routing. Per-chunk
estimated bytes use LiveHD's cold downstream model and do not certify
that actual detailed placement fits that budget. No downstream cell placement, timing analysis or routing
of the modeled 388M-cell workload is run.

For just the portable input, run `python3 mixed_soc/scripts/floorplan.py --graph soc.json`.
`bazel test //mixed_soc:topology_test` checks populations and reachability without
requiring a new LiveHD binary. The full sweep additionally checks every object's
unique home, budget, exact tiling without overlap, repeated module partitions,
and that increasing the budget never increases the number of chunks.

