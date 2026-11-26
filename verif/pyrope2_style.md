# Pyrope2 style scan

Source-only scan of all 13 `xiangshan/Backend/pyrope2/*.prp` files: **420 suggestions**, no partial parses. `RenameBuffer.prp` accounts for 389; increasing `--max-findings` to 500 emitted all 389. No loop rewrites or equivalence claims are implied by this scan.

```sh
../livehd/bazel-bin/lhd/lhd pyrope style xiangshan/Backend/pyrope2/*.prp --diag-fmt pretty --emit diagnostics:/tmp/pyrope2-direct-bundles/style/xiangshan.jsonl
../livehd/bazel-bin/lhd/lhd pyrope style xiangshan/Backend/pyrope2/RenameBuffer.prp --max-findings 500 --emit diagnostics:/tmp/pyrope2-direct-bundles/style/rename-all.jsonl -q
```

| File | Suggestions |
| --- | ---: |
| AgeDetector.prp | 2 |
| Arbiter16_LqPtr.prp | 1 |
| enqueue_pointers.prp | 0 |
| FreeList_3.prp | 13 |
| FreeList_5.prp | 14 |
| RenameBuffer.prp | 389 |
| RobEnqPtrWrapper_N32.prp | 0 |
| RobEnqPtrWrapper.prp | 0 |
| snapshot_queue.prp | 1 |
| SnapshotGenerator_1.prp | 0 |
| SnapshotGenerator_2.prp | 0 |
| SnapshotGenerator_3.prp | 0 |
| SnapshotGenerator.prp | 0 |

Largest reported RenameBuffer block: 73 statements repeated 352 times, lines 90461–116156. Other large candidates include 6 statements repeated 511 times and 4 statements repeated 520 times. Numbered scalar declarations may need conversion to arrays before using loops.

The cleanup prompt now recommends inspecting these findings before and after cleanup, passing typed bundles across internal interfaces instead of pack/unpack adapters, keeping meaningful field names, using selection expressions, and validating at the external top level.
