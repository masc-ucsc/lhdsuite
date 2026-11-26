# RenameTableWrapper cleanup

`xiangshan/Backend/pyrope2/RenameTableWrapper.prp` preserves the generated
wrapper's 203 input leaves and 87 output leaves, including their widths and
bundle structure. It calls the existing `rename_table` implementation directly
for integer, floating-point, vector, v0, and vl mappings.

The shared commit decoder uses loops for the eight retirement/walk lanes and
520 differential lanes. Rename writes override walk writes in each lane;
retirement and differential enables remain independent. The single-entry v0/vl
tables use `ADDRESS_BITS=0`, with no address fields or retained address state. VL has
eight differential ports, selected by the new `DIFF_PORTS` parameter; its default
remains 520 for all existing callers.

The generated `DummyDPICWrapper_Arch*RenameTable` Pyrope bodies are empty combs
with no outputs. Their private delay chains have no observable effect and are
omitted. The external `io_diff_vl_rat` output remains connected to the VL table.

Reference: checked-in `xiangshan/Backend/verilog/RenameTableWrapper.sv` and its
dependency closure, with `-DSYNTHESIS`. Design intent was also checked against
`../xs/repo/src/main/scala/xiangshan/backend/rename/RenameTable.scala`.
This is the fixed, checked-in Backend configuration, not a new configurable
external interface.

## Size

Counts include comments and use whitespace-separated words (`wc -w`). The
closure follows every import, counting each source once; the RTL scope is the
same set of generated module names. The decoder helper is inside the wrapper.

| Scope | Generated Pyrope | Cleaned Pyrope | Matching Verilog |
| --- | ---: | ---: | ---: |
| Wrapper lines | 5,973 | 533 | 12,385 |
| Wrapper words | 73,647 | 1,551 | 48,896 |
| Closure files | 15 | 3 | 15 |
| Closure lines | 72,400 | 715 | 270,041 |
| Closure words | 1,610,165 | 2,707 | 890,390 |

Most closure reduction comes from reusing the previously cleaned table and
snapshot implementations. This change adds the wrapper and extends
`rename_table.prp` with the differential-port count and addressless single-entry
configurations. The existing 5- and 6-bit-address configurations retain their
previous behavior.

## Reproduce

```sh
../livehd/bazel-bin/lhd/lhd sim --setup-only \
  xiangshan/Backend/pyrope2/RenameTableWrapper.prp \
  xiangshan/Backend/sim/xs_renametable_tb.prp --workdir tmp2

python3 verif/check_xs_tables_cleanup.py --module RenameTableWrapper \
  --timeout 600 --memory-gib 16 --bundle --lec
```

The wrapper comparison runs each design separately with identical stimulus and
compares every external output bit on every sampled cycle. It drives concurrent
rename/walk writes, retirement inputs with duplicate destinations, all 520
differential lanes, read holds, snapshots, redirects, and a later one-cycle
reset. Both runs use zero power-on fill. This is simulation evidence, not an
arbitrary-initial-state equivalence proof.

The initially combined two-wrapper test crashed in LiveHD with SIGSEGV; its
generated `compare.prp` is retained by the checker for reproduction. The
separate-run comparison retains the same stimulus and output coverage.

The pre-existing `tmp2` directory contained stale simulation C++ for other
designs, causing host compilation errors in old `__Color_runtime` declarations.
It was preserved as `tmp2.before-wrapper-20260913`; the requested command was
then checked using a fresh `tmp2`.

## Validation status (2026-09-13)

- Both requested setup commands passed. The final fresh cleaned setup took 17.6 s;
  timings varied with concurrent machine load and are not a controlled speed
  comparison.
- The final 1,024-cycle differential test passed: all 87 output leaves matched
  on all 1,022 sampled cycles, including the later resets.
- The unchanged `xs_renametable_tb.prp` builds and runs on both wrappers.
  Both print `cycles=1000 sum=6204314683438792704`.
- Direct compile, incremental compile, LN export, and LN reload passed.
  Direct-versus-reloaded top-level LEC was unbounded PROVEN.
- Final top-level LEC against the original Pyrope reached the 180 s process
  limit without a verdict (peak process-tree RSS: 10.2 GiB). Equivalence remains
  unproven. Two earlier runs of the artificial-address version returned UNKNOWN
  for `Get_mask non-contiguous mask not supported (M1)`.
- The external RTL compile reached the 300 s limit before LEC could start.
  External RTL equivalence therefore remains unproven.
- The wrapper style analyzer reports zero suggestions. Existing
  `snapshot_queue.prp` generic type-bound warnings remain.

The initial trace writer used tuple bit packing inside a test, which the current
sim test-expression evaluator rejects. The checker now records individual
scalar outputs instead, with identical sampled data and cycle coverage.

The first single-entry integration used an artificial one-bit zero address.
The full comparison exposed incorrect VL output in that version: cgen tested
physical-destination bits as addresses after a sparse-mask optimization. The
final implementation carries no synthetic address bits (`ADDRESS_BITS=0`),
matching the original addressless ports; the complete output traces then match.
The final wrapper trace uses explicitly grouped reset predicates; the grouped
and original predicates emit identical C++ and give identical output traces.

Source hashes and structured results: [validation JSON](renametable_wrapper_cleanup_validation.json).
