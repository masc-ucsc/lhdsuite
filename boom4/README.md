# BOOM v4

The tile entry point is `pyrope/BoomTile.prp`. Its relative imports reach the
five subsystem directories. `exe` corresponds to upstream `v4/exu`.
`verilog/filelist.f` names the complete SmallBoomV4Config tile RTL, including
its memory models. Its entries resolve relative to the filelist with `-F`.
The RTL comes from the firtool-1.75.0 Chipyard elaboration recorded in
`../boom/BUILD`. Source annotations identify modules from the BOOM generator.
Shared Chisel and Rocket Chip support cells reside with their consumers or in
`util`.

## Configure a tile

Bind the compile-time record to `BoomTile<C=...>`. For example, a parent beside the
BOOM4 directory can derive a three-wide core with its own protection settings and
shared predictor geometry.

```pyrope
const config = import("boom4/common/pyrope/BoomConfig")
const presets = import("boom4/common/pyrope/BoomPresets")
const tile = import("boom4/pyrope/BoomTile.BoomTile")
comptime const core = config.params<B=presets.large>(
  nPMPs=16, nLocalInterrupts=4, ftq=config.fetchTargetQueue(nEntries=48), alpha21264BPD=true)
```

Instantiate `tile<C=core>` once per hart and supply its hart ID. `params()` starts
from Small. `params<B=core>(...)` can refine the record again. Derived metadata,
history and TileLink source widths follow the final settings. A custom predictor
can supply its Pyrope bank module via `branchPredictor`. The bank receives one
physical fetch bank and its training update and returns three prediction stages
and FTQ metadata. A Medium tile using the example bank completed the 256-line memory walk. [Example predictor](ifu/sim/fixtures/LastTargetBank.prp)

The coherent example binds four records to the same tile and forwards TileLink
probes and dirty releases. The tile uses a 32-bit physical address and 64-bit external TileLink data. Its frontend supports the four- and eight-slot fetch widths of the supplied v4 presets. Its regression also runs with one, two and three
populated BOOM sockets. [Mixed SoC configurations](../mixed_soc/pyrope/TileProfiles.prp)

The Pyrope port starts from the reachable `../boom/pyrope2` small-tile
implementation. `common/pyrope/BoomConfig.prp` defines the supported tile
parameters. The `cs152BaselineCore` preset uses the upstream single-lane teaching core’s four-entry ROB, 33 integer registers, disabled predictor and RAS, and its four issue-queue sizes. It inherits the upstream 32-way data TLB. `common/pyrope/BoomPresets.prp` supplies the Medium, Large, Mega, Mega Tapeout and Giga resource records. The Medium, Large, Mega, Mega Tapeout and Giga execution widths run complete tiles with the current LSU. The coherent system runs complete tiles with one, two, five and three dispatch lanes on harts 12–15 respectively. The harts have one integer ALU per dispatch lane. Hart 14 has two FP issue ports and each other hart has one. Hart 14 has three memory issue ports. Each other hart has two. The five-wide hart uses two address generators. All four harts have one unique unit. The issue queues support a configurable number of slow entries.
Column issue uses one queue per ALU. Large and Giga rotate dispatch across three and five columns. Mega Tapeout dispatches one operation per column using the integer rename allocation and configures a four-stage multiplier and registers address generation. The multiplier test exercises latencies one through five, including signed high products, bubbles and flushes. The optional LSU load-to-store-data path matches younger integer stores by physical source and verifies the load generation at writeback.

The upstream three-wide CS152 default assigns all 32 ALU issue slots to the slow region. BOOM requires three fast slots to accept a dispatch row. Its eight-entry fetch buffer also fails the upstream divisibility requirement for a three-wide core. `BoomPresets.cs152Default()` reproduces that upstream elaboration error. The profile checker runs `cs152Default(numSlowAluEntries=28, fetchEntries=12)`, which leaves four fast slots and four complete fetch-buffer rows. Mega Tapeout also exposes the upstream shared cache/predictor port switch via `megaTapeoutCore(singlePorted=false)`.

The instruction TLB takes a configuration record such as `iTLB=config.instructionTLB(nSets=2, nWays=6, nSectors=2, nSuperpageEntries=3)`. Adjacent base pages share a tag, each set has its own replacement state, and superpages share a separate associative table. The two-wide mixed-system hart uses this geometry. [Translation and invalidation test](ifu/sim/instruction_tlb.prp)

The page-table walker accepts `nL2TLBEntries` and `nL2TLBWays`. Zero entries bypass the cache. Enabled caches store page permissions and global status per way, use tree PLRU on hits, check parity and support address, ASID and full invalidation.

The optional A and F/D extensions appear in `misa` and control instruction legality. An integer-only configuration omits the FP issue and execution pipeline, FP rename state and integer-to-FP conversion datapath. The MISA program reads the configured bits and uses them to select its first data-cache acquire. `haveBasicCounters` controls access to the basic counter CSRs, and `enableBPDHPMs` enables the five predictor-source groups of branch, JAL and JALR counters.

Set `enableCommitLogPrintf` or `enableBranchPrintf` to record each lane’s retired instructions or control transfers. Commit logging takes precedence when both are enabled. `enableMemtracePrintf` independently records committed memory operations. Pipe the native `lhd_simrt` output from `boom_tb.prp` through `python3 boom4/sim/retirement_log.py` to render the upstream text fields. Custom drivers can read the registered `logEvents` and `memEvents` ports on each tile.

Pass a `BimCounters.params(nSets, nCols, singlePorted, useFlops, slow)` record as `bimTable` for the BOOM2 or TAGE-L direction predictor. FastTAGE uses `fastBimTable` and `slowBimTable` for its two banks. Each bank trains four saturating counters per fetch group and forwards the last two updates. [BIM geometry regression](ifu/sim/bim_geometry.prp)

Configure the set-associative target banks with `btbTable`, `fastBTB` or `slowBTB`. Each takes a record with the set and way counts, signed offset width, extended-target depth and flop-storage switch. The slow bank has its own `slowBTBSinglePorted` switch. The flop-backed bank stores full jump targets on writes, including offsets that exceed the inline range. The corresponding upstream flop-backed extended-target array has no write assignment. For the fully associative micro-BTB, `microBTB` selects the number of ways, tag width and whether a branch and jump can keep distinct targets. FastTAGE exposes its micro-BTB way and tag counts separately. [High-address target and storage regression](ifu/sim/target_geometry.prp)

Set `pgLevels` to 3, 4 or 5 for Sv39, Sv48 or Sv57. A deeper walker accepts the lower SATP modes. The supervisor regression boots in machine mode, enables PMP and translation, executes MRET, and checks the result of a dependent load and add at a high virtual PC. Instruction and data breakpoints use the configured virtual address width. The data TLB sizes its four-page sectors from `dTLBSets * dTLBWays`. [Supervisor program](sim/virtual_memory.S)

As in the BOOM v4 source, `useRVE` changes the base-extension indication in `misa`, and `useSCIE` has no execution-unit consumer. These fields do not qualify RV64E instruction compliance.

With `useNMI=true`, a tile accepts a resumable interrupt and separate interrupt and nested-exception vectors. Its NMI CSRs use the addresses in this Chipyard revision. The platform driver checks the handler's integer writeback and the interrupted loop's resumption after MNRET.

`trace=true` exposes a registered retirement event for each decode lane. Bits 0, 1–64, 65–96 and 97–160 hold validity, the sign-extended PC, the instruction and writeback data. `traceStatus` carries privilege and lane-zero trap information. `enableTraceCoreIngress` independently enables the RISC-V trace groups, with retirement, last size, instruction type and PC in bits 0, 1, 2–5 and 6–45. `traceStall` stops ROB retirement. The raw CSR time and ROB empty state are available as `traceTime` and `traceEmpty`. [Platform program](sim/platform_tb.prp)

A tile with `usingRoCC=true` exposes accelerator commands and accepts responses, busy and interrupt signals. `numRXQEntries` and `numRCQEntries` size the speculative execute queue and in-order response queue. The execute queue holds commands until the ROB point of no return. The whole-tile test uses three execute entries and five response entries, applies command backpressure, delays a response and checks a dependent instruction retired with 17. [Accelerator program](sim/rocc_tb.prp)

The D-TLB applies `haveCFlush` to the write-permission check on a flush request, including both lookup ports. The misalignment check follows the memory command's actual write classification.

Instruction and data breakpoints share `nBreakpoints` trigger entries and machine/supervisor context matching. The whole-tile breakpoint test programs an execute trigger and distinguishes the trap handler from ordinary execution using its data request.

Each tile accepts zero through sixteen PMP entries and zero through 48 local
interrupt inputs. Local interrupt zero corresponds to cause 16. Machine and
supervisor context CSRs use independently configurable widths, with zero
omitting the CSR. The optional debug unit accepts an external debug request and implements debug-mode CSR access. With `misaWritable`, clearing A makes LR.D illegal, clearing F also clears D, and clearing C changes the EPC alignment mask. An unaligned next instruction suppresses a write that would clear C. `useAtomicsOnlyForIO` controls LR/SC eligibility in cached
memory. `enableConservativeSNI` gates speculative address generation and
issue relative to the ROB head and point of no return. `integerDivide()`
configures divider unrolling, early out and its granularity.

The immediate file and its free list use `numImmPhysRegisters`. The tag width also determines which signed immediates travel inline through issue. The mixed system exercises 12-, 32- and 48-entry files. The FP configuration selects equal single- and double-precision FMA latencies of at least three cycles and enables or disables divide and square root per tile.

A profile can supply `issueParams` as a sequence of four queues tagged with `IQ_MEM`, `IQ_UNQ`, `IQ_ALU` and `IQ_FP`, in any order. Select `useMatrixIssue` per queue to keep entries stationary and arbitrate with a registered age matrix. `queue<B=presets.large.alu>(useMatrixIssue=true)` preserves the other queue settings. The matrix regression checks the oldest eligible operation after a physical slot is reused.

Each queue takes its entry count, dispatch width, issue width and full or
partitioned issue-selection policy from the configuration. The queues compact
multiple incoming instructions in program order. Each issue port supplies its
own function mask. The integrated Small execution cluster binds two memory ports
and one port each for integer ALU, unique and FP operations. The configured TAGE tables instantiate
one implementation with configurable row counts, history lengths, tag widths,
aging period and port policy. The frontend selects TAGE-L, FastTAGE, BOOM2 BIM/BTB/gshare, Alpha21264 or the BOOM reference software predictor model. The default FastTAGE preset combines a 24-way micro-BTB, fast and slow BIM tables, fast and slow BTBs, and six 128-row tagged tables. The software model implements the upstream C++ predictor’s 256 bimodal counters and 32-entry FIFO target table in Pyrope, shared by both fetch banks of a tile.
Alpha21264 uses 2,048-row local and global history-indexed tables and a
128-row tournament selector. The fetch target queue carries the speculative
local history snapshot along with the direction counters for training and repair. BOOM2 uses a configurable tagged table with a
default 16-bit history. The FTQ stores the configured metadata width per bank. The defaults are 120 bits for TAGE-L and FastTAGE, 45 for BOOM2, 64 for Alpha21264 and one for the software predictor. Global history width follows the predictor preset or an explicit override. Alpha21264 also accepts independent local-history depth and width, including a zero-set null history.
With two banks, prediction lanes follow fetch order and metadata stays in physical bank order. Global prediction enable, BTB fast repair
and RAS top repair are independently configurable. The frontend supports the slow-BTB redirect and global-history stall-repair options. Calls, returns, FTQ replay
and backend redirects wrap at the configured return-stack depth. The FTQ regression checks seven-bit return-stack indices with 96 entries.
Zero disables return prediction. The FTQ stores PCs, control-flow information
and predictor snapshots at its configured depth. Its 12-, 16-, 32- and
40-entry tests check every resident row and wraparound. The tile derives FTQ and predicate tags from the configured depth throughout the fetch, execution and cache pipelines. The coherent example uses 16, 32, 40 and 12 entries. Short forward branch predication is independently selectable per tile through `enableSFBOpt`.
TAGE-L and FastTAGE accept a list of table geometries. The FTQ layout derives its provider and allocation fields from that list. A directed test trains banks containing one, three and nine tables. The six-table rewrite matched the preceding Pyrope implementation on every output over 32,768 cycles.

The tile supports configurable fetch-buffer capacity. Its shared fetch queue supports
partial decode rows and simultaneous masked enqueue and row dequeue. Its packet input supports one or two fetch banks and reconstructs straddling instruction PCs at either bank boundary. The decoder
accepts a row of independently expanded instructions, with per-lane CSR decode
flags and a shared interrupt input. The CSR file checks all lanes against the same privilege state and counts every architectural retirement. Full equivalence against the preceding scalar Pyrope decoder covers all 32 instruction bits, privilege state and counter permissions. A two-lane test follows a load and a store
from sparse fetch packets through instruction decode.
The LSU uses one dispatch allocator for loads and stores. Its tests exercise
five lanes against a 24-entry queue under both fullness lookahead policies,
including exceptions, partial acceptance and wrap-generation changes. Store
forwarding selects the youngest matching entry across wrap. The integrated
LSU sizes the load and store queues independently. Small, Medium, Large and Mega/Giga use 8, 16, 24 and 32 entries respectively. The mixed tile on hart 15 has 24 load entries and 12 store entries. Its five-lane driver issues two rows of interleaved loads and stores, fills the load queue, and retires three loads and two stores together across pointer wrap. Load and store queues use the same
107-field micro-op record with independent updates for the branch mask,
destination and exception. Both use the Chisel circular age interval to
select candidates at wraparound. The integer load-use path supports the
five-cycle Small policy and the four-cycle Mega policy, including speculative
wakeup, cancellation and integer writeback.

The I-cache supports one or two interleaved banks, configurable ways and sets, single-port operation and delayed reads. The wide frontend combines pairs of 64-bit TileLink D beats for a 128-bit refill. The two-bank cache test inserts gaps between bus beats and fetches across a cache-line boundary. Hart 14 uses this path. A complete frontend test checks consecutive instructions and their PCs at the upstream Medium, Large, Mega and Giga fetch/decode widths. The ROB instantiates one bank per dispatch lane and wraps
at the configured row count. The complete ROB driver exercises the 64-, 96-,
128- and 130-entry upstream geometries, in-order commit, rollback, flushes,
FP flags, partial dispatch and both point-of-no-return policies. Integrated tiles derive ROB tags from their bank and row counts. The heterogeneous system configures 32, 64, 130 and 24 entries. Branch recovery masks, checkpoints and branch register addresses follow maxBrCount throughout rename, issue, execution, the LSU and cache miss queues. Small uses 8 tags, Medium 12, Large 16 and Mega, Mega Tapeout and Giga 20. The D-cache uses the upstream bank count, set count, associativity and physical row width for each named preset. Large, Mega and Giga use eight ways and 128-bit rows. Mega Tapeout uses 128 sets, four ways, 128-bit rows and four single-ported banks. The cache transfers 64-bit TileLink beats. The data TLB has 8, 16 or 32 ways according to the preset. Four base-page translations share each tag, with a tree pseudo-LRU replacement policy. The existing superpage and special-entry paths remain active. Mega, Mega Tapeout and Giga also enable the next-line data prefetcher. It checks cacheability, shares the metadata read port with lower priority than demand traffic, and holds prefetched lines in the miss file. Small and Medium have two miss-status handling registers (MSHRs), Large has four, and Mega, Mega Tapeout and Giga have eight. Native TileLink allocates one source ID per MSHR. The older mixed packet fabric negotiates two cached source IDs per tile and retains each ID through the last grant beat. An eight-MSHR test filled the file before accepting any acquire, returned eight lines in reverse source order, checked all load completions and reused a slot. Mega, Mega Tapeout and Giga elaborate two address generators. Two translations can read the same TLB state each cycle. An independent cache hit can complete on a second integer register-file write port. Conflicts, faults, FP loads and loads with older stores retry through the primary pipe. The four-load program checks the dependent sum and observes simultaneous writebacks. The rename map, busy table, physical register allocator and branch-tag allocator
accept multiple lanes. Integer, FP and immediate rename share one free-list
implementation. A rotating banked allocator uses that same implementation per bank. Their
standalone drivers exercise per-lane snapshots, writeback bypass, speculation
cancellation, tag exhaustion and recovery. The shared integer and FP rename stages handle partial dispatch and in-row bypass. Immediate rename preserves inline operands alongside physical immediate registers. A five-lane test checks a 48-entry immediate file, stalls and killed rows. Dispatch propagates hazards in program order and supports both superscalar and single-snapshot policies. Its five-lane driver checks 65,536 rows with holes, unique instructions, unavailable resources and redirects.
Standalone drivers exercise two through five lanes and register files above 64 entries.
The dispatch operand selector widens each integer and FP tag at its own lane boundary. A mixed-type, five-lane row checks 6-bit FP and 8-bit integer tags, CSR source passthrough and short-forward-branch predicate routing. Immediate, predicate and branch files share the same fully ported register file with configurable read and write counts. FTQ release picks the youngest retiring lane with exceptions and early system-PC requests taking priority.

Each tile binds the capacity, bank count and read ports of its integer and FP
register files independently. Integer-to-FP conversions align results, flags and branch recovery at the configured latency. The response queue holds six more entries than the conversion latency, as in Chisel.
Micro-ops carry the larger of the integer and FP physical register address widths. Each register file uses its own address width. The four coherent harts use 52/48, 80/64, 144/128 and 64/56 integer/FP register counts. The Small tile has a four-instruction fetch and
single-instruction decode.

The CSR file supports zero through 29 hardware performance counters. Medium selects six and Small selects two. Each tile can configure the initial machine trap vector with `mtvecInit` and its writeability with `mtvecWritable`.

## Reproduce the checks

Run from the suite root with the local LiveHD build on PATH. The profile checker runs single tiles, homogeneous and heterogeneous meshes, and the subsystem simulations.

```sh
python3 mixed_soc/scripts/check_profiles.py --lhd ../livehd/bazel-bin/lhd/lhd
bazel test //mixed_soc:coherent_harts //bench:mixed_soc_sim_pyrope --override_module=livehd=../livehd
lhd sim boom4/pyrope/BoomTile.prp boom4/sim/boom_tb.prp +cycles=100000 \
    --set compile.unknown_zero=true --set sim.init_zero=true --set sim.vcd=false --workdir /tmp/boom4-small
lhd_simrt /tmp/boom4-small/sim --init-zero +cycles=100000
lhd sim boom4/ifu/sim/fetch_rows.prp --set compile.unknown_zero=true --workdir /tmp/boom4-fetch-rows
lhd sim boom4/ifu/sim/fetch_decode.prp --set compile.unknown_zero=true --workdir /tmp/boom4-fetch-decode
lhd sim boom4/ifu/sim/cache_profiles.prp --set compile.unknown_zero=true --workdir /tmp/boom4-cache
lhd sim boom4/exe/sim/rob_rows.prp --set compile.unknown_zero=true --workdir /tmp/boom4-rob
lhd sim boom4/exe/sim/rename_rows.prp --set compile.unknown_zero=true --workdir /tmp/boom4-rename
lhd sim boom4/exe/sim/queue_profiles.prp --workdir /tmp/boom4-queues
lhd sim boom4/ifu/sim/gshare_training.prp --set compile.unknown_zero=true --workdir /tmp/boom4-gshare
lhd sim boom4/util/sim/find_one.prp --workdir /tmp/boom4-priority
verilator --cc --exe --build -j 4 -Wno-fatal -DSYNTHESIS --top-module BoomTile \
    -F boom4/verilog/filelist.f --Mdir /tmp/boom4-verilator "$PWD/boom4/sim/boom_tb_verilator.cpp"
/tmp/boom4-verilator/VBoomTile --cycles 100000
```

The default Pyrope and Verilator runs both print `sum=6034797118373429972`.
The cache driver checks returned refill data for each combination of the two
port and timing flags. The issue driver checks backpressure with zero and four
slow entries. The priority search driver checks all 32 five-bit masks in both
priority directions, including the padded empty-mask result.
