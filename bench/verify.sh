#!/usr/bin/env bash
# Formal assert/assume: the <core>/verif/$CORE_UNIT.verify.prp sidecar proves
# arithmetic facts about one real module of the design (dino: the ALU's ADDW
# sum + sign-extension; minion: the TxFMA 64-bit adder). lhd is strict by
# default: an UNKNOWN fails the run, so PASS == all PROVEN.
#
#   MODE=cold  one proving run.
#   MODE=bug   the bug1 variant ($CORE_UNIT's add flipped to subtract) must be
#              CAUGHT: non-zero exit AND a refutation with a counterexample
#              trace, not a crash and not an inconclusive UNKNOWN.
#   MODE=temporal  the SEQUENTIAL sidecar ($CORE_SEQ_UNIT): properties relating
#              one cycle to the next (`past`/`stable`), at a deeper bound. Only
#              generated for a core that declares seq_unit.
#   MODE=incr  three runs sharing one --workdir (formal_cache.json over it):
#              cold, identical warm re-run (obligation cache hits asserted),
#              then a comment1 recompile (obligations unchanged — still warm).
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

copy_core_pyrope src/pyrope

# The bound is per-core (CORE_VERIFY_BOUND, default 2) because the useful depth
# is a property of the DESIGN's reset: a core that holds reset longer than the
# window has all its obligations checked while it is still idle, which makes the
# proof weak and makes the bug1 twin unable to refute anything.
: "${CORE_VERIFY_BOUND:=2}"
: "${CORE_VERIFY_SETS:=}"  # set -u: the script also runs outside bazel
vrun() {
  local wd=${1:-FW} incremental=${2:-true}
  local incr_args=()
  [ "$incremental" != false ] || incr_args=(--set lhd.incremental=false)
  # shellcheck disable=SC2086  # CORE_VERIFY_SETS is a token LIST, split on purpose
  lhd formal verify "src/pyrope/$CORE_UNIT.prp" "$CORE_VERIF_DIR/$CORE_UNIT.verify.prp" \
    --top "$CORE_UNIT" --set "formal.bound=$CORE_VERIFY_BOUND" --workdir "$wd" \
    $CORE_VERIFY_SETS \
    ${incr_args[@]+"${incr_args[@]}"}
}

# The SEQUENTIAL sidecar ($CORE_SEQ_UNIT), whose properties relate one cycle to
# the next (`past`, `stable`, ...). Deeper bound than the arithmetic units: a
# temporal claim proven only two cycles out is not worth much, and the extra
# depth costs little on one module.
: "${SEQ_BOUND:=8}"
vrun_seq() {
  lhd formal verify "src/pyrope/$CORE_SEQ_UNIT.prp" "$CORE_VERIF_DIR/$CORE_SEQ_UNIT.verify.prp" \
    --top "$CORE_SEQ_UNIT" --set "formal.bound=$SEQ_BOUND" --workdir FW
}

# How many assert obligations the sidecar DECLARES. `--list-tests` is a pure
# parse of the formal blocks (no design load, no solver, ~10 ms), so this is the
# sidecar's own count rather than a number hardcoded here that drifts the moment
# someone adds a property.
expected_asserts() {  # UNIT — defaults to $CORE_UNIT
  local u=${1:-$CORE_UNIT}
  lhd formal verify "src/pyrope/$u.prp" "$CORE_VERIF_DIR/$u.verify.prp" \
    --top "$u" --list-tests 2>/dev/null | head -1 | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
print(sum(t.get("asserts", 0) for t in d.get("tests", [])))'
}

# check_proven LABEL EXPECTED — every assert obligation PROVEN, and as many of
# them as the sidecar declares.
#
# This reads the per-obligation verdicts out of formal_report.json rather than
# counting "PROVEN" in the log. The old `grep -c PROVEN >= 2` gate had real
# slack: a passing dino run prints FOUR lines containing PROVEN (one per assert
# plus the whole-design summary line) against THREE asserts, so two of the three
# could vanish — a front-end change that stops parsing a `formal` block, say —
# and the target would still go green. Same reasoning as CORE_SIM_EXPECT: a run
# that completes but checks less than it should must not pass.
check_proven() {
  local label=$1 want=$2 report=${3:-FW/formal_report.json}
  python3 - "$report" "$want" <<'PY' || { step_failed "$label" "obligation check failed"; exit 1; }
import json, sys
rep, want = sys.argv[1], int(sys.argv[2])
try:
    d = json.load(open(rep))
except Exception as e:
    print(f"FAIL: cannot read {rep}: {e}", file=sys.stderr)
    raise SystemExit(1)
obs = [o for o in d.get("obligations", []) if o.get("kind") == "assert"]
bad = [(o.get("line"), o.get("verdict")) for o in obs if o.get("verdict") != "proven"]
if want <= 0:
    print("FAIL: the sidecar declares no assert obligations (--list-tests parse failed?)", file=sys.stderr)
    raise SystemExit(1)
if len(obs) != want:
    print(f"FAIL: sidecar declares {want} assert(s) but the report carries {len(obs)}"
          " — an obligation was dropped, not proven", file=sys.stderr)
    raise SystemExit(1)
if bad:
    print(f"FAIL: not every assert is PROVEN: {bad}", file=sys.stderr)
    raise SystemExit(1)
PY
  metric "${label}_obligations" "$want" asserts
}

case "${MODE:?}" in
cold)
  want=$(expected_asserts)
  run_timed verify_cold vrun
  check_proven verify_cold "$want"
  echo "PASS: $CORE_UNIT — $want/$want assert obligations PROVEN (${LAST_MS} ms)"
  ;;
bug)
  # The formal counterpart of lec_bug. The sidecar's first assert is exactly
  # what tests/bug1 breaks (the unit's add flipped to subtract), so the run must
  # REFUTE — a non-zero exit alone is not enough, since strict mode also exits
  # non-zero on an UNKNOWN that proves nothing.
  core_variant bug1 src/pyrope
  run_expect_fail verify_bug vrun
  if ! grep -qa "REFUTED" step_verify_bug.log; then
    step_failed verify_bug "bug1 failed the run but not as a refutation (an UNKNOWN proves nothing)"
    exit 1
  fi
  # A refutation must come with the per-cycle input trace that reproduces it;
  # that trace is what the generated replay testbench is built from.
  if ! grep -qa "counterexample inputs" step_verify_bug.log; then
    step_failed verify_bug "REFUTED without a counterexample trace"
    exit 1
  fi
  metric verify_bug_refuted 1 bool
  echo "PASS: injected $CORE_UNIT bug REFUTED with a counterexample (${LAST_MS} ms)"
  ;;
temporal)
  # Sequential properties over $CORE_SEQ_UNIT: `past`/`stable` relate a cycle to
  # the next, which the arithmetic `unit` sidecars cannot exercise at all. The
  # same pinned gate applies — every declared assert PROVEN, and as many as the
  # sidecar declares.
  : "${CORE_SEQ_UNIT:?this core has no seq_unit; the target should not have been generated}"
  want=$(expected_asserts "$CORE_SEQ_UNIT")
  run_timed verify_temporal vrun_seq
  check_proven verify_temporal "$want"
  # A temporal claim must actually reach past cycle 0: if every obligation were
  # skipped for want of history the run would be vacuously green, so require the
  # engine to disclose a history window (it prints one line per monitor).
  grep -qa "cycle(s) of history" step_verify_temporal.log \
    || { step_failed verify_temporal "no history window disclosed — are these properties temporal at all?"; exit 1; }
  echo "PASS: $CORE_SEQ_UNIT — $want/$want sequential obligations PROVEN (bound=$SEQ_BOUND, ${LAST_MS} ms)"
  ;;
incr)
  want=$(expected_asserts)
  run_timed verify_full vrun FF false
  check_proven verify_full "$want" FF/formal_report.json

  run_timed verify_cold vrun
  check_proven verify_cold "$want"

  run_timed verify_warm vrun
  check_proven verify_warm "$want"
  grep -qaE "formal\[cache\]: [1-9][0-9]* obligation hit" step_verify_warm.log \
    || { echo "FAIL: warm identical re-run reported no obligation-cache hits" >&2; exit 1; }

  core_variant comment1 src/pyrope
  run_timed verify_touch vrun
  check_proven verify_touch "$want"
  echo "PASS: cold/warm/comment-touch verify runs all PROVEN ($want obligations each)"
  ;;
*)
  echo "FAIL: unknown MODE=$MODE" >&2
  exit 2
  ;;
esac
