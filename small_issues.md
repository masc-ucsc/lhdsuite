# Pending LiveHD issues found by //verif:genprp

Found 2026-08-21 by extending `//verif:genprp` to `//xiangshan/Backend`, one
`--top` at a time (~680 of its 783 module families swept). Every item here is a
**livehd-side** gap — the suite changes that surfaced them are already in.

**The headline negative result: ZERO `REFUTED` across the whole sweep.** Not one
proven inequivalence. Every failure below is a crash, a refusal, or a budget
exhaustion — the tool declining to decide, never deciding wrong. So there is no
evidence of a silent miscompile in the xiangshan path; issue 2 is a design that
cannot be *checked*, not one shown to be broken.

Caveat on that claim: the sweep was stopped at ~680/783 to free the machine for
uncontended memory measurements, and the ~100 unswept families are the LARGEST
modules — where a refutation is most likely to hide. Finish the sweep before
treating "0 refutations" as final.

## Reproducing

Everything below runs from the repo root. Four items have a bazel target, which
is the least error-prone route:

```bash
bazel test //verif:genprp_xs_enqentry_4   --test_output=all   # issue 1
bazel test //verif:genprp_xs_tracebuffer  --test_output=all   # issue 2
bazel test //verif:genprp_minion          --test_output=all   # issue 3
```

For the raw form — and for issues 4 and 5, which have no target on purpose —
this helper runs the same four steps `verif/genprp.sh` runs. `lhd` is whatever
`bazel run @livehd//lhd:lhd` builds; the suite's own binary lands at
`bazel-bin/external/livehd+/lhd/lhd`.

```bash
# genprp_one <TOP> [extra slang flags...]   — gen, re-read, ref, lec
genprp_one() {
  local top=$1; shift
  local fl=xiangshan/Backend/verilog/filelist.f
  local va=(-F "$fl" -DSYNTHESIS --single-unit "$@")
  rm -rf /tmp/gp && mkdir -p /tmp/gp && cd /tmp/gp || return 1
  lhd compile verilog --top "$top" --emit-dir pyrope:gen --workdir cw_gen -- "${va[@]}" || return
  lhd compile "gen/$top.prp" --top "$top" --emit-dir lg:impl.lg --workdir cw_impl || return
  lhd compile verilog --top "$top" --emit-dir lg:ref.lg  --workdir cw_ref  -- "${va[@]}" || return
  lhd lec --impl lg:impl.lg --ref lg:ref.lg --top "$top" --workdir LW
}
```

Paths in `va` are relative, so call it from the repo root or make `$fl`
absolute first.

---

## 1. `inou.slang` dies with `std::bad_alloc` — tens of GB on a small design

**Blocks:** the whole 15-module `EnqEntry` family. `bazel test
//verif:genprp_xs_enqentry_4` FAILS.

Step 1 (`gen`) never completes. On an **idle** 64 GB box it reaches **~34 GB
RSS at ~47s** and then dies (34.4 and 34.1 GB on two runs); under parallel load
it dies earlier, at 17.1 GB / 55s. The wall moves with available memory, the
failure does not. Siblings `EnqEntry` and `EnqEntry_18` die identically.

The design is not large — 275 KB of `.sv` emitting ~1056 Pyrope lines. For
scale, the sibling that *survives*, `EnqEntryVecMem`, still peaks at **24.7 GB**
to emit 1038 lines. So this is a front-end memory blowup across the family, not
one pathological module.

```bash
cd /path/to/lhdsuite
/usr/bin/time -l lhd compile verilog --top EnqEntry_4 \
    --emit-dir pyrope:gen --workdir /tmp/w \
    -- -F xiangshan/Backend/verilog/filelist.f -DSYNTHESIS --single-unit
# exit 1, {"code":"slang-internal-error","message":"std::bad_alloc"}
# "maximum resident set size" ~34e9 on an idle machine
```

`EnqEntryVecMem` is wired as `//verif:genprp_xs_enqentryvecmem` specifically as
the canary: it is the nearest sibling that passes, so if this blowup worsens it
goes red first.

---

## 2. False WORD-LEVEL combinational cycle in the emitted Pyrope

**Blocks:** `TraceBuffer`, `fpsqrt_r16_block`. `bazel test
//verif:genprp_xs_tracebuffer` FAILS.

`lec` encodes the Verilog reference fine and then refuses the implementation:

```
impl encode failed: operand of 'get_mask_4184' has no encodable driver
  (combinational cycle?); root: WORD-LEVEL CYCLE through:
  get_mask_4184@gen/TraceBuffer.prp:333 -> concat_7804@:417 -> concat_7664@:417
  -> concat_7652@:416 -> concat_7612@:414 -> mux_7160@:403 -> ... -> :417
```

Every hop is inside the GENERATED file. The mechanism, from the emitted source:

```
:417   blocksUpdate = (lane7 << 182) | (lane6 << 156) | (lane5 << 130) | ...
:333   _mux_38 = ... blocksUpdate#[26..=51] ...      # reads a DIFFERENT lane
:389   _mux_54 = ... blocksUpdate#[130..=155] ...    # reads a DIFFERENT lane
```

The emitter packs 8 per-lane structs into ONE flat `blocksUpdate` bus, and lane
N's logic reads *another* lane's slice out of it. Bit-wise there is no loop —
the slices are disjoint. Word-wise it is `blocksUpdate -> _mux -> _GEN_* ->
blocksUpdate`, and the encoder reasons at word level, so it refuses.

This is the same family as the `Get_mask`-over-`Set_mask` false cycle already
fixed once in `pass/cprop`, so it reads as a NEW INSTANCE of a closed class, and
the fix site is likely the same (make the slice-disjointness visible) rather
than the emitter. Worth confirming which before touching prp_writer.

```bash
genprp_one TraceBuffer     # ~3s, lec exits 7
genprp_one fpsqrt_r16_block  # same class, 3.6s, 4 files
```

`TraceBuffer` is the cheaper reproducer: one module, no imports, ~3s.

Note the parent `fpsqrt_r16` PROVES — at that level lec boxes the child and
escalates, so the defect only shows when the block is the top.

---

## 4. Word-level cycle on the VERILOG side (`ref encode failed`)

**Not wired as a target on purpose** — the cycle is in the reference, so this is
an encoder limit, not a prp_writer defect. Wiring it would blame the generator
for something it did not do. Listed here so it is not re-found and misfiled.

```
ref encode failed: operand of 'xor_13912' has no encodable driver
  (combinational cycle?); root: WORD-LEVEL CYCLE through:
  xor_13912@xiangshan/Backend/verilog/Reduction.sv:815 -> ...
```

```bash
genprp_one Reduction    # ~3s, lec exits 7, note "ref encode failed"
```

Same word-level-disjointness question as issue 2, approached from the Verilog
front end instead — plausibly one fix covers both.

---

## 5. Cost cliffs: `gen` and `lec` on mid-size modules

Not correctness. Recorded because it is what caps how much of xiangshan
`genprp` can cover, and it is why the suite's slowest passing pick is only 87s.

| top | where | cost |
| --- | --- | --- |
| `DecodeUnitComp` | `gen` | >900s, killed (never reached lec) |
| `Dispatch` | `gen` | >900s, killed |
| `SSIT` | `lec` | 364s then INCONCLUSIVE (`formal.timeout=120s x hard_timeout_mult=3`; all 4 memory sub-blocks pass, the top box does not) |
| `Permutation`, `VfRegFilePart1/2/3` | — | >200s, killed |
| `EnqEntryVecMem` | `gen` + `ref` | 43.0s + 43.1s of slang, vs 0.5s of lec |

That last row is the general shape: on these designs the front end, run twice,
dominates — `lec` is often the cheap step.

```bash
time genprp_one DecodeUnitComp   # still inside step 1 at 900s
time genprp_one SSIT             # ~373s total, 364s of it lec, ends UNKNOWN
```

Do NOT reach for `--set formal.timeout=...` to make `SSIT` green — that is the
"never add an lhd option to make a bench pass" rule in AGENTS.md.

---

## 6. lgcheck REFUTES 3 modules — don't-cares materialized as all-ONES

Found by re-running the sweep with the SECOND engine: `lhd lec --set
formal.solver=lgyosys` (yosys `equiv` via `inou/yosys/lgcheck`). COMPLETE: 781
module families checked with both engines. lgyosys exit codes: 611 clean, 133
timeout (120s cap), 3 REFUTED, 2 refused. cvc5: 671 PROVEN, 38 no-output, 24
inconclusive, 13 timeout, 23 never reached lec (gen/re-read/ref failed).

| module | cvc5 | lgcheck |
| --- | --- | --- |
| `MultiWakeupQueue_2` | **PROVEN** | **REFUTED** |
| `BlockCipherModule` | INCONCLUSIVE | **REFUTED** |
| `CryptoModule` | TIMEOUT (400s) | **REFUTED** |

Everything else was PROVEN, INCONCLUSIVE, or TIMEOUT — fine either way. lgcheck
exits **10** and prints `lec: 'impl.lg' REFUTED (not equivalent)
(solver=lgyosys)`. NOTE the wording differs from cvc5's `is NOT equivalent;
counterexample:` — a gate that greps only cvc5's phrasing will miss it.
`verif/genprp.sh` still catches it, but via the non-zero exit, not the gate.

**Root cause (`MultiWakeupQueue_2`).** The refutation is a bounded miter, and the
BMC is set up soundly — `-set-at 1 in_reset 1 -set-at 2 in_reset 1 -set-at 3
in_reset 0 -set-init-zero` — so it is NOT an unreset-state artifact. Stripping
the X-masked noise leaves exactly ONE both-concrete mismatch, at every step:

```
t=2  io_deq.valid   gold=0  gate=1
t=3  io_deq.valid   gold=0  gate=1
t=4  io_deq.valid   gold=0  gate=1
```

It comes from one dead pipe-stage submodule whose outputs the reference leaves
as don't-cares and the round trip commits to all-ones:

| output | ref (`check_ref.v:963`) | impl (`check_impl.v:939`) |
| --- | --- | --- |
| `io_deq.valid` | `2'sb0?` | `2'sh1` |
| `io_deq.bits.fuType` | `37'sb0???...?` | `37'shfffffffff` |
| `io_deq.bits.fuOpType` | `10'sb0?????????` | `10'sh1ff` |
| `io_deq.bits.src` | `129'sb0????...?` | `129'sh...ffffffff` |

Every `?` bit becomes a `1`. On the reference the don't-care is masked away
downstream and the top's `io_deq.valid` settles to 0; on the implementation the
hard 1 leaks through and the queue asserts valid. So the divergence IS
observable at the top — this is not confined to an unused net.

**Do not assume cvc5 is simply wrong.** Two readings, and they need separating
before anyone "fixes" an engine:

1. cvc5 treats the reference `0?` as a FREE variable, so it may pick 1 and the
   two sides are equal — a legitimate don't-care refinement, and PROVEN is right.
2. yosys picks a concrete gold value and compares, so it sees 0 vs 1.

Under reading 1 the bug is the emitter materializing don't-cares as all-ones
(harmless in silicon, fatal for equivalence checking, and it changes an
observable output here). Under reading 2 the default engine is missing a real
inequivalence. Settle which by checking whether the Verilog source genuinely
leaves that stage unconstrained.

```bash
# reproduce (the try2 helper runs gen/reread/ref once, then BOTH solvers)
genprp_one MultiWakeupQueue_2        # cvc5: PROVEN, ~0s
lhd lec --impl lg:impl.lg --ref lg:ref.lg --top MultiWakeupQueue_2 \
    --workdir LWy --set formal.solver=lgyosys
# exit 10, "REFUTED (not equivalent)", ~12s
# counterexample trace: LWy/lgcheck_bmc.log ; cgen'd sides: LWy/check_{ref,impl}.v
```

`BlockCipherModule` (29s) and `CryptoModule` (48s) refute the same way and carry
the same don't-care asymmetry (82 `?`-bearing lines in ref vs 76 in impl); cvc5
reaches no verdict on either, so there is no engine disagreement to explain
there — only lgcheck has an opinion, and it is REFUTED.

**Method note.** lgcheck is worth running as a routine second opinion: on the
modules cvc5 could not decide it returned PROVEN once (`fpdiv_r64_block`) and
refuted three times. It is slower and weaker at proving (611 clean exits vs
cvc5's 671 PROVEN, 133 timeouts at a 120s cap) but it decides different things.

## 7. IDEA: bind unknowns to ZERO on BOTH sides and re-run both engines

37 modules end with cvc5 undecided (24 inconclusive + 13 timeout), and 35 of
those are undecided by BOTH engines — no verdict at all from anything. That is
the biggest blind spot left, bigger than the 3 refutations.

**The proposal.** Constrain every unknown (`?`) bit to 0 on BOTH the reference
and the implementation, regenerate the Pyrope under the same convention, and
re-run cvc5 AND lgcheck. Zero-filling is a common optimization, so it both
matches what downstream tools tend to do and massively constrains the search
space — an undecidable miter may become decidable once the free X bits stop
being free.

**What it would and would not prove.** Zero is not the only correct resolution
of a don't-care, so agreement under a zero-binding is NOT a proof of equivalence
for all X assignments. But it is a strong and cheap signal: if ref and impl BOTH
zero their unknowns and then MATCH, that is fine — the remaining difference was
only in don't-care territory. And if they still DIFFER with every X pinned to
the same value, the difference is real logic and the search space is now small
enough to get a usable counterexample out. Either outcome is progress on a
module that currently yields nothing.

Issue 6 is the motivating case: the round trip already materializes reference
don't-cares as all-ONES, so today the two sides disagree on X by construction —
measured on `MultiWakeupQueue_2`, the emitted implementation has **0** lines
carrying a `?` while the reference has **27**. Pinning both to 0 removes exactly
that asymmetry.

**Blocker: the knob does not exist on the lec path.** Verified 2026-08-22:

| spelling | result |
| --- | --- |
| `--set sim.unknown_zero=true` | ACCEPTED but INERT — still REFUTED, and the emitted `check_ref.v` still carries `\io_deq.valid = (2'sb0?)` |
| `--set formal.unknown_zero=true` | rejected, exit 2 (unknown option) |
| `--set cgen.unknown_zero=true` | rejected, exit 2 |

`unknown_zero` is registered only in the sim/cgen namespace
(`inou/cgen/inou_cgen.cpp`, routed via `lhd/lhd_kernel_common.cpp` as
`sim.unknown_zero`) and never reaches the `inou.cgen.verilog` emission that
`formal.solver=lgyosys` uses for its two sides. So step one is wiring it there
(or adding `formal.unknown_zero`) — after which this experiment is a re-run of
the sweep with one extra flag.

```bash
# once the knob lands, the experiment over the 35 both-undecided modules:
lhd lec --impl lg:impl.lg --ref lg:ref.lg --top <TOP> --workdir LWz \
    --set formal.unknown_zero=true                      # cvc5
lhd lec --impl lg:impl.lg --ref lg:ref.lg --top <TOP> --workdir LWy \
    --set formal.solver=lgyosys --set formal.unknown_zero=true
```

The 35 both-undecided modules are mostly the float/vector and regfile families:
`VfRegFilePart0-3`, `FpRegFilePart0-3`, `IntRegFile`, `VIAlu`, `VIPU`, `VIDiv`,
`VPPU`, `Bku`, `FDivSqrt`, `VFDivSqrt`, `VectorFloatDivider`, `fpdiv_r64_block`,
`fpsqrt_r16_block`, `Reduction`, `TraceBuffer`, `Permutation`, `Trace`,
`RegCacheTagTable`, `LFST`, `MemCtrl`, and the `Entries*`/`IssueQueue*` vector
pairs. Several of those are ALSO the word-level-cycle refusals of issues 2 and 4,
so a zero-binding may unblock two problems at once.

## Finish the sweep

The ~100 unswept families are the largest ones. To resume, generate the family
representative list (largest `cone_lines` per name with trailing `_N` stripped)
and run `genprp_one` over each with a timeout, skipping the two benign classes
that cannot be compared at all:

- `DummyDPICWrapper_*` — DPI debug shells that `-DSYNTHESIS` empties
- `{V,}{M,S}iregNModule`, `PrintCommitIDModule` — CSR alias stubs whose body is
  literally `reg_0 <= reg_0`

Both correctly draw `lec REFUSED: selected top has no observable output ports;
no equivalence claim can be compared`. 35 modules land in this class; they are
not bugs.
