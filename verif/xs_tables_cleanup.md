# XiangShan rename and busy table cleanup

Five concrete modules now have cleaned versions in `xiangshan/Backend/pyrope2`:
`RenameTable`, `RenameTable_1`, `RenameTable_2`, `BusyTable`, and `BusyTable_1`.
The original `pyrope` files remain unchanged. Two shared implementations,
`rename_table.prp` and `busy_table.prp`, replace the repeated generated logic;
the concrete adapters preserve the existing external interfaces for comparison
and integration. Existing callers have not been switched to these new files.

The helpers now infer configuration-dependent input and output types from
concrete instantiations. This removes six type parameters from `rename_table`,
seven from `busy_table`, and 32 repeated type bindings across their callers.
Fixed-width controls retain their declared types. `ENTRIES` and `PREGS` are
required configuration parameters (every existing caller already supplies them),
so these helpers require an instantiation instead of advertising an independent
default top with no concrete input types. Other configuration defaults remain.

All five external tops are unbounded PROVEN equivalent to their versions before
this generic cleanup, on two independent runs; both the top and helper graphs
match structurally. A shared LN bundle containing all five configurations also
reloads every top with an unbounded proof against its direct compilation. The
saved baseline is commit `39ac6a11ec31d6aeb967cfe24a46e46ef66e4b54`. Current
source hashes and the new checks are in `xs_inferred_generics_validation.json`;
`xs_tables_cleanup_validation.json` retains the original cleanup evidence.
The final inferred-port sources also pass all five 1,024-cycle differential
simulations against the original generated Pyrope, fresh and incremental
compilation, and per-module LN export/reload proofs.

This equivalence establishes that removing the type parameters preserves the
existing implementation; it does not close the earlier RTL-equivalence gap.

The design hints came from `../xs/repo/src/main/scala/xiangshan/backend/rename/`
(`RenameTable.scala` and `BusyTable.scala`) at Chisel checkout
`96c3f568f943a096ffd3d712dc6f462ac4b1ba33`.
The exact checked-in Verilog, compiled with `-DSYNTHESIS`, is the behavior
reference; current Chisel is not assumed to have identical elaboration.
See the validation JSON for the verified commit and all source hashes.

The rename implementation covers 32/34/47 logical entries, 16/24 read ports,
eight speculative and architectural write lanes, and 520 differential write
lanes. It preserves last-lane write priority, read holds and delayed bypass,
retirement alias handling, duplicate-free suppression, and four snapshots.
The vector configuration omits logical entry zero from the differential output.
The tables are packed registers so their asynchronous reset is immediate;
Pyrope array reset initializers would introduce a memory restore sweep.

The busy implementation covers 224 integer and 256 floating-point physical
registers, with their respective read, writeback, and wakeup port counts.
It preserves the integer zero-register rule, current-allocation read bypass,
wakeup/writeback priority, three two-cycle load-dependency histories, and
cancellation. Multiple matching wakeups OR their dependencies, as Chisel's
Mux1H does. Unobservable performance counters are omitted. Unreset snapshot
storage and pipeline state retain their uninitialized declarations.

Counts include each complete reachable design source set once: the five
original modules plus SnapshotGenerator_9/10/11; the five cleaned adapters plus
both new helpers and the existing snapshot_queue; and the corresponding eight
Verilog files. Whitespace-delimited words use `len(text.split())`; tests and
reports are excluded. This is removal of repeated logic, not whitespace
compression.

| Source closure | Lines | Words | Bytes |
| --- | ---: | ---: | ---: |
| Original Pyrope | 92,715 | 2,163,129 | 17,564,208 |
| Cleaned Pyrope, before generic cleanup | 1,058 | 3,823 | 58,154 |
| Cleaned Pyrope, inferred ports | 1,054 | 3,806 | 57,411 |
| Matching Verilog | 324,842 | 1,093,203 | 15,710,360 |

The initial cleanup simulation, compilation, and bundle results are recorded in
`xs_tables_cleanup_validation.json`. All five 1,024-cycle differential tests
pass, including a two-cycle initial reset and one-cycle reset pulses during
active traffic. Direct compilation, a cache-hit repeat, LN export/reload, and
unbounded direct-versus-reloaded LEC pass for every module. Both shared
implementations have zero style suggestions; the seven remaining suggestions
are repeated assignments in the adapters for the fixed external ports.
External declarations match the originals exactly after removing whitespace.

Full equivalence must be distinguished from passing differential simulation: the original three RenameTable variants
had unbounded proofs, while both original BusyTable proofs timed out after
180 seconds. All five final external-top RTL comparisons return UNKNOWN
with the inductive engine. State correspondence is unresolved: the reference exposes arrays as memories and
individual pipeline registers, while the cleaned hierarchy uses packed
registers. The reported differences across unmatched cuts are not confirmed
reachable counterexamples. No state mapping, ignored memory, trusted module,
or weakened assertion was used. The original unbounded rename-table proofs
have not been re-established, so these remain candidate cleanups.

Two valid generic constructs exposed LiveHD frontend bugs, fixed in
`../livehd/upass/runner/upass_runner.cpp`: forwarding a declared input bundle
into a generic child, and specializing a nested combinational helper with a
width derived from the caller's generic. The latter also needed a private
inline copy to keep one specialization from freezing subsequent widths.
The permanent Pyrope/Verilog pairs are `generic_input_bundle` and
`nested_generic_width` in `../livehd/inou/prp/tests/equiv`. Both direct and
Verilog-roundtrip tests pass. The generic/template regression selection passes
61 tests; the uPass selection passes 13 tests (these selections overlap).
Unrelated dirty LiveHD files and the prior RenameBuffer fix were preserved.

Reproduce the checks from the lhdsuite root:

```sh
python3 verif/check_xs_tables_cleanup.py --bundle
python3 verif/check_xs_tables_cleanup.py --lec --timeout 180
# Select one module or extend simulation:
python3 verif/check_xs_tables_cleanup.py --module RenameTable_2 --cycles 2048
```

The checker retains staged sources, generated test drivers, tool logs, and
result JSON in a fresh temporary directory. It uses identical zero power-on
fill on both simulated designs, checks every output including invalid data,
uses a two-cycle initial reset, and later pulses reset for one cycle while
work is active. This does not prove arbitrary initial-state equivalence.
Each tool invocation has a wall-clock limit and a 16 GiB process-tree RSS
limit. The initial 12 GiB cap stopped RenameTable_2 during host code generation;
its retry passed with a 12.51 GiB peak. Unknown, bounded-only, failed, or timed-out LEC returns nonzero.
