# Pyrope2 cleanup and three-language compatibility

Verilog is the reference. `pyrope/` is generated from the matching RTL;
`pyrope2/` is the maintained implementation. The acceptance gate is unbounded
**top-level** equivalence, including external port names, widths, directions,
and signedness. Intermediate modules may change. The same simulation driver
and arguments are used on RTL, freshly generated Pyrope, checked-in Pyrope,
and Pyrope2. Bounded results, missing references, and unresolved proofs fail
the checker; the old Pyrope2 snapshot is no longer an acceptance baseline.

## Validation snapshot

The subsequent [if-expression pass](pyrope2_if_expressions.md) records the
expression rewrites and fresh validation for their affected tops. The counts
below describe this earlier compatibility snapshot.

The final matrix covers **26 proved top/configuration combinations**: eleven
matching external tops and fifteen additional parameter configurations. It
contains 107 unbounded LEC results, including repeat, generated-reference,
and precompiled-import legs, plus 42 passing simulation runs and common
interface checks. RenameBuffer passes all 14 checks, including two independent
unbounded Pyrope2-to-RTL proofs.

Of 489 matrix checks, 485 pass. The four remaining failures are missing RTL
configurations, listed below; their Pyrope2 sources compile. This is an
**incomplete** repository-wide compatibility pass until those references are
available. Evidence records source and binary hashes, commands, and logs.

All four mutation checks pass with the final compiler. The final LiveHD
regression run passes **224/224** CLI, LEC, and repaired generic tests. The
earlier full optimized run passed 2,366/2,369; its three failures were the new
generic fixture's hierarchy and two unbounded-type cases. All three were
fixed and pass in the final regression run.

## Word counts

Counts are whitespace-delimited words in all direct design `.prp` files,
including comments and helper modules. The saved pre-pass Pyrope2 snapshot
matches the repository HEAD for these two trees.

| Design | Generated Pyrope | Pyrope2 before this pass | Current Pyrope2 |
|---|---:|---:|---:|
| DINO | 8,685 | 4,991 | 4,999 |
| PicoRV32 | 6,639 | 7,219 | 7,314 |

DINO is 42.4% smaller than generated Pyrope, but this pass added eight words.
PicoRV32 is 10.2% larger than its generated default configuration and this
pass added 95 words. Its Pyrope2 tree also includes configurable multiply and
divide helpers absent from the generated default tree, so that comparison
includes a scope difference. These correctness edits have not reduced words.

## Repairs

- **DINO:** `a_execute_control` was incorrectly declared as a register, adding
  an extra pipeline stage after `pipeA_id_ex_ctrl`. It is now a wire. The CPU
  proves unbounded against RTL and passes the existing architectural program.
- **PicoRV32:** do not instantiate a disabled PCPI arbiter whose only data
  output is entirely unknown. The disabled result remains unknown and its
  valid/wait/write controls remain false. The normal program and both serial
  and fast RV32M programs pass. Instruction-decoder, optional ALU, and PCPI
  register relocation are recorded in `pyrope2/picorv32.match`; LEC proves
  every paired next-state obligation. No module is trusted or ignored.
- **Matched filter:** replace the six separate validity instances with the
  RTL's packed validity pipeline. Give adder instances stable local names and
  record their correspondence in `pyrope2/matched_filter.match`. Correct the
  one-bit multiplication configuration by shifting before sign extraction and
  declaring the complete product width. Remove the unused `valid_stage`.
- **Snapshots:** the base queue read its partially updated valid mask. It now
  shares the transition function already used by the other entries, with
  old-state outputs and whole-register updates. `SnapshotGenerator_3` now
  matches the actual 80-bit payload / 320-bit snapshot RTL interface. New
  common drivers check payloads, validity priority, wrap, flush/rewind,
  simultaneous operations, and a later reset over 1,024 cycles.
- **ROB pointers:** the checked-in Backend uses **352 entries**, nine value
  bits, and an 80-bit output. The old Pyrope2 top implemented 16 entries.
  Its public interface now matches the checked-in RTL, including removal of
  the obsolete `canTrain` port. The shared pointer function handles arbitrary
  capacity rather than assuming a power of two. A common 1,024-cycle test
  exercises dispatch, block/allow, redirect, and the non-power-of-two wrap.
  The separate N32 entry remains a different, unresolved reference configuration.
- **LFSR:** vendor the actual 16-bit enabled Chisel RTL, with only its module
  name changed to the existing suite top. Generate `rocket/pyrope/` from it.
  Match its asynchronous reset, consolidate the duplicate file exporting the
  same top, and retain scalar state for automatic unbounded induction. The
  shared recurrence operates on a packed word. See `rocket/README.md` for
  provenance. The common driver checks 66,000 cycles and a complete period.
- **RenameBuffer:** retain the walking-entry loop cleanup and corrected
  snapshot child. Restore the allocation-request, packed allocation-pointer,
  and vector-configuration pointer connections that the old Pyrope2 source
  left unknown. Keep the vector exception output pipeline as three arrays.
  LiveHD now bridges those arrays to the RTL's 24 scalar flops. The latest
  whole-top comparisons against generated Pyrope and original RTL prove
  all 64 obligations without a bound. Repeated direct RTL proofs pass.
- **LiveHD:** preserve generic parameter/default metadata in saved LN units,
  retain lowered concrete stateful bodies when reloading complete bundles,
  and resolve file-level named scalar types passed into imported generics.
  DINO, PicoRV32, and all tested filter configurations now pass their
  precompiled top-level checks. The formal backend also avoids the recursive
  array-read propagation that crashed the RenameBuffer worker and recognizes
  scalar register banks whose lane index precedes a field suffix. It groups
  repeated memory-read addresses before proving their correspondence, proves
  small operand equalities beneath common large expressions, and retains
  completed slice proofs when a later solver batch exhausts its budget.

The affected generated Pyrope trees were refreshed through LiveHD. DINO's
comment-only and ADDW bug variants, and the filter's comment-only, corrupted
reference, and local-output variants, were updated to overlay the generated
trees while preserving each edit's intent. No benchmark assertion, expected
checksum, or benchmark option was weakened.

## Reproduce

```sh
python3 verif/check_pyrope2_cleanup.py --configurations --simulations --precompiled
python3 verif/check_pyrope2_cleanup.py --only picorv32 --configurations --simulations
python3 verif/check_pyrope2_cleanup.py --only RenameBuffer --timeout 240
```

The checker records commands, source/binary hashes, JSON verdicts, logs,
interfaces, and driver results in its printed work directory. `--only` selects
an entry; `--skip` explicitly separates expensive checks into another run.
The combined checked-in evidence is `pyrope2_cleanup_validation.json`.
Simulation uses compiled `lg:` inputs for every language so the same concrete
top is selected even when the generated source has a generic declaration.

The configuration matrix includes PicoRV32 without RVC/counters, 32-bit
counters, iterative shifts, a single register-file port, two-cycle ALU/compare,
serial/fast multiplication, division, and both full RV32M implementations.
Filter configurations cover (SIZE, MULT_WIDTH) = (2,1), (8,4), (8,8), (8,16)
in addition to the default (64,4).

## References still needed

These checked-in Pyrope2 entries cite an unavailable `rtl_rob16` / `rtl_rob32`
elaboration, and have no matching RTL in this repository:

- `Arbiter16_LqPtr`
- `FreeList_3` (96 entries)
- `FreeList_5` (120 entries)
- `RobEnqPtrWrapper_N32`

The locally available `../xs/build/build_opt/rtl/FreeList_3.sv` and
`FreeList_5.sv` both have 24 entries. Substituting them under the existing
96/120-entry interfaces would test different designs. These four entries
compile, but their three-language compatibility remains unverified and the
checker reports missing references. The matching RTL location was requested.

## Remaining LiveHD limitations

A `--top`-filtered `ln:` export is not a complete source bundle: reload loses
imports such as DINO's `encodings`. Export the entire explicit source list
**without `--top`** and select the external top after reloading. The checker
exercises this with `--precompiled`. Full-bundle DINO, filter, and PicoRV32
reloads now pass unbounded equivalence against RTL, including the tested
nondefault configurations. The former generic metadata and saved `wrap`
failures were fixed in LiveHD; focused regression tests cover both.

RenameBuffer's former correspondence gaps and solver SIGBUS are fixed.
Its top-level RTL proofs now pass unbounded and repeatably. The wide output
bottleneck was a common packed memory bus selected by differently sized but
equivalent pointer arithmetic. LiveHD proves the small operand lemmas first,
then uses ordinary functional congruence to discharge the large expressions.
Unproved lemmas retain their original output obligations. Previously completed
slice proofs also remain valid when a later ABC batch times out. Negative
regressions change a memory read address and a pointer wrap boundary; both
must refute, so these changes cannot bypass a real difference.

The filter's deliberate reference-load corruption changes the common 5M-cycle
checksum from `6209346479474330016` to `5156641730641301433`. Its six-cycle
bounded LEC result does not detect the bug and is rejected as proof; the
unchanged checksum gate catches it. DINO's deliberate ADDW mutation is
refuted at the CPU top. Comment-only variants prove equivalent.

The later [direct-bundle follow-up](pyrope2_direct_bundles.md) replaces DINO's packed stage adapters and records a fresh validation snapshot.
