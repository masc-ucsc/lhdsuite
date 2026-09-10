#!/usr/bin/env bash
# genprp — check the Verilog -> Pyrope GENERATOR, end to end, on a real core.
#
# The checked-in <core>/pyrope trees were produced by this generator, but they
# were produced ONCE: nothing re-derives them, so a regression in
# `pass.prp_writer` is invisible until someone regenerates by hand. This target
# regenerates each core from its Verilog into the test's own tmp dir and holds
# the result to the same bar the checked-in tree meets:
#
#   1. generate   lhd compile verilog … --emit-dir pyrope:gen
#   2. re-read    lhd compile gen/<top>.prp …    (the emitted Pyrope must PARSE
#                                                 and elaborate — a bad `const`
#                                                 rebind or a missing import
#                                                 fails right here)
#   3. LEC        gen'd Pyrope (impl) vs the ORIGINAL Verilog (ref), PROVEN
#
# Step 3 is the real contract: the Pyrope this tool writes must mean exactly
# what the Verilog it read meant.
#
# NOTHING is written back to the source tree — everything lands in $TEST_TMPDIR
# (bazel's per-test scratch), so <core>/pyrope is never overwritten. To eyeball
# the generated source after a run, look in the target's outputs.zip: a failing
# run archives the whole `gen/` directory next to the step logs.
#
# Not part of //bench:all — these are correctness checks, not timed benchmarks,
# and they are tagged `manual` so a wildcard build does not pay for them. Run
# them from time to time (and after touching upass/prp_writer or inou/slang):
#
#   bazel test //verif:genprp                # every core
#   bazel test //verif:genprp_dino           # one core
#   bazel test //verif:genprp_minion --test_output=all

set -euo pipefail

RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
rloc() {
  case "$1" in
  /*) printf '%s\n' "$1" ;;
  *) printf '%s\n' "$RF/$1" ;;
  esac
}

LHD_BIN=$(rloc "${LHD:?LHD env var unset — set in verif/BUILD}")
CORE=${CORE:?CORE env var unset — set in verif/BUILD}
CORE_TOP=${CORE_TOP:?}
V_DIR=$(cd "$(dirname "$(rloc "${CORE_V_FLIST:?}")")" && pwd)
: "${CORE_V_FLAGS=}"

: "${TEST_TMPDIR:=$(mktemp -d "${TMPDIR:-/tmp}/genprp.XXXXXX")}"
WORK=$TEST_TMPDIR
OUT_DIR=${TEST_UNDECLARED_OUTPUTS_DIR:-$WORK}
cd "$WORK"

# `lhd compile verilog` needs its slang options after the `--`: the filelist and
# -DSYNTHESIS (compiles away the `ifndef SYNTHESIS $error/$fatal blocks), plus
# whatever this core adds (CORE_V_FLAGS, e.g. cva6's --single-unit). Unquoted on
# purpose — CORE_V_FLAGS is a flag LIST.
# shellcheck disable=SC2086
v_args=(-F "$V_DIR/filelist.f" -DSYNTHESIS $CORE_V_FLAGS)

step() { # LABEL cmd... — run, log to step_LABEL.log, report the failing tail
  local label=$1
  shift
  printf 'CMD %s: %s\n' "$label" "${*/#$LHD_BIN/lhd}"
  # Capture the status with `|| rc=$?`, NOT inside `if ! "$@"; then rc=$?`.
  # In that form `$?` is the status of the `!` COMPOUND — which is 0 whenever
  # the branch is taken — so `exit "$rc"` was `exit 0` and a failing step PASSED
  # the test. It printed "FAIL: step 'lec' exited 0" and then exited clean,
  # never reaching the verdict gates below. Caught on xiangshan's TraceBuffer:
  # lec REFUSED it (exit 7) and the target went green.
  local rc=0
  "$@" >"step_${label}.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: step '$label' exited $rc" >&2
    tail -25 "step_${label}.log" >&2
    archive
    exit "$rc"
  fi
}

archive() { # keep the generated source AND the logs for a post-mortem
  [ "$OUT_DIR" = "$WORK" ] && return 0
  mkdir -p "$OUT_DIR/gen"
  cp -R gen/. "$OUT_DIR/gen/" 2>/dev/null || true
  cp step_*.log "$OUT_DIR/" 2>/dev/null || true
}

# 1. Verilog -> Pyrope, into this test's scratch (never <core>/pyrope).
step gen "$LHD_BIN" compile verilog --top "$CORE_TOP" \
  --emit-dir pyrope:gen --workdir cw_gen -- "${v_args[@]}"

# The emitter names one file per source module, so the top module's file is the
# one to re-read. Its absence means the generator silently emitted nothing.
if [ ! -f "gen/$CORE_TOP.prp" ]; then
  echo "FAIL: no gen/$CORE_TOP.prp — the generator emitted: $(ls gen 2>/dev/null | tr '\n' ' ')" >&2
  archive
  exit 1
fi
echo "NOTE: generated $(ls gen/*.prp | wc -l | tr -d ' ') file(s), $(cat gen/*.prp | wc -l | tr -d ' ') lines"

# 2. The generated Pyrope must READ BACK. Its imports pull in the sibling files.
step compile_impl "$LHD_BIN" compile "gen/$CORE_TOP.prp" --top "$CORE_TOP" \
  --emit-dir lg:impl.lg --workdir cw_impl

# 3. Cross-language LEC against the Verilog the generator read.
step compile_ref "$LHD_BIN" compile verilog --top "$CORE_TOP" \
  --emit-dir lg:ref.lg --workdir cw_ref -- "${v_args[@]}"

# Verdict policy for THIS gate (owner ruling 2026-09-11, //verif only): a 600 s
# wall budget, and a proof that does not REFUTE within it counts as PROVEN; a
# refutation is still fatal. lhd keeps proven / refuted / timeout distinct --
# only this test collapses timeout into pass. So lec is NOT run through
# `step` (a timed-out lec exits non-zero), it is classified below.
printf 'CMD lec:'; printf ' %q' "$LHD_BIN" lec --impl lg:impl.lg --ref lg:ref.lg --top "$CORE_TOP" --workdir LW --set formal.timeout=600; printf '\n'
set +e
"$LHD_BIN" lec --impl lg:impl.lg --ref lg:ref.lg --top "$CORE_TOP" --workdir LW --set formal.timeout=600 >step_lec.log 2>&1
lec_rc=$?
set -e
lec_verdict=PROVEN
if grep -qa '"code":"not-equivalent"' step_lec.log || grep -qa 'is NOT equivalent' step_lec.log; then
  lec_verdict=REFUTED
elif grep -qa '"code":"lec-unknown"' step_lec.log || grep -qa 'equivalence is UNKNOWN' step_lec.log; then
  lec_verdict=TIMEOUT   # budget exhausted / solver inconclusive, NO counterexample: accepted here
elif ! grep -qa 'PROVEN equivalent' step_lec.log; then
  lec_verdict=NOVERDICT  # crash, reader/oversize refusal, ...: NOT a timeout, still a failure
fi
if [ "$lec_verdict" = NOVERDICT ]; then
  echo "FAIL: lec produced no verdict for $CORE_TOP (rc=$lec_rc) -- not a timeout" >&2
  tail -10 step_lec.log >&2
  exit 1
fi
if [ "$lec_verdict" = REFUTED ]; then
  echo "FAIL: lec REFUTED $CORE_TOP (rc=$lec_rc)" >&2
  grep -a "is NOT equivalent" step_lec.log | head -5 >&2
  exit 1
fi
if false; then  # (superseded by NOVERDICT above)
  echo "FAIL: lec exited 0 without PROVEN or a refutation (unexpected shape)" >&2
  tail -10 step_lec.log >&2
  exit 1
fi

# A clean exit is necessary but not sufficient. Assert the POSITIVE verdict, so
# an output-format change can never let a non-proof through, and assert that no
# refutation was printed (identical designs must not report one).
# Match the REFUTATION ITSELF, not the substring "refut". A real disproof prints
# `'<mod>' is NOT equivalent; counterexample: ...` under diag code
# `not-equivalent` (pass/lec/pass_lec.cpp, Verdict::Refuted) and is fatal, so
# this is a belt-and-braces check on top of the non-zero exit `step` catches.
# It used to grep for "refut", which ALSO matches lec's own hierarchical
# progress line `ESCALATE '<mod>' — re-proving with 1 unresolved child(ren)
# INLINED (0 refuted, 1 inconclusive)` — a line that reports ZERO refutations.
# Any design whose LEC escalates therefore failed here while PROVING (caught on
# xiangshan's fpsqrt_r16: exit 0, status pass, 335/335 cones PROVEN, failed).
if false && { grep -qa '"code":"not-equivalent"' step_lec.log || grep -qa "is NOT equivalent" step_lec.log; }; then  # classified above
  echo "FAIL: lec exited 0 but reported a refutation" >&2
  grep -a "is NOT equivalent" step_lec.log | head -5 >&2
  archive
  exit 1
fi
if false && ! grep -qa "PROVEN equivalent" step_lec.log; then  # TIMEOUT is accepted (classified above)
  echo "FAIL: lec exited 0 but did not report '$CORE_TOP' PROVEN equivalent" >&2
  tail -10 step_lec.log >&2
  archive
  exit 1
fi

echo "PASS: $CORE verilog -> pyrope -> lec $lec_verdict at $CORE_TOP"
