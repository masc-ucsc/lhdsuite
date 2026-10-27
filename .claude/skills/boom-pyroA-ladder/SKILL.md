---
name: boom-pyroA-ladder
description: End-to-end workflow for the BOOM pyroA→D scalar-array-fold ladder on `lhdsuite/boom/pyrope2/<Module>.prp`. Orchestrates baseline LEC vs the SmallBoomV4 .sv reference, per-step scalar-family folds (dispatched to `pyrope-ablation-rules scalar-array-fold`), incremental LEC pyroX vs pyroPREV, end-of-chain audit vs .sv, and the final commit of the cumulative result into `pyrope2/`. Use when the user asks for pyroA, pyroB, ... pyroZ on a BOOM module, or asks to "continue the fold ladder" on a module.
---

# boom-pyroA-ladder

Thesis context (per Jose, meeting 2026-10-05): *compact IR via loop recovery + incremental + bootstrap-the-language.* Scalar-array folding is the first mechanical compaction step toward that end — it builds the array scaffolding on which later loop recovery can run. This skill wraps the whole BOOM pyroA→D fold ladder so the user does not have to re-prompt each step.

This is a **workflow skill**, not a rewrite rule. Rewrites are delegated to `pyrope-ablation-rules` (specifically the `scalar-array-fold` rule). This skill owns the orchestration, scratch-dir layout, LEC chains, and git plumbing.

## Scope

- **Target**: a single file `/mada/users/frabieik/lhdsuite/boom/<design>/pyrope2/<Module>.prp`.
- **Reference**: the firtool-emitted `.sv` under `/mada/users/frabieik/chipyard-boom-v4/sims/verilator/generated-src/chipyard.harness.TestHarness.<Config>Config/gen-collateral{,.dedup-on.bak}/<Module>.sv`.
- **Deliverable**: one commit per module replacing `pyrope2/<Module>.prp` with the end-of-chain pyroX, PROVEN vs .sv. Scratch dir with `pyroA/B/…` intermediates kept for audit, outside the lhdsuite repo per Jose's directive (`feedback_pyroABCD_outside_repo.md`).

## Prerequisites

- `lhd` on `PATH` (`/soe/frabieik/.local/bin/lhd` is the canonical binary).
- `/tmp` writable for workdirs.
- Scratch root exists: `/mada/users/frabieik/pyro_scratch/boom/`.
- `pyrope-ablation-rules` skill available (dispatched for the actual rewrite).
- User's `feedback_no_claude_trailer.md` memory loaded → **never** add `Co-Authored-By: Claude …` to commit messages.
- User's `feedback_no_git_push.md` memory loaded → **never** run `git push`. Stop at `git commit`.
- User's `reference_boom_lec_conventions.md` memory loaded → 5-rule BOOM pyroA ↔ .sv LEC convention (no `reset:u1` port on reset-free modules, no `[reset_pin=…] = 0` on RegNext regs, scalar reg-arrays with firtool-matching names, RegNext regs renamed to firtool conventions).

## The ladder — one step at a time

Each pyroX step is one atomic transition:

1. Seed `pyroX/` from `pyroPREV/` (or from `pyrope2/<Module>.prp` for pyroA).
2. Pick a scalar family (or a batch of fields sharing the same K) via the detection algorithm in `pyrope-ablation-rules scalar-array-fold`.
3. Apply the fold.
4. Compile pyroX.
5. LEC pyroX vs pyroPREV (incremental). PROVEN → continue. REFUTED/UNKNOWN → revert and reclassify.
6. Report LOC delta.

The user chooses the batch size per step. Typical schedule:

| step | fields batched | LOC delta per field | motivation |
|---|---|---|---|
| pyroA | 1 | K−1 | smallest, catches any Pyrope-syntax surprises first |
| pyroB | 1–3 | (K−1)×3 | confirm the batch pattern works |
| pyroC | 3–10 | (K−1)×10 | scale up once PROVEN pairwise |
| pyroD+ | 10–30 | (K−1)×30 | sweep remaining fields |
| end-of-chain | — | — | audit vs .sv then commit |

K is the number of scalars per family (8 for FetchBuffer slots, 4 for BranchKillablePipeline_2 pipeline stages, etc.). LOC delta per field = K − 1 (K scalar decls deleted, 1 array decl inserted).

## Directory and workdir layout

```
# scratch (outside repo)
/mada/users/frabieik/pyro_scratch/boom/<Module>/
  chisel/<Module>.sv              # the SV reference, copied for provenance
  pyroA/<Module>.prp              # first fold
  pyroA/<Deps>.prp                # any sibling .prp imports copied in
  pyroB/<Module>.prp              # ...
  ...
  pyroE/<Module>.prp              # final state

# LEC/compile workdirs (ephemeral)
/tmp/<module>_baseline/
  impl_lg/                        # pyrope2 side (lgraph)
  ref_lg/                         # SV side (lgraph) — compiled with -DSYNTHESIS
  pyroA_lg/ … pyroE_lg/           # per-step lgraphs
  w_impl/ w_ref/ w_pA/ …          # lhd workdirs
```

## Step 0 — baseline LEC

Run exactly once per module, before pyroA. If this does not PROVEN, flag the module and stop — the pyroA ladder cannot anchor against a broken baseline.

```sh
# Config: default to SmallBoomV4Config. Fall back to .dedup-on.bak sibling if
# the primary gen-collateral/ is empty (common when firtool was re-run without dedup).
MOD=<Module>
PRP=/mada/users/frabieik/lhdsuite/boom/pyrope2/${MOD}.prp
GC_PRIMARY=/mada/users/frabieik/chipyard-boom-v4/sims/verilator/generated-src/chipyard.harness.TestHarness.SmallBoomV4Config/gen-collateral
GC_BAK=/mada/users/frabieik/chipyard-boom-v4/sims/verilator/generated-src/chipyard.harness.TestHarness.SmallBoomV4Config/gen-collateral.dedup-on.bak
if [ -f "$GC_PRIMARY/${MOD}.sv" ]; then SV=$GC_PRIMARY/${MOD}.sv; else SV=$GC_BAK/${MOD}.sv; fi

WD=/tmp/${MOD,,}_baseline
mkdir -p $WD && cd $WD && rm -rf impl_lg ref_lg w_impl w_ref

# PRP side — include any sibling imports the top .prp uses (grep for const.*import).
DEPS=$(grep -oE 'import\("[^"]+"\)' "$PRP" | sed -E 's#.*import\("([^"]+)"\).*#\1#' | awk -F. '{print "/mada/users/frabieik/lhdsuite/boom/pyrope2/"$1".prp"}' | sort -u | tr '\n' ' ')
lhd compile $PRP $DEPS --emit-dir lg:impl_lg --workdir w_impl

# SV side — always pass -DSYNTHESIS to strip firtool $error system tasks. Include SV deps if present.
SV_DEPS=$(dirname $SV)/$(grep -oE 'IssueSlot_[0-9]+|ram_[0-9]+x[0-9]+' "$SV" | sort -u | sed 's/$/.sv/' | tr '\n' ' ')  # heuristic; refine per module
lhd compile $SV $SV_DEPS --emit-dir lg:ref_lg --workdir w_ref -- -DSYNTHESIS

# LEC
lhd lec --impl lg:impl_lg --ref lg:ref_lg --top $MOD
```

Expected: `PROVEN equivalent (… cones: N/N PROVEN …)`. If not, see Troubleshooting.

## Step 1..K — per-step fold

Each step takes the previous step as input, applies the `scalar-array-fold` rule for one or more fields, and verifies.

```sh
PREV=pyroA   # or pyroB, pyroC, ...
NEXT=pyroB
MOD=<Module>
SCRATCH=/mada/users/frabieik/pyro_scratch/boom/$MOD

# 1. Seed next from prev
cp -r $SCRATCH/$PREV $SCRATCH/$NEXT

# 2. Delegate the rewrite to pyrope-ablation-rules scalar-array-fold
#    (plan + diff + wait-for-ack handled there)
PRP=$SCRATCH/$NEXT/${MOD}.prp
# Invoke the rule skill with the target .prp. Caller may list specific fields
# to batch (e.g. "inst debug_inst is_rvc"), or leave open for auto-detect of
# the single next candidate.

# 3. Compile
WD=/tmp/${MOD,,}_baseline
cd $WD && rm -rf ${NEXT}_lg w_${NEXT,,}
lhd compile $PRP --emit-dir lg:${NEXT}_lg --workdir w_${NEXT,,}

# 4. Incremental LEC
lhd lec --impl lg:${NEXT}_lg --ref lg:${PREV}_lg --top $MOD

# 5. Report LOC delta
A=$(wc -l < $SCRATCH/$PREV/${MOD}.prp)
B=$(wc -l < $SCRATCH/$NEXT/${MOD}.prp)
echo "LOC: $PREV=$A  $NEXT=$B  Δ=$((A-B))"
```

Expected LEC output: `PROVEN equivalent (… structural …)` for pure semdiff cases, or `PROVEN equivalent (solver=cvc5 …)` with a tier-2 state-pairing notice like:

```
'<MODULE>' tier-2 unpaired state: ref{<prefix>_0_<field> ...} impl{<prefix>_<field>}
```

The tier-2 notice is **expected** — it is the matcher reporting the group-to-array pairing, not a failure. Only `REFUTED` or `UNKNOWN` are failures.

## End-of-chain audit

Before committing, run LEC pyroFINAL vs the SV ref directly. This re-anchors the chain against the original ref and catches any pyroX step that silently drifted.

```sh
FINAL=pyroE   # whichever letter is last
lhd lec --impl lg:${FINAL}_lg --ref lg:ref_lg --top $MOD
```

Must return PROVEN. If not, bisect: `lhd lec` pyroA vs ref, pyroB vs ref, … to find the first drifting step. The pairwise PROVENs do NOT compose automatically — the end-of-chain audit is mandatory.

## Commit

```sh
cp /mada/users/frabieik/pyro_scratch/boom/$MOD/$FINAL/${MOD}.prp \
   /mada/users/frabieik/lhdsuite/boom/pyrope2/${MOD}.prp

cd /mada/users/frabieik/lhdsuite
git add boom/pyrope2/${MOD}.prp

# Compose the message body. Commit title format MUST match the existing
# BOOM pyroA convention (grep `git log --oneline` for examples):
#   boom: pyroA on <Module> (-X.XX% lines, <concise fold description>, PROVEN vs .sv)
#
# Multi-line body:
#   <before> → <after> LOC. <field list> → <array decl summary>.
#   LEC: PROVEN in <ms> ms vs SmallBoomV4Config .sv ref (SYNTHESIS wrap).
#   <N/N> cones discharged by cone pass (solver=cvc5, <engine>).
#   Incremental scratch chain pyroA→X all PROVEN pairwise before this landing.
#
# NO "Co-Authored-By: Claude ..." trailer. The feedback_no_claude_trailer.md
# rule applies to every commit this skill makes.

git commit -m "boom: pyroA on <Module> (-X.XX% lines, …, PROVEN vs .sv)

<body as above>"
```

**Do NOT** run `git push`. The user runs push themselves (`feedback_no_git_push.md`).

The committed state captures the cumulative result of pyroA→pyroFINAL as a single atomic transition. Intermediate pyroX letters are not individually committed to lhdsuite (per `feedback_pyroABCD_outside_repo.md`). The scratch directory remains available for audit.

## Troubleshooting

### Baseline LEC fails to compile the SV side

Firtool emits `$error` system tasks for Verilog assertions. The SV side **must** be compiled with `-DSYNTHESIS`:

```sh
lhd compile $SV --emit-dir lg:ref_lg --workdir w_ref -- -DSYNTHESIS
```

Any error like *"system task '$error' is not supported by --reader slang"* indicates `-DSYNTHESIS` was missing.

### Baseline LEC: `top 'X' not found; using 'X.X'`

Harmless warning. The lec tool found the top via entity-name match. The verdict still determines PASS/FAIL.

### Baseline LEC: SV ref doesn't exist in `gen-collateral/`

Firtool inlined the module in SmallBoomV4Config, so no standalone `.sv` exists. Check `gen-collateral.dedup-on.bak/` for a dedup-on sibling, or try the MegaBoomV4Config's gen-collateral which generally preserves more module boundaries. If no reference exists in any config, the pyroA ladder cannot anchor and this module is **not** a candidate.

### Compile fails: "array wire is not supported"

The target field is in a `wire` family (forward-referenced signals). SKIP this family and look for a `reg` family instead. Pyrope has no array-wire support yet.

### Compile fails: "written before it has an initializer"

Scalar family was `wire` or you used `mut` without `= 0`. For `reg` arrays, use `reg …:[K]uW:[ordering="old"]` (no initializer needed). For `mut` arrays, add `= 0`.

### Incremental LEC returns UNKNOWN or REFUTED

- Missing `[ordering="old"]` on the reg array → array lowers to `mem:(K)xW`, matcher can't pair. Add the attribute.
- Forgot to rewrite a ref (EOL regex missed) → compile may still pass but LEC fails. Grep for remaining `<prefix>_<N>_<field>` with word-boundary and fix.
- A field is actually two different widths across indices → `SKIP_MIXED_WIDTH` the family, don't fold.

### End-of-chain audit (pyroFINAL vs .sv) fails but all pairwise PROVENs passed

Suggests the pairwise chain accumulated a tier-2 drift. Bisect: LEC pyroMID vs .sv to find the first drift point. The faulty pyroX step must be undone and re-done, or SKIP that family and leave it as scalars.

## Composition with other rules

After scalar-array-fold has landed all reg families on a module, follow-up passes are candidates from the sibling skill:
- `rename` — rename remaining `_GEN_N`, `_T_N`, `_mux_N` noise.
- `wire-to-const` — collapse two-step `wire`+assign into `const`/`mut`.
- `band-fold`, `cascade-fold`, `flatten-extract` — more aggressive loop-recovery patterns.
- `register-removal` — if any reg became observably dead after the fold.

The clean end state is a module ready for the parametric Mini↔Mega rewrite (Rob_rob16 pyroBA pattern), where `[K]` → `[nEntries]` with a module-level `comptime` parameter.

## Invariants and non-goals

- **This skill does not add any trailer to commits.** The `feedback_no_claude_trailer.md` rule is absolute.
- **This skill does not push.** Stop at `git commit`.
- **This skill does not modify `pyrope2/<Module>.prp` incrementally.** Only one commit, representing the full ladder result, lands in-repo.
- **This skill does not alter `io.*` signatures, module port lists, comments, or whitespace** beyond what `scalar-array-fold` rewrites.
- **This skill does not run `bazel test`.** The ablation PPA capture is a separate workflow; this skill owns correctness (LEC) only.
- **This skill does not touch the lhdsuite scratch sibling of pyrope2/.** No `pyrope2_scratch`, no `pyrope2_v2` — only the single `pyrope2/<Module>.prp` landing.

## Known gotchas (bake these into every run)

| gotcha | fix |
|---|---|
| sed without word boundary misses EOL identifiers | always use `sed -E "s/\<<prefix>_([0-9]+)_<field>\>/.../g"` |
| array `wire` not supported | the family must be `reg`; else SKIP |
| `mut` array needs `= 0` | or switch to `reg` with `[ordering="old"]` |
| 2D reg-array breaks matcher | fold one dimension at a time; see `reference_pyrope_lec_matcher_2d_regarray.md` |
| scalar fold on a BOOM module with reset init | BOOM pyroA convention: no `reset_pin=…`, no `= 0`, scalar reg-arrays with firtool-matching names; see `reference_boom_lec_conventions.md` |
| gen-collateral/ empty but ..dedup-on.bak/ has refs | fall back to the backup sibling automatically |
| SV compile fails on `$error` | pass `-DSYNTHESIS` to the SV `lhd compile` |

Running without these guards is the fastest path to a REFUTED or compile fail.
