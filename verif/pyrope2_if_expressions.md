# Pyrope2 if-expression pass

Reviewed all 36 design `.prp` files across the five `pyrope2` trees. Converted
value-selecting branches to expressions in eight files:

- DINO: forwarding, ALU operation decoding, ALU results, immediates, and branch
  comparisons. The same cleanup applies to `match` expressions without changing
  their mutually exclusive case semantics.
- PicoRV32: register-file read selection and the iterative-shift result. The
  ALU comparison/result if-expressions were already present when this pass began.
- Matched filter: the typed product is a constant if-expression; each arm keeps
  its local signed intermediate calculations.
- Xiangshan: snapshot enqueue/dequeue pointers are direct expressions, removing
  two mutable temporaries and preserving flush priority.

Register enable/hold blocks and branches that update several signals remain
conditional statements. The pass preserves unknown values, explicit narrowing,
state update order, and external interfaces. Rocket already uses expressions for
its value selectors. Generated `pyrope` and Verilog sources were not edited.

## Validation

**423/423 checks pass** across 23 affected top/configuration combinations,
including 95 unbounded equivalence results and 34 shared-driver simulations.
No source or compiler fixes were needed after the expression rewrites.

Evidence is in [pyrope2_if_expressions_validation.json](pyrope2_if_expressions_validation.json).
The checker requires unbounded external top equivalence and identical external
interfaces. It regenerates Pyrope from RTL, checks the checked-in Pyrope where
applicable, repeats Pyrope2 proofs, and uses the same simulation driver across
the language variants. The affected configurations are DINO; all 12 PicoRV32
configurations; all five filter configurations; four snapshot variants; and
RenameBuffer, which imports the shared snapshot implementation.

Baseline compilation passed before editing. Complete precompiled bundles are
also checked for DINO, PicoRV32, and the filter. Commands and source/compiler
hashes are recorded in the evidence file. The shared LiveHD binary was rebuilt
during the initial RenameBuffer run, so that run was repeated using a pinned
copy of the new binary; the other completed runs used the earlier binary.
Compiler hashes are therefore recorded per run. Reproduction:

```bash
python3 verif/check_pyrope2_cleanup.py --only dino --simulations --precompiled
python3 verif/check_pyrope2_cleanup.py --only picorv32 --configurations --simulations --precompiled
python3 verif/check_pyrope2_cleanup.py --only matched_filter --configurations --simulations --precompiled
python3 verif/check_pyrope2_cleanup.py --only SnapshotGenerator --simulations
python3 verif/check_pyrope2_cleanup.py --only RenameBuffer
```

The four missing RTL configurations from the earlier repository-wide pass are
unchanged and outside this edit's dependency set.

## Word counts

DINO decreases from 4,999 to 4,898 words (101 fewer); the filter from 601 to 596
(five fewer); the snapshot helper from 278 to 270 (eight fewer). The two rewritten
PicoRV32 blocks remove another 15 words: **129 words removed by these rewrites**.

PicoRV32 was also reformatted during the pass, separately from these edits.
Spaces inserted inside slices increase its raw whitespace word count, so its
whole-directory before/after count does not isolate this transformation. The
evidence records raw counts rather than treating formatting as simplification.
