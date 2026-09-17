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
# These correctness checks run under //verif:all, separately from the timed
# //bench:all benchmarks. Run them after touching upass/prp_writer or inou/slang:
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

# 1. One original-Verilog elaboration produces the generated Pyrope and its
# reference graph library. Both artifacts share exactly the same source and
# options, and large hierarchies do not pay for a second reference elaboration.
step gen "$LHD_BIN" compile verilog --top "$CORE_TOP" \
  --emit-dir pyrope:gen --emit-dir lg:ref.lg --workdir cw_gen -- "${v_args[@]}"

# The emitter names one file per source module, so the top module's file is the
# one to re-read. Its absence means the generator silently emitted nothing.
if [ ! -f "gen/$CORE_TOP.prp" ]; then
  echo "FAIL: no gen/$CORE_TOP.prp — the generator emitted: $(ls gen 2>/dev/null | tr '\n' ' ')" >&2
  archive
  exit 1
fi
echo "NOTE: generated $(ls gen/*.prp | wc -l | tr -d ' ') file(s), $(cat gen/*.prp | wc -l | tr -d ' ') lines"

# ---------------------------------------------------------------------------
# run_deadline SECONDS LOGFILE CMD...  -- run CMD with a HARD wall-clock limit,
# returning 124 when it had to be killed.
#
# Not `timeout(1)`: the bazel test PATH has no homebrew, so that binary is
# absent in the sandbox and every call would silently fall back to no limit at
# all. This is a plain background-and-poll watchdog, which needs nothing but
# bash.
# ---------------------------------------------------------------------------
# kill_tree PID SIGNAL -- PID and every descendant, children first. A bare
# `kill $pid` is not enough here: the things being timed are WRAPPER scripts
# (lgcheck spawns yosys, lhd spawns solvers), job control is off in a
# non-interactive shell so the child shares OUR process group (killing the
# group would kill this script), and an orphaned yosys keeps a core busy for
# the rest of the suite -- which also corrupts every timing measured after it.
kill_tree() {
  local pid=$1 sig=$2 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child" "$sig"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
}

run_deadline() {
  local secs=$1 logfile=$2
  shift 2
  if [ "${secs:-0}" -le 0 ] 2>/dev/null; then
    local rc0=0
    "$@" >"$logfile" 2>&1 || rc0=$?
    return "$rc0"
  fi
  "$@" >"$logfile" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
    sleep 5
    waited=$((waited + 5))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill_tree "$pid" TERM
    sleep 2
    kill_tree "$pid" KILL
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  local rc=0
  wait "$pid" || rc=$?
  return "$rc"
}

# The LEC budget for every leg of this gate, soft and hard (owner ruling
# 2026-09-15). Override with LEC_BUDGET_S for a one-off deeper run.
LEC_BUDGET_S=${LEC_BUDGET_S:-300}   # SOLVER budget -> --set formal.timeout=
LEC_WALL_S=${LEC_WALL_S:-0}        # hard wall-clock stop for the leg; 0 = none

# 2. The generated Pyrope must READ BACK. Its imports pull in the sibling files.
step compile_impl "$LHD_BIN" compile "gen/$CORE_TOP.prp" --top "$CORE_TOP" \
  --emit-dir lg:impl.lg --workdir cw_impl

# 3. Cross-language LEC against the original-Verilog graph from step 1.
#
# Verdict policy for THIS gate (owner ruling 2026-09-15, //verif only): a
# FIVE-MINUTE budget per leg, and only a REFUTATION fails. A timeout, an
# undecided solver and an encoder refusal all mean the engine found no issue, so
# they pass with the verdict named. lhd itself keeps proven / refuted / timeout
# distinct; only this test collapses the non-refutations into a pass. So lec is
# NOT run through `step` (a timed-out lec exits non-zero), it is classified below.
#
# BOTH engines run: the native solver and the independent lgyosys oracle. A
# single engine cannot police itself -- if the native LEC silently stopped
# proving anything, every leg would go "inconclusive" and this gate would look
# green, which is exactly what the second engine is here to catch.
#
# LEC_LEG_VERDICT is set rather than echoed: a `$(lec_leg ...)` would capture
# the CMD line into the verdict AND put the refutation `exit 1` in a subshell,
# where it would leave this script running and the gate green.
LEC_LEG_VERDICT=
lec_leg() {  # LABEL EXTRA_SET...
  local label=$1
  shift
  local log="step_${label}.log" rc=0
  printf 'CMD %s:' "$label"
  printf ' %q' "$LHD_BIN" lec --impl lg:impl.lg --ref lg:ref.lg --top "$CORE_TOP" \
    --workdir "LW_${label}" --set "formal.timeout=$LEC_BUDGET_S" "$@"
  printf '\n'
  set +e
  run_deadline "$LEC_WALL_S" "$log" \
    "$LHD_BIN" lec --impl lg:impl.lg --ref lg:ref.lg --top "$CORE_TOP" \
    --workdir "LW_${label}" --set "formal.timeout=$LEC_BUDGET_S" "$@"
  rc=$?
  set -e
  LEC_LEG_VERDICT=$(python3 "$(rloc _main/verif/lec_verdict.py)" "$log" "$rc")
  # NOVERDICT / BOUNDED / UNDECIDED: no counterexample, but nothing was fully
  # checked either (a truncated run, a proof that only covered some cycles, an
  # encoder refusal). All three were fatal before this gate learned about
  # deadlines and stay fatal -- only a real TIMEOUT is forgiven.
  case $LEC_LEG_VERDICT in
  NOVERDICT | BOUNDED | UNDECIDED)
    echo "FAIL: $label reached no usable verdict ($LEC_LEG_VERDICT) for $CORE_TOP (rc=$rc) -- not a timeout" >&2
    tail -10 "$log" >&2
    archive
    exit 1
    ;;
  esac
  if [ "$LEC_LEG_VERDICT" = REFUTED ]; then
    echo "FAIL: $label REFUTED $CORE_TOP (rc=$rc)" >&2
    tail -10 "$log" >&2
    archive
    exit 1
  fi
}

lec_leg lec
lec_verdict=$LEC_LEG_VERDICT
lec_leg lec_lgyosys --set formal.solver=lgyosys
lgyosys_verdict=$LEC_LEG_VERDICT
echo "PASS: $CORE verilog -> pyrope -> lec native=$lec_verdict lgyosys=$lgyosys_verdict at $CORE_TOP"
