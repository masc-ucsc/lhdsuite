# DINO direct-bundle follow-up

DINO Pyrope2 now passes its pipeline values as typed bundles. All fourteen
`StageReg<T>` instances store those bundles directly; `Control` returns nested
`ex_ctrl`, `mem_ctrl`, and `wb_ctrl` fields. The CPU passes whole values and
subtuples between them, and `pipeline_bundles.prp` has been removed.
The external `PipelinedDualIssueCPU` ports and testbench are unchanged.

| Source snapshot | Files | Words |
| --- | ---: | ---: |
| Pyrope2 immediately before this bundle pass | 13 | 4,898 |
| Pyrope2 after this pass | 12 | 3,908 |
| Current checked-in Pyrope | 17 | 8,685 |
| Matching Verilog | 17 | 10,519 |

Words are whitespace-separated tokens (`len(text.split())`), including comments
and every design/helper `.prp` or `.sv` in the corresponding DINO directory;
testbenches and manifests are excluded. The before snapshot is retained at
`/tmp/pyrope2-direct-bundles/before`. The bundle pass removes **990 words
(20.2%)**. The final Pyrope2 is **62.8% smaller than Verilog** by this measure.
Formatting added seven words to the 3,901-word draft; the reduction comes from
removing pack/unpack functions, offsets, and repeated field connections.

## Validation

**25/25 checks passed** using the local LiveHD checkout. Exact commands,
binary hash, source hashes, verdicts, and log paths are in
[the validation JSON](pyrope2_direct_bundles_validation.json).

```sh
python3 verif/check_pyrope2_cleanup.py --only dino --simulations --precompiled \
  --workdir /tmp/pyrope2-direct-bundles/validation-final
```

The checks cover fresh Verilog-to-Pyrope generation, ordinary and incremental
compilation, external-interface agreement, repeated Pyrope2 top-level LEC,
checked-in and freshly generated Pyrope LEC, full LNAST export/reload and LEC,
and the same 2,000-cycle program testbench against all four representations.
All five required LEC results are `proven` with `bounded: false`.

## LiveHD fixes required

Generic specialization now carries named tuple layouts through ports and
registers. Nested types, whole-bundle/subtuple connections, and split-register
reset attributes are lowered consistently. SSA preserves a register read
assigned to an output instead of redirecting later conditional state writes
to that output.

LEC now proposes correspondence between a packed register and its scalarized
fields. It proves the relation after reset and proves preservation of the
relation and external outputs by induction. The field-order guess is never
trusted without those proofs. A short reset-base check can complete an already
proved inductive relation; a bounded check alone cannot yield an unbounded
verdict. DINO needs no explicit state map or trusted module.

The imported, nested, two-stage fixture is
`../livehd/inou/prp/tests/equiv/generic_tuple_register.prp`.
`//lhd/tests:lec_tuple_register_test` requires unbounded proof both directly
and after precompiled export, and requires refutation of three independent
mutations: missing flush, inverted enable, and wrong reset.

The 71 selected existing tuple, generic, style, and formal regression targets
also passed (`/tmp/pyrope2-direct-bundles/focused-final.log`). This was focused
validation, not a full LiveHD test-suite run.

This establishes the explicit named-type generic bundle path used here. It
is not a blanket claim that every nested non-generic call syntax or scalar
assignment to a whole tuple is implemented.

The [style scan](pyrope2_style.md) and
[cleanup prompt](../sample_prompt_cleanup_pyrope.md) record the related guidance
for future passes, including Xiangshan's large repeated blocks.
