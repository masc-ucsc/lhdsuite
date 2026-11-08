# Dino Pyrope

`pyrope/` is a hand-maintained implementation of the checked-in Verilog,
with the same `PipelinedDualIssueCPU` interface and cycle behavior.
It began as a LiveHD translation of Chisel-generated RTL. The Verilog
remains the equivalence reference; cleanup does not regenerate or alter it.

The Scala source used to understand the design is
`../simplechisel/src/main/scala/`, especially `pipelined/stage-register.scala`,
`pipelined/dual-issue.scala`, and `components/`. That checkout was at
`57ecdddf2c3bf3f32084234792145b7e66ce603c`. This is provenance for the
explanatory source, not a claim that re-elaborating it reproduces the vendored
RTL. The suite describes the RTL as its July 7, 2026 simplechisel fork.

## Organization

- `StageReg.prp` is the single parameterized pipeline-storage module. `T`
  specializes to `u2`, `u4`, `u14`, `u97`, `u257`, `u321`, and `u322`.
  All fourteen stage instances call it directly; the numbered StageReg modules
  and the old extra `stage_register.prp` have been removed.
- `pipeline_bundles.prp` contains pure packing/unpacking helpers with named
  `comptime const` offsets. It contains no state or pipeline-register modules.
  These conversions are necessary because LiveHD currently rejects a generic
  named-tuple register and nested tuple call arguments (see the issues report).
- The CPU passes named tuples to the helpers, reusing its existing data bundles.
  There are no escaped dotted port arguments. Control tuples are flat at calls;
  fields stay named throughout the CPU. External memory interfaces are direct.
- `encodings.prp` defines shared `pub comptime const` opcodes, ALU operations,
  forwarding selectors, control encodings, and instruction-field positions.
  Constants used by only one decoder remain local to that file.
- ALU, opcode/immediate decoding, issue, hazards, and forwarding express their
  operations directly. Internal predicates use `bool`; the external `u1`
  interface converts explicitly. Fixed-width arithmetic uses `wrap`.
- The register file has two writes with port B last, giving it collision
  priority. It retains unreset storage, old-data reads, and the x0 read override.
- The leaf blocks are explicit `mod` entities. They add no pipeline stage;
  they preserve independent module/proof boundaries. The reasons for retaining
  these boundaries and explicit field connections are in [cleanup_issues.md](../cleanup_issues.md).

`tests/comment1/ALU.prp` is the current ALU plus one comment.
`tests/bug1/ALU.prp` changes only ADDW addition to subtraction.
The old generated `manifest.json` was removed because its hashes no longer
represented these sources. `BUILD` stages the maintained `.prp` files directly.
The StageReg formal sidecar retains all four load/hold/flush/reset properties
using equality over the packed 97-bit value, which covers the original three
fields. Its standalone driver checks the same fields by slicing that value.

## Validation

From the suite root:

```sh
python3 dino/check_cleanup.py --lhd ../livehd/bazel-bin/lhd/lhd
```

The command retains a fresh artifact directory with exact commands, source and
binary SHA-256 hashes, logs, JSON results, and formal reports. It requires
**unbounded** top-level LEC, repeats it in an independent workdir, checks the
comment variant, refutes the ADDW mutation at the ALU, runs the existing formal
sidecars, and runs the program with two seeds plus focused simulations.
`--top-bug` additionally requests the slower whole-CPU mutation check.

Final sources validated September 12, 2026, using `lhd 0.1.0`:

| Check | Result |
|---|---|
| Original generated tree versus original RTL | Unbounded PROVEN, 17/17 definitions |
| Final CPU, two fresh LEC runs | Unbounded PROVEN, 10/10 matched definitions, 92/92 top cones, no trust or state map |
| Comment-only variant versus original RTL | Unbounded PROVEN |
| ADDW bug versus original ALU | REFUTED: operation 23, x=2, y=1, expected 3, got 1 |
| Whole-CPU ADDW mutation | Inconclusive run interrupted during fallback; optional `--top-bug` check |
| Existing ALU formal sidecar | Passed |
| StageReg load/hold/flush/reset sidecar | Passed at bound 8; overall bounded, after two reset cycles |
| Program, 2,000 cycles, seeds 1 and 37 | Both passed: x2=100, x3=-102, stores complete at cycle 521 |
| SRL bit-63 corner and StageReg capture simulations | Passed |
| Bazel `dino_compile_pyrope`, `dino_compile_incremental` | Passed with `--override_module=livehd=../livehd` |
| Bazel `dino_verify_temporal` | Passed, four obligations at bound 8 |
| Bazel `dino_compile_pyrope_parallel` | Fails on precompiled generic imports; see issues |

The proof now inlines the reference stage adapters and the generic storage
specializations; the smaller definition count reflects the new hierarchy.

[cleanup_validation.json](cleanup_validation.json) records the final checks and
binary fingerprint. The sibling checkout and binary changed during this session,
so the binary hash is the precise executable identity; a later observed source
HEAD and local-change status are recorded separately. Synthesis/QoR and the full suite were not measured.
