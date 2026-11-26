# RenameBuffer loop cleanup

The rewritten `xiangshan/Backend/pyrope2/RenameBuffer.prp` replaces generated
repetition with allocation, commit/walk, pointer, exception-map, and debug loops.
It compiles and has zero `lhd pyrope style` suggestions. **Full top-level LEC
against the matching RTL is inconclusive**: the latest attempt was stopped after
180 seconds with no counterexample. The starting source had an unbounded proof;
that proof has not yet been re-established for the rewrite.

| Source | Lines | Whitespace-delimited words | Bytes |
| --- | ---: | ---: | ---: |
| Starting Pyrope | 116,600 | 1,418,448 | 9,815,423 |
| Cleaned Pyrope | 247 | 1,537 | 13,003 |
| Matching Verilog | 138,083 | 633,958 | 8,239,740 |

Counts use `len(text.split())`, with the same single-module file scope for each
source. Both new combinational helpers and all constants are in the counted
Pyrope file. Existing SnapshotGenerator/snapshot_queue files are unchanged and
excluded from both Pyrope snapshots. Test/checker files are not design helpers.
This removes repeated logic; it is not whitespace compression. Formatting was a
separate final step, proven equivalent to the pre-format graph.

The starting file exactly matches commit
`894526b6e47cca7a4686931cda1bfb90d8d22a39`. The matching reference is
`xiangshan/Backend/verilog/RenameBuffer.sv`, with `SnapshotGenerator.sv`.
`../xs/repo/src/main/scala/xiangshan/backend/rob/Rab.scala` and backend/rename
provided design intent (RabSize 352, rename/commit width 8, MaxUopSize 65).
The checked-in RTL remains the behavior reference where its elaboration differs
from current Chisel.

The external interface, old-state memory reads, request-lane write priority,
reset behavior, unreset storage, nine-bit counter wrapping, and invalid output
data behavior are retained. Commit selection remains a masked OR, preserving
multi-hot behavior. The 520 debug lanes deliberately subtract 352 once and
truncate to nine address bits; invalid addresses retain the RTL entry-zero
fallback. They do not use modulo 352. Only unobservable `currentVdIdx` and
`vcfgPtrOH` state was removed.

Validation:

- Fresh compilation passes; the repeat compilation has 8 cache hits, 0 misses.
- Exporting and loading a complete precompiled bundle passes. Its LEC against
  the direct cleaned graph is unbounded PROVEN.
- Formatter output versus pre-format graph is unbounded PROVEN.
- Differential simulation passes 2,048 cycles, checking every public output,
  including all 520 debug entries, through allocation, commit, redirects,
  special walk, snapshot recovery, pointer wrap, and exception-map updates.
  Both sides use `sim.unknown_zero=true` and `sim.init_zero=true` for identical
  power-on fill. This simulation does not prove arbitrary initial-state behavior
  or replace the incomplete top-level LEC.
- Full RTL LEC proves SnapshotGenerator, then reaches the 180-second external
  limit with RenameBuffer pending. Earlier intermediate versions produced
  UNKNOWN memory obligations or a solver worker SIGBUS; those are not design
  counterexamples and the SIGBUS cause has not been repaired.
- Compilation still reports three pre-existing generic-bound warnings in
  snapshot_queue, an unnecessary-wrap warning, and two loop-index range
  warnings. No error is suppressed.

A valid loop inside an inlined combinational helper exposed a LiveHD bug:
`inl1_*.valid_count.__loop0` became an undefined callee. Preserving the callee
alone exposed incorrect constant folding of the initial loop accumulator.
`../livehd/upass/runner/upass_runner.cpp` now replays a compact loop's retained
source body through normal inline lowering, including carry invalidation.
The fix applies to compact loops without a runtime activation recurrence.

The small permanent regression is the pair
`../livehd/inou/prp/tests/equiv/loop_helper_priority.prp` and `.v`.
Direct unbounded LEC, the Pyrope/Verilog test, Verilog round trip, six existing
loop regressions, and the uPass runner unit tests pass (nine Bazel targets).
Existing unrelated LiveHD worktree changes were preserved.

Run the retained comparison from the lhdsuite root:

```sh
python3 verif/check_renamebuffer_cleanup.py
# Also retry the external-top proof; a timeout returns nonzero:
python3 verif/check_renamebuffer_cleanup.py --lec --timeout 180
```

The checker stages the pinned original source and current cleaned source in a
fresh temporary directory, keeps logs/result JSON, and never alters the design
or its reference. `--cycles` changes the simulation length. The `--timeout`
limit is per tool invocation.

Detailed results and source/compiler hashes are in
`renamebuffer_cleanup_validation.json`. Exploratory compiler/LEC logs and the
original source snapshot are retained under `/tmp/renamebuffer-cleanup`.
