# rocket

Rocket-chip `TinyConfig` (small config) in Verilog and Pyrope. Used as a whole,
loop-rich RISC-V design bigger than Dino, to iterate on LiveHD loops (sim,
synth, LEC), and as a second data point for the ASPLOS27 frontend-cost
measurement (Chisel cold frontend 13.2 s, `asplos27/experiments/frontend_cost_rocket/`).

## Configuring the Pyrope tile

`pyrope2/RocketTile.prp` defaults to the RV32 Tiny scratchpad tile. Pass a compile-time record to the same module for RV64. The configuration factory supplies the defaults for omitted fields.

```pyrope
const configs = import("RocketConfig")
const RocketTile = import("RocketTile.RocketTile")
comptime const profile = configs.params(xLen=64, useCompressed=true, mulUnroll=8, fastLoadByte=true, btbEntries=16)
// Inside the enclosing module, connect its TileLink, clock, reset and interrupt ports.
```

Instantiate the tile with `RocketTile<profile>(...)`. The named profiles are `tiny`, `rv64`, `earlyMul` and `tinyNoMulDiv`.

| Configuration group | Factory parameters and Tiny defaults |
| --- | --- |
| Base ISA | `xLen=32`, `useRVE=false`, `useCompressed=true`, `useAddiForMv=false`, `useAtomics=true`, `useAtomicsOnlyForIO=false` |
| Multiply and divide | `useMulDiv=true`, `mulUnroll=8`, `mulEarlyOut=false`, `divUnroll=1`, `divEarlyOut=false`, `divEarlyOutGranularity=1`, `mulDivClockGate=false` |
| Clock gating | `clockGate=false` controls the core pipeline and instruction frontend. |
| Nonstandard instructions | `haveCease=true` enables Rocket’s CEASE instruction, which halts retirement until reset. |
| Optional integer instructions | `useConditionalZero=false`, `useZba=false`, `useZbb=false`, `useZbs=false` |
| Fetch and load bypass | `btbEntries=0`, `icacheSets=64`, `icacheWays=1`, `fastLoadWord=true`, `fastLoadByte=false` |
| Return address stack | `nRAS=0` |
| Branch history | `branchPredictionModeCSR=false`, `bhtEntries=0`, `bhtCounterLength=1`, `bhtHistoryLength=8`, `bhtHistoryBits=3` |
| Floating point | `fLen=0`, `minFLen=32`, `divSqrt=true`, `fpuClockGate=false` |
| Data cache | `useDataScratchpad=true`, `dcacheSets=256`, `dcacheWays=4` (coherent cache) |
| Privilege | `useUser=false`, `useSupervisor=false`, `useVM=false` |
| Translation | `iTLBEntries=4`, `dTLBEntries=4`, `nPTECacheEntries=8`, `nL2TLBEntries=0`, `nL2TLBWays=1`, `pgLevels=0` (XLEN default), `asIdBits=0` |
| External debug | `useDebug=true` |
| Hardware triggers | `nBreakpoints=1`, `useBPWatch=false`, `mcontextWidth=0`, `scontextWidth=0` |
| Physical memory protection | `nPMPs=8` |
| Local interrupts | `nLocalInterrupts=0` |
| Hardware performance counters | `nPerfCounters=0` (0–29), starting at counter 3 |
| Machine CSRs | `misaWritable=true`, `mtvecInit=0`, `mtvecWritable=true`, `haveBasicCounters=true`, `mvendorid=0`, `mimpid=0x20181004` |

`mulUnroll` selects 1 through XLEN multiplier bits per iteration. At XLEN the tile uses a separate two-stage multiplier that accepts one multiply per cycle, including while an independent divide is running. Other values share the iterative unit with division. A standalone `MulDiv<C=profile>` includes iterative multiplication at every supported digit width. A short first digit handles widths that do not divide XLEN. RV64 MULW can finish after processing 32 bits when the digit width divides 32 and is less than 32. `divUnroll` can be any integer from 1 through XLEN. With `divEarlyOut`, the divider skips leading zero quotient bits in whole groups of steps. `divEarlyOutGranularity` controls the alignment of the skip. Fast byte-load bypass requires word-load bypass.

The four optional integer instruction groups follow Chipyard's Rocket decode tables. Each defaults off. RV64 also supports the word and unsigned-word variants of the enabled extensions.

The instruction cache defaults to 64 sets and one way. Each line holds 64 bytes. The set and way counts are powers of two, and associative configurations rotate the replacement way within each set.

Both profiles use Tiny's 32-bit physical memory map. The scratchpad starts at `0x80000000`, with 64 bytes per set and a default capacity of 16 KiB. Choose a power of two for `dcacheSets`. Fetch and data access use the same map and check PMP permissions independently. The bare tile has no page-table walker instance. The TileLink master beat is `max(xLen, fLen)` bits, including 64-bit beats on RV32D. The scratchpad slave port transfers four bytes per beat on either profile. The compressed decoder follows the local Chipyard Rocket implementation. Set `useAddiForMv=true` to expand C.MV into ADDI with a zero immediate. The default expansion uses ADD with x0. The archived Tiny RTL also decoded some Zcb and Zcmop encodings. Set `btbEntries` to a positive entry count to instantiate a direct-mapped target buffer with one direction bit per entry. Zero selects sequential fetch until the core redirects. With `useRVE=true`, the register file stores x1 through x15 and instructions that use x16 through x31 trap. The basic counters support 64-bit writes on RV64 and low/high CSR pairs on RV32.

With `haveBasicCounters=true`, set `nPerfCounters` to allocate 40-bit counters starting at `mhpmcounter3`. Write `mhpmeventN` to select events. Bits 1–0 select retired instructions (0), pipeline stalls and redirects (1), or cache and TLB traffic (2). The event mask starts at bit 8. Multiple selected events increment a counter at most once per cycle. For example, `0x600` counts retired integer loads and stores, and `0x202` counts data-cache A-channel transfers. The retired group includes separate multiply/divide and FP instruction classes when those units are present. The cache group orders its bits as I-cache acquisition, D-cache acquisition, D-cache release, I-TLB miss, D-TLB miss, and L2 TLB miss. Selector `0x2002` counts accepted L2 lookups that miss and start a walk. It reads zero with the L2 disabled.

The counter bank can sleep when all event masks are clear and earlier pipeline samples have drained. A counter CSR access wakes the bank. Initialize the counter before measuring. On RV32, `mhpmcounterNh` holds bits 39–32. Bit N of `mcountinhibit` freezes counter N. Set the corresponding `mcounteren` bit for supervisor reads, and both `mcounteren` and `scounteren` bits for user reads when supervisor mode is present. Unimplemented machine counter and selector slots read zero.

With a target buffer enabled, set `bhtEntries` to a power of two to use a global branch history table. For example, `btbEntries=16, bhtEntries=512, bhtCounterLength=2` uses two-bit counters for conditional branches. The other supported counter length is one. `bhtHistoryLength` is the number of remembered outcomes. `bhtHistoryBits` selects how many hashed history bits enter the table index (zero uses the fetch address alone). Fetch saves the index with each packet so a resolving branch trains the counter it looked up. A core redirect restores the resolved history. Unconditional jumps use their target-buffer entry directly.

Set `branchPredictionModeCSR=true` to expose machine CSR `0x7c0` on either XLEN. Bit 0 resets to zero for dynamic prediction. Writing one selects static taken prediction for conditional branches when the target buffer is enabled. Every write invalidates the target buffer. Static mode preserves the dynamic BHT counters. Fetch decodes a missing branch target from the packet, including a 32-bit branch split across two words. With the option off, access to the CSR raises an illegal-instruction exception.

With a target buffer enabled, set `nRAS` to the number of return addresses to remember. For example, `btbEntries=16, nRAS=6` enables a six-entry stack independently of the branch history table. Fetch updates the speculative stack when it accepts a predicted call or return. A redirect restores the resolved links, including the transfer resolving that cycle. The stack recognizes the x1 and x5 link registers, compressed calls and returns, and JALR coroutine exchanges. A full stack drops its oldest link. An empty stack uses the last target recorded for the return.

Set `useAtomicsOnlyForIO=true` with `useAtomics=true` to keep MISA.A and send arithmetic and logical AMOs to capable uncached TileLink devices. The local scratchpad and coherent RAM raise a store access fault for AMOs. LR raises a load access fault and SC raises a store access fault in every region. The scratchpad slave accepts Get and Put transactions in this profile. Setting `useAtomics=false` disables the ISA extension in either configuration.

Set `useDataScratchpad=false` to instantiate the blocking coherent DCache on RV32 or RV64. The cache covers physical addresses `0x80000000` through `0xffffffff`. Choose powers of two for `dcacheSets` and `dcacheWays`. The tile exposes the cache's five TileLink channels on the `memA` through `memE` ports. A carries AcquireBlock with every byte enabled. A and C use 64-byte lines. D must return the request's source ID. The existing master port still carries instruction fetches and uncached device accesses. The coherent profile omits the scratchpad slave adapter. A manager supplies backing memory and permission grants. The directed tests use one tile.

Set `clockGate=true` to gate the pipeline and instruction frontend independently. CSR `0x7c1` resets to `0xe` with this option. Bit 2 forces the pipeline and FPU clocks on and bit 1 forces the frontend clock on. Clear both overrides with `csrci 0x7c1, 6`. WFI wakeup logic stays on the tile clock, and the core resumes on a locally enabled interrupt.

Set `mulDivClockGate=true` to stop the integer multiply/divide clock while idle. An incoming request wakes the unit. It stays awake until writeback accepts the result or the pipeline kills the instruction. In a full-unroll configuration the separate multiplier also has a clock gate and wakes independently of the divider.

Set `fLen=32` for F or `fLen=64` for F and D. Set `minFLen=16` to add half precision. `divSqrt=false` omits floating-point division and square root. With `fpuClockGate=true`, the FPU clock runs for FP instructions in decode, execute and writeback, and on tagged FP load responses. The FPU reads its register file at writeback and waits for outstanding FP load responses. It supports NaN boxing, rounding modes, accrued flags and the FS privilege state. The FPU timing is specific to this implementation. RVE requires `fLen=0`.

With `useUser=true`, machine firmware can use `mret` to enter user mode. The tile applies the current privilege to instruction PMP checks, the effective data privilege to load/store checks, and `mcounteren` to user counter reads.

Set `useDebug=false` to omit the debug CSR bank and its saved state. DCSR, DPC, DSCRATCH0 and DRET then raise illegal-instruction exceptions. EBREAK takes a breakpoint exception. The raw halt-request input follows Chipyard’s interrupt wiring on both profiles. It wakes WFI and takes machine interrupt 14 when debug is disabled. With debug enabled it enters the debug ROM at `0x800`. A nested debug exception enters at `0x808`.

Set `nBreakpoints` to the hardware trigger count. Firmware selects an entry with `tselect`. Each entry can match an instruction, load, or store address, with M/S/U enables, an exact or masked address, or a range bound. Two adjacent triggers can form a chain. Zero entries omit the trigger bank and return zero from all four trigger CSRs. With a non-power-of-two count, unused selectors also read zero from the data CSRs. The default action raises a breakpoint exception. Debug mode can program a debug-only trigger. With `useBPWatch=true`, actions 2–7 report matches on the tile’s `watchValid` and `watchAction` outputs. Bit `i` and action bits `3*i..+3` describe entry `i` alongside the retiring instruction.

Set `mcontextWidth` or `scontextWidth` to expose the corresponding context-ID CSR, even when the trigger count is zero. Each defaults to zero. A trigger’s `tdata3` selects which IDs must match. RV32 compares up to 6 machine and 16 supervisor bits. RV64 compares up to 13 and 34 respectively. Both CSRs retain the full configured ID width.

Set `nPMPs` to 0–16 on either XLEN. Zero omits the PMP registers and checkers. With entries enabled, unused address and configuration fields read as zero. The lowest-numbered entry overlapping a transfer controls access. A partial match faults even in machine mode.

Set `nLocalInterrupts` to 0–16 on RV32 or 0–48 on RV64. Bit 0 of the `localInterrupts` input maps to cause 16. Within a privilege level, the highest enabled local interrupt takes priority over the other local and standard interrupts. Machine interrupts take priority over delegated supervisor interrupts. In vectored mode, the trap table aligns to 128 bytes on RV32 and 256 bytes on RV64.

With `useSupervisor=true`, the tile implements machine, supervisor and user privilege. It supports trap delegation, direct and vectored supervisor interrupts, `sret`, and the supervisor CSR views of interrupt, status and counter state. Drive `supervisorExternalInterrupt` for the external supervisor interrupt. The bare supervisor profile reads zero from `satp`.

With `useVM=true`, the tile includes supervisor and user mode, separate instruction and data TLBs, and a page walker. RV32 uses Sv32. RV64 defaults to Sv39. Set `pgLevels=4` to also support Sv48, or `pgLevels=5` to support Sv48 and Sv57. Firmware selects any implemented mode through `satp`. An unsupported mode leaves the entire CSR unchanged. Set `asIdBits` to 0–9 on RV32 or 0–16 on RV64. The low implemented ASID bits read back from `satp`. Both TLBs tag translations and pending faults with the ASID, mode and root page table. Every form of `sfence.vma` flushes both TLBs and cancels outstanding fills. A hit checks the effective privilege, access type, SUM and MXR. Software manages the PTE accessed and dirty bits. Both walkers share a fully associative cache of non-leaf PTEs, indexed by physical PTE address. Set `nPTECacheEntries=0` to omit it. Positive sizes use tree pseudo-LRU replacement. A hit supplies the next table page in one cycle. Leaf reads and cache misses use the DCache and undergo supervisor PMP checks. Every `sfence.vma` clears the pointer cache and suppresses refills from outstanding walks. Set `nL2TLBEntries` to share successful 4 KiB translations between instruction and data accesses. Entries and ways must be powers of two, with at least one entry per way. The VPN selects a set, and the ASID, mode and root page distinguish address spaces. Each L1 rechecks the stored leaf permissions for the current access. Superpages stay in the L1s. A fence invalidates the shared entries and suppresses outstanding fills. The array clock runs during lookup, refill, fence and reset.

The I-cache uses the virtual set for lookup and refill and checks a physical tag, including for ways larger than a page.

The paged firmware test installs its own tables, runs supervisor code from a virtual ROM mapping, remaps a user data page, and verifies the results at both physical locations. It also checks instruction and load page faults, supervisor trap return, and a TVM-protected fence on both widths.

Run the checks from this directory with a current LiveHD build.

```sh
lhd sim sim/return_program.prp --workdir /tmp/rocket-return-program
lhd sim sim/return_stack.prp --workdir /tmp/rocket-return-stack
lhd sim sim/core_clock.prp --workdir /tmp/rocket-clock
lhd sim sim/prediction_mode.prp --workdir /tmp/rocket-prediction-mode
lhd sim sim/static_prediction.prp --workdir /tmp/rocket-static-prediction
lhd sim sim/history_table.prp --workdir /tmp/rocket-history-table
lhd sim sim/history_program.prp --workdir /tmp/rocket-history-program
lhd sim sim/tile_profiles.prp --workdir /tmp/rocket-boot
lhd sim sim/atomic_io.prp --workdir /tmp/rocket-atomic-io
lhd sim sim/scratchpad_slave.prp --workdir /tmp/rocket-slave-replay
lhd sim sim/coherent_program.prp --workdir /tmp/rocket-coherent-boot
lhd sim sim/coherent_cache.prp --workdir /tmp/rocket-coherent-bus
lhd sim sim/rv64_program.prp --workdir /tmp/rocket-rv64
lhd sim sim/div_program.prp --workdir /tmp/rocket-div-program
lhd sim sim/pipelined_mul.prp --workdir /tmp/rocket-pipelined-mul
lhd sim sim/multiply_digits.prp --workdir /tmp/rocket-multiply-digits
lhd sim sim/divider_profiles.prp --workdir /tmp/rocket-divider
lhd sim sim/bit_operations.prp --workdir /tmp/rocket-bit-operations
lhd sim sim/float_program.prp --workdir /tmp/rocket-float
lhd sim sim/half_program.prp --workdir /tmp/rocket-half
lhd sim sim/float_arithmetic.prp --workdir /tmp/rocket-float-arithmetic
lhd sim sim/bit_program.prp --workdir /tmp/rocket-bit-program
lhd sim sim/supervisor_program.prp --workdir /tmp/rocket-supervisor
lhd sim sim/local_interrupts.prp --workdir /tmp/rocket-local-irqs
lhd sim sim/supervisor_interrupts.prp --workdir /tmp/rocket-supervisor-irqs
lhd sim sim/supervisor_csrs.prp --workdir /tmp/rocket-supervisor-csrs
lhd sim sim/user_program.prp --workdir /tmp/rocket-user
lhd sim sim/rvc_profiles.prp --workdir /tmp/rocket-rvc
lhd sim sim/asid_program.prp --workdir /tmp/rocket-asids
lhd sim sim/vm_depth_program.prp --workdir /tmp/rocket-vm-modes
lhd sim sim/vm_depth_walk.prp --workdir /tmp/rocket-vm-walk
lhd sim sim/paged_program.prp --workdir /tmp/rocket-paged-program
lhd sim sim/translation_cache.prp --workdir /tmp/rocket-translation-cache
lhd sim sim/pte_walks.prp --workdir /tmp/rocket-pte-walks
lhd sim sim/pte_refill.prp --workdir /tmp/rocket-pte-refill
lhd sim sim/page_table_walk.prp --workdir /tmp/rocket-page-walk
lhd sim sim/pmp_registers.prp --workdir /tmp/rocket-pmp-registers
lhd sim sim/trigger_profiles.prp --workdir /tmp/rocket-trigger-csrs
lhd sim sim/debug_program.prp --workdir /tmp/rocket-debug-program
lhd sim sim/trigger_program.prp --workdir /tmp/rocket-trigger-program
lhd sim sim/pmp_profiles.prp --workdir /tmp/rocket-pmp-profiles
lhd sim sim/pmp_boundary.prp --workdir /tmp/rocket-pmp-boundary
lhd sim sim/page_table_dcache.prp --workdir /tmp/rocket-walk-dcache
lhd sim sim/page_table_sram.prp --workdir /tmp/rocket-page-sram
lhd sim sim/scratchpad_geometry.prp --workdir /tmp/rocket-scratchpad
lhd sim sim/icache_geometry.prp --workdir /tmp/rocket-icache
lhd sim sim/embedded_registers.prp --workdir /tmp/rocket-embedded
lhd sim sim/csr_profiles.prp --workdir /tmp/rocket-csr
lhd sim sim/branch_program.prp --workdir /tmp/rocket-branches
lhd sim sim/cache_lanes.prp --workdir /tmp/rocket-byte-lanes
```

The boot test feeds a complete instruction-cache line over TileLink and checks retirement after dependent scratchpad stores, loads and branches in four configurations. The direct RV64 pipeline test also checks compressed loads, stores, word arithmetic and the architectural XLEN in `misa`. The LFSR test below measures throughput separately. The historical equivalence results describe the earlier fixed-width implementation.

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

In the November 9 version, RocketTile still carried individual PMP fields. The current tile passes one table to the instruction and data checkers. The earlier RVCExpander table fold doubled the line count and was dropped.

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

### Importing Rocket alongside BOOM

The two packages keep the original module filenames. An import such as
`import("PTW.PTW")` resolves relative to the file containing it.
Use the package-aware LiveHD compiler when building the combined design.

The maintained tile also accepts a compile-time configuration record.
`RocketConfig.tiny` preserves the generated RV32 multiplier, and
`RocketConfig.earlyMul` enables the upstream `mulEarlyOut` option.
The [multiplier test](sim/mul_profiles.prp) exercises both with two
independent early-out instances.
