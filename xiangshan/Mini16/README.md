# xiangshan/Mini16

XiangShan `MinimalRob16Config`: `MinimalConfig` with a 16-entry ROB, added to
`/mada/users/frabieik/XiangShan/src/main/scala/top/Configs.scala`. Widths are the
same as `DefaultConfig` (decode/rename/commit 8), only sizes shrink, so the
port counts match the full XiangShan. It is the XiangShan point of the
Rocket -> BOOM -> XiangShan loop-cleanup ladder; the target cone is `CtrlBlock`
(decode, rename, dispatch, ROB).

## Layout and status (2026-11-09)

| Where | Contents |
|---|---|
| `pyrope2/` | 66 `.prp` files: 23 cleaned modules plus the raw children they instantiate |
| Verilog | `XiangShan/build/rtl_mini16_lhd/` (2,009 `.sv`; `build/mini16.sh` on kaffirlime, then two hand patches: `until` -> `untilv`, `ifdef DUMMY` around the DiffExt instance in the 21 `DummyDPICWrapper_*.sv`) |
| Scratch | `/mada/users/frabieik/pyro_scratch/xs_mini16/<Module>/{base,pyroA,...,ref_sv,work}`, one fold script per step (`rob_fold_*.py`, `rb_fold_*.py`, ...) |

Every step was LEC'd against the previous step and against the module's
Verilog before it was committed (one commit per step).

## Cleaned modules (lines, raw emit -> `pyrope2/`)

| Module | raw | pyrope2 | Steps |
|---|---|---|---|
| RenameBuffer | 46,249 | 3,892 | pyroB-G: allocate matrix, entry write, diff-commit pointers and slots, commit/walk lane reads -> loops |
| DecodeUnitComp | 44,158 | 31,911 | pyroA-D |
| Rob | 37,828 | 3,460 | pyroA-BG (59 commits): entry next state, debug blocks, commit/deq lanes, difftest lanes, writeback decode, enqueue matrix -> loops; dead presets and temps removed |
| Dispatch | 34,261 | 14,151 | pyroA-I |
| Rename | 16,644 | 12,816 | pyroA |
| LFST | 13,819 | 11,143 | pyroA (robIdx write loop) |
| DecodeStage | 7,612 | 4,575 | pyroA |
| BusyTable_2 | 5,425 | 1,391 | pyroA-B |
| VTypeBuffer | 5,213 | 879 | pyroA-H |
| BusyTable | 4,730 | 982 | pyroA-B |
| LsqEnqCtrl | 4,382 | 686 | pyroA-D |
| FusionDecoder | 4,284 | 528 | pyroA-D, incl. new children FusionMatch (196) and FusionLaneOut (120) |
| BusyTable_1 | 3,843 | 1,122 | pyroA-B |
| StdFreeList_1 | 2,895 | 362 | pyroA-D |
| RegCacheTagModule | 2,892 | 1,071 | pyroA |
| DataModule__64entry_16 | 2,832 | 41 | pyroA-C |
| MEFreeList | 1,703 | 284 | pyroA-B |
| RegCacheTagModule_1 | 1,364 | 471 | pyroA |
| DataModule__64entry | 1,188 | 42 | pyroA |
| StdFreeList_3 | 1,008 | 348 | pyroA-B |
| BusyTable_3 | 991 | 501 | pyroA |
| StdFreeList | 985 | 348 | pyroA-B |
| StdFreeList_2 | 779 | 349 | pyroA-B |

Still raw: RenameTable, RenameTable_1..4, RenameTableWrapper, CompressUnit,
ExceptionGen, VecExceptionGen, VlBusyTable, RegCacheTagTable, the
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
| case17 | SSIT 1024-entry debug state: loop fold times out. Alternative: delete the dead debug state (owner decision) |

## Not done

- No sim driver for Mini16, and it is not in the bench.
- DecodeUnitComp (31,911 lines) still has large repeated blocks.
