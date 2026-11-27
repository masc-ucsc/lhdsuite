# Mixed Rocket / BOOM / Gemmini SoC

The design instantiates **12 Rocket tiles, four BOOM tiles, and one full 16×16 Gemmini
accelerator** on a shared **6×3 mesh**, with one external gateway. The checked-in
[Pyrope glue](pyrope/MixedSocTop.prp) imports the existing
[Rocket](../rocket/pyrope2/RocketTile.prp), [BOOM](../boom4/pyrope/BoomTile.prp), and
[Gemmini](../gemmini/Mesh16/pyrope2/GemminiTPU.prp) trees, which supply the source for `lhd sim`, `lhd synth` and the floorplan.
The cores' original Verilog (`rocket/verilog`, `boom/verilog`, `gemmini/Mesh16/verilog`)
is only staged for the Verilator comparison. The checksums of the `pyrope/` and
`pyrope2/` closures are identical (cycle-exact; checked at 12,000 cycles). There are no copied CPU
or accelerator implementations in this package. Custom adapters bridge their
TileLink ports and Gemmini accumulator interfaces to the shared request/response
network. The runtime enable mask controls reset on each populated tile.

The `scripts/` directory holds the simulation runners, source generators,
shared topology, and floorplan generator/validator. Simulation drivers stay in
`sim/`, and design glue stays in `pyrope/` and `rtl/`.

### Tile configurations

The default `heterogeneous` preset binds four configurations to the same BOOM4
tile implementation. Rocket harts 1 and 2 use early-out multiplication.

| BOOM hart | Configuration changes from Small |
|---|---|
| 12 | Default Small |
| 13 | Two-wide dispatch, 48-entry return stack, 12 immediate physical registers, 32-entry FTQ, one-cycle integer-to-FP conversion, three-cycle FMA, FP division disabled, six performance counters, short forward branch predication disabled, 80 integer and 64 FP physical registers, two integer register banks, BOOM2 predictor (BIM, BTB, gshare), 64 ROB entries, 16 fetch-buffer entries, 12 memory issue slots, four slow slots, direct-mapped 32-set I-cache, BTB fast repair disabled, conservative issue, an age-matrix memory queue, no PMP or L2 TLB, three-step divider |
| 14 | Five-wide dispatch, eight-lane fetch, 40-entry fetch buffer, return prediction disabled, 48 immediate physical registers, 40-entry FTQ, four-cycle integer-to-FP conversion, six-cycle FMA, next-line data prefetching, 144 integer and 128 FP physical registers, 130 ROB entries, Alpha21264 tournament predictor, 12 FP and unique-function issue slots, 12 memory slots and 32 ALU slots, each queue with four slow slots and restricted selection on the ALU queue, sixteen PMP regions, four-way L2 TLB, four-step divider |
| 15 | Three-wide dispatch, 12-entry return stack and fetch-target queue, four-cycle load-use path, noncompacting dispatch lookahead, 64 integer registers in four banks with four read ports per bank, 56 FP registers in two banks, 24 ROB entries, 30 fetch-buffer entries, 32 memory issue slots, four slow slots, restricted issue selection, single-ported TAGE, slow-BTB redirect, history-only stall repair disabled, delayed dual-port I-cache, RAS top repair disabled |

Each Rocket and BOOM reads its physical hart ID through `mhartid`. A parent can bind its
own 16-tile record to `MixedSocTop<Tiles>` or `CoherentMixedSoc<Tiles=...>`. The `uniform` record uses the default
BOOM and Rocket at every respective position. The heterogeneous BOOMs use one, two, five and three dispatch lanes respectively. Each has one integer ALU per dispatch lane. Hart 13 uses six branch snapshots and fixed ALU columns. Hart 14 uses rotating ALU columns, three memory issue ports and two FP issue ports. [TileProfiles.prp](pyrope/TileProfiles.prp)

Both Pyrope tops attach a TileLink-C memory manager at the gateway. The 12 RV32 Rocket tiles use two-way, 64-set data caches in both presets. Both Rocket and BOOM cache 64-byte lines. Rocket transfers a line in sixteen 32-bit beats and BOOM transfers it in eight 64-bit beats. The
default SRAM spans 4 KiB from `0x80000000`. It tracks one holder per line,
recalls that holder before transferring the line, and reserves sink ID 7 for
its grants. Boot memory remains external. The four-hart regression runs the same ROM on all four BOOM configurations.
Each core first executes 127 uncompressed NOPs and jumps to the coherence program. Harts 12 and 13 write different jump targets to adjacent cache lines. Harts 14
and 15 load those targets and jump through them. The driver checks both dirty
transfers and both dependent instruction fetches. The ROM selects the pair and
the reader/writer role from `mhartid`. [Boot program](sim/coherent_harts.S)
Run `bazel test //mixed_soc:coherent_harts --override_module=livehd=../livehd`.
[CoherentMixedSoc.prp](pyrope/CoherentMixedSoc.prp)

The four BOOM harts use 8, 6, 20 and 12 branch tags respectively. Their load/store queue depths are 8/8, 16/16, 32/32 and 24/12.
The `boomHarts` parameter on `MixedSocTop` and `CoherentMixedSoc` selects zero to four BOOM sockets at elaboration, starting at hart 12. The remaining sockets drive idle mesh ports. Each populated socket binds its own tile configuration to the same TileLink endpoint. The runtime `core_enable` mask releases the populated harts from reset.

The profile checker also runs the coherent program with the CS152 baseline core geometry on writer hart 12. Run both SoC presets, the coherent teaching-core variant, the subsystem tests and the invalid-width check from the suite root.

```sh
python3 mixed_soc/scripts/check_profiles.py --lhd ../livehd/bazel-bin/lhd/lhd
```

For Bazel runs below, add `--override_module=livehd=../livehd` while the
suite's pinned LiveHD predates package-relative imports and record bindings.

### Shared interrupt controllers

Both Pyrope tops instantiate one Chipyard CLINT and one PLIC at the mesh gateway.
Each hart has its own 32-bit software-interrupt register at `0x02000000 + 4*hart`
and 64-bit timer compare at `0x02004000 + 8*hart`. The shared 64-bit time
register at `0x0200bff8` increments on `rtcTick`, which defaults high.
Program each timer compare before enabling timer interrupts.

The PLIC starts at `0x0c000000`. Input bit `i` of `deviceInterrupts` drives
level-sensitive source ID `i+1`. Priorities and pending bits are shared.
Enables, threshold, claim and completion are per context. Each populated hart has a
machine context and each supervisor-capable hart also has a supervisor context.
In the default profile, Rocket harts 0–11 use contexts 0–11 and the four BOOM
harts use M/S pairs 12/13, 14/15, 16/17 and 18/19. The gateway adapts
32-bit Rocket and 64-bit BOOM accesses to the same register file.
[Gateway](pyrope/PlatformInterrupts.prp) · [CLINT](../chipyard/pyrope/CLINT.prp) · [PLIC](../chipyard/pyrope/TLPLIC.prp)

```sh
bazel test //mixed_soc:interrupt_mmio //mixed_soc:interrupt_harts --override_module=livehd=../livehd
```

The MMIO test exercises supervisor routing, a stalled claim, a device ID above
31 and partial timer writes. The firmware test runs Rocket hart 3 and two
differently configured BOOM harts, 12 and 13. It checks interprocessor software
interrupts, timer traps, and external claims and completions. The three harts pass
one dirty cache line from Rocket 3 to BOOM 12 to BOOM 13 and back to Rocket 3.
Each recipient checks two words in different beats before signaling the next
hart through the CLINT. The driver checks that all three reach their own completion
addresses, issue their completion stores, and return 16, 8, and 8 dirty beats respectively. SRAM and interrupt requests must stay on-chip. [Firmware](sim/interrupt_harts.S)

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
execute `park: wfi; j park` with interrupt delivery disabled by firmware. They remain ordinary
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

The [SystemVerilog glue](rtl/soc.sv) provides the reference mesh for the Gemmini connectivity workload. The shared interrupt controllers and coherent SRAM are exercised by the Pyrope regressions.
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
ID. The reference Verilog uses the original narrow hart-ID port. The single
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
XY hops and round-robin injection. In Pyrope the gateway routes cacheable SRAM
requests to the shared coherence manager and peripheral requests to the CLINT or PLIC.

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

