# xiangshan/Mini16

XiangShan `MinimalRob16Config`: `MinimalConfig` with a 16-entry ROB, added to
`/mada/users/frabieik/XiangShan/src/main/scala/top/Configs.scala`. Widths are the
same as `DefaultConfig` (decode/rename/commit 8), only sizes shrink, so the
port counts match the full XiangShan. It is the XiangShan point of the
Rocket -> BOOM -> XiangShan loop-cleanup ladder; the target cone is `CtrlBlock`
(decode, rename, dispatch, ROB).

## Layout and status (2026-11-11)

| Where | Contents |
|---|---|
| `verilog/` | the CtrlBlock cone of the Verilog below (88 `.sv` + `filelist.f`) |
| `pyrope/` | that cone emitted by `lhd compile verilog --top CtrlBlock` (raw, 88 `.prp` + `manifest.json`) |
| `pyrope2/` | the same tree with the cleaned modules swapped in (90 `.prp`: FusionDecoder adds FusionMatch and FusionLaneOut) |
| `sim/` | `xs_mini16_tb.prp` and its Verilator twin `xs_mini16_tb_verilator.cpp` (see Simulation) |
| Verilog | `XiangShan/build/rtl_mini16_lhd/` (2,009 `.sv`; `build/mini16.sh` on kaffirlime, then two hand patches: `until` -> `untilv`, `ifdef DUMMY` around the DiffExt instance in the 21 `DummyDPICWrapper_*.sv`) |
| Scratch | `/mada/users/frabieik/pyro_scratch/xs_mini16/<Module>/{base,pyroA,...,ref_sv,work}`, one fold script per step (`rob_fold_*.py`, `rb_fold_*.py`, ...) |

Every step was LEC'd against the previous step and against the module's
Verilog before it was committed (one commit per step).

## Cleaned modules (lines, raw emit -> `pyrope2/`)

| Module | raw | pyrope2 | Steps |
|---|---|---|---|
| RenameBuffer | 46,249 | 3,892 | pyroB-G: allocate matrix, entry write, diff-commit pointers and slots, commit/walk lane reads -> loops |
| DecodeUnitComp | 44,158 | 31,911 | pyroA-D |
| Rob | 37,828 | 3,458 | pyroA-BH (60 commits): entry next state, debug blocks, commit/deq lanes, difftest lanes, writeback decode, enqueue matrix -> loops; dead presets and temps removed; pyroBH bounds array indices for the new lhd address rule |
| Dispatch | 34,261 | 14,151 | pyroA-I |
| Rename | 16,644 | 12,816 | pyroA |
| LFST | 13,819 | 11,143 | pyroA (robIdx write loop) |
| DecodeStage | 7,612 | 4,575 | pyroA |
| BusyTable_2 | 5,425 | 1,391 | pyroA-B |
| VTypeBuffer | 5,213 | 879 | pyroA-H |
| BusyTable | 4,730 | 982 | pyroA-B |
| ExceptionGen | 4,383 | 268 | pyroA: rewritten from the Chisel intent (enqueue lane loop, writeback group/stage oldest-select helpers, packed 131-bit info kept so state pairs) |
| LsqEnqCtrl | 4,382 | 686 | pyroA-D |
| FusionDecoder | 4,284 | 528 | pyroA-D, incl. new children FusionMatch (196) and FusionLaneOut (120) |
| BusyTable_1 | 3,843 | 1,122 | pyroA-B |
| StdFreeList_1 | 2,895 | 362 | pyroA-D |
| RegCacheTagModule | 2,892 | 1,071 | pyroA |
| DataModule__64entry_16 | 2,832 | 41 | pyroA-C |
| MEFreeList | 1,703 | 284 | pyroA-B |
| RegCacheTagModule_1 | 1,364 | 471 | pyroA |
| RegCacheTagTable | 1,111 | 126 | pyroA: rewritten from the Chisel intent; wakeup -> write port, cancel and read-port logic are loops, `loadShouldCancel` is a small comb; the two RegCacheTagModule children are unchanged |
| VlBusyTable | 1,310 | 194 | pyroA: rewritten from the Chisel intent; one loop builds the per-preg update, one flop per preg kept by name (a `[32]U1` reg array came back REFUTED with the state unpaired); dead perf counters and loadDependency (vl has no load cancel) dropped |
| DataModule__64entry | 1,188 | 42 | pyroA |
| TraceBuffer | 1,029 | 62 | pyroA: rewritten from the Chisel intent; need-PC / iretire-fold lane loop, enqueue loop into the 8-entry ring, 3-block dequeue loop |
| StdFreeList_3 | 1,008 | 348 | pyroA-B |
| BusyTable_3 | 991 | 501 | pyroA |
| StdFreeList | 985 | 348 | pyroA-B |
| StdFreeList_2 | 779 | 349 | pyroA-B |
| DataModule_BackendPC_8entry | 591 | 14 | pyroA: rewritten from the Chisel intent; 16 read ports with write bypass as one loop, 1 write port |
| VecExceptionGen | 521 | 171 | pyroA: rewritten from the Chisel intent; each instruction list is one loop over its keys, three small helpers (notAlign, regPow, nfToLmul) |

Still raw: RenameTable, RenameTable_1..4, RenameTableWrapper, the
SnapshotGenerator/DelayReg/indexedLSUopTable children. The other CtrlBlock
modules are ranked in `pyro_scratch/xs_mini16/style_rest/RANKING.txt`.

## LEC status

- **Per step:** every committed step is PROVEN-full vs the previous step, and
  most vs the module's Verilog too. For the big ones the direct check vs the
  Verilog times out, and they are proven only through the chain:
  - VTypeBuffer: the steps from pyroD on (64-entry buffer write as a loop)
    time out vs the Verilog (4 h on the final pyroH); every step is PROVEN-full
    vs the one before.
  - RenameBuffer: pyroG vs the Verilog times out (2 h); pyroF vs the Verilog
    and pyroG vs pyroF are PROVEN-full.
  - Rob: proven vs the Verilog after each step, with the checker's export
    harness for the debug state that is unobservable from the outputs.
- **Whole CtrlBlock** (cleaned modules + raw rest vs the Verilog, 4 h,
  2026-11-06): 44 of 70 defs proven, 0 refuted, the top TIMEOUT. The raw emit
  alone proves 68 of 70 (2026-10-29), so the cleaned loops are what makes the
  big blocks slow for the solver (jose_repro case12).
- **Rob subtree** (2026-11-07): Rob PROVEN with its children boxed (21 min);
  VTypeBuffer and RenameBuffer TIMEOUT, so the subtree as a whole rests on
  their step chains.
- Only PROVEN counts on these modules: planted bugs come back TIMEOUT, not
  REFUTED.

## Blocked (repros in `pyro_scratch/jose_repro_20261102/`)

| Case | What |
|---|---|
| case12 | big reg-array loop folds (VTypeBuffer, RenameBuffer) time out vs the Verilog |
| case16 | RenameTable difftest chain (520 ports x 32 entries): every loop form times out; RenameTable_1/_2 folds are built and wait on this |
| case25 | DecodeUnitComp pyroE (17 one-hot decode folds, 31,911 -> 29,820 lines): a new loop between existing ones renumbers `__loopN`, so the later loops stop pairing and LEC times out (also case2). Built as single-fold steps `pyroE1..17` in scratch, waiting on the fix |
| case28 | lhd sim rejects a false (bit-level acyclic) cycle through loop arrays: Rob pyroN packs each ROB entry's fields into one `[8]U67` word, and one field (`valid`) feeds another (`fflags`). So `pyrope2/` does not simulate; LEC is fine |
| case17 | SSIT 1024-entry debug state: loop fold times out. Alternative: delete the dead debug state (owner decision) |

## Simulation

`sim/xs_mini16_tb.prp` drives `CtrlBlock` as a throughput benchmark and a
cross-language checksum oracle, not functional coverage. Each cycle the
frontend offers 8 random ADDI/ADD instructions; the issue queues and the LSQ
accept; writeback ports 1-4 sweep the ROB indices (4 per cycle), so the ROB
keeps retiring (~1.5 instructions per cycle). The frontend `trigger` field
must be 15 (TriggerAction.None): 0 means "breakpoint exception", which turns
every uop into an exception that never reaches an issue queue.

Needs `--set sim.unknown_zero=true --set sim.init_zero=true` (reset-free
state reaches the outputs; Verilator zero-fills). With those, the same
checksum comes from lhd sim on `pyrope/`, lhd sim on the Verilog (`lg:`) and
Verilator, at 2, 5, 50, 1,000 and 20,000 cycles:

    xs_mini16: cycles=1000 sum=1660443741802788855

Measured on kaffirlime (lhd 5cba85788, 16 jobs, 2026-11-10):

| | lhd sim `pyrope/` | lhd sim Verilog | Verilator |
|---|---|---|---|
| build | 1,311 s setup (`inou.cgen.sim` 1,057 s) + 74 s C++ | 179 s compile + 877 s setup | 300 s |
| 20,000 cycles | 23.7 s | 22.2 s | 27.4 s |

After a testbench-only edit, replaying the workdir (`cd w/sim && lhd sim`)
took 308 s instead of 1,385 s.

Not a bench core yet: each lhd sim leg costs 15-22 min of codegen (xs_rob's
sim was disabled at 5 min), and `pyrope2/` is blocked by case28.

## Not done

- Mini16 is not in the bench (see Simulation).
- DecodeUnitComp (31,911 lines) still has large repeated blocks.
