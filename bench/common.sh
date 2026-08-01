# Shared helpers for lhdsuite bench/test scripts. Source this; do not execute.
#
# Contract with bench/defs.bzl: every sh_test gets
#   MODE              scenario selector within a script family
#   LHD               rlocationpath of @livehd//lhd:lhd
#   CORE              design under test: dino | minion
#   CORE_V_FLIST      rlocationpath of <core>/verilog/filelist.f
#   CORE_P_TOP        rlocationpath of <core>/pyrope/<CORE_TOP>.prp
#   CORE_TOP          whole-design top module, in both languages
#   CORE_V_FLAGS      extra slang options for this core (may be empty)
#   CORE_UNIT         module carrying the verify sidecar + bug1/comment1
#   CORE_COLOR_ALGS   space-separated `pass color` algorithms this core runs
#                     (e.g. "flat synth", or just "synth" when the design is
#                     too big to fuse into one region)
#   CORE_SIM_TB       asserted, timed sim benchmark testbench basename
#   CORE_SIM_CYCLES   explicit cycle count for CORE_SIM_TB
#   CORE_SIM_TB_TOP   "1" = supply CORE_TOP before CORE_SIM_TB (for a driver
#                     importing the already-compiled whole design); "" = the
#                     testbench discovers its source-level unit itself
#   CORE_SIM_TB_V     MODE=verilog override for CORE_SIM_TB ("" = same driver
#                     for both modes); needed when the two trees declare a port
#                     differently (struct-packed → tuple vs flat). See defs.bzl
#   CORE_SIM_MARKER   string proving the benchmark reached its final report
#   CORE_SIM_EXPECT   string the asserted sim's output must also contain — the
#                     testbench's known-good data readback ("" = skip)
#   CORE_SIM_TOP_TB   whole-top testbench ("" = none)
#   CORE_SIM_TOP_CYCLES  explicit `cycles` value for CORE_SIM_TOP_TB
#   CORE_SIM_PROG_TB  program testbench ("" = none)
#   CORE_SIM_PROG_CYCLES explicit `cycles` value for CORE_SIM_PROG_TB
#   CORE_SIM_TOP_ASSERT  "1" = the two above GATE the target (a driver that
#                     fails fails the test); "" = report them as metrics only.
#                     Always metrics either way. See defs.bzl.
#   CORE_LEC_TRUST    comma-separated module-def names the LEC scenarios ASSUME
#                     equivalent without proving them (latch escape hatch; ""
#                     = trust nothing). When set, lec.sh also runs strict so a
#                     witness-free UNKNOWN top is a hard fail. See defs.bzl.
# Paths are runfiles-relative; resolve them with rloc before use. Scripts run
# inside $TEST_TMPDIR so every pass/workdir is hermetic per test. Scripts set
# RF (runfiles root) before sourcing this file, which also makes plain
# `bazel run //bench:<target>` work for debugging (no TEST_* env).

set -euo pipefail

if [ -z "${TEST_SRCDIR:-}" ]; then
  TEST_SRCDIR="${RF:?source common.sh from a bench script (RF unset)}"
fi
: "${TEST_TMPDIR:=$(mktemp -d "${TMPDIR:-/tmp}/lhdbench.XXXXXX")}"

rloc() {
  case "$1" in
  /*) printf '%s\n' "$1" ;;
  *) printf '%s\n' "$TEST_SRCDIR/$1" ;;
  esac
}

LHD_BIN=$(rloc "${LHD:?LHD env var unset — set in bench/defs.bzl}")
CORE=${CORE:?CORE env var unset — set in bench/defs.bzl}
CORE_V_DIR=$(cd "$(dirname "$(rloc "${CORE_V_FLIST:?}")")" && pwd)
CORE_P_DIR=$(cd "$(dirname "$(rloc "${CORE_P_TOP:?}")")" && pwd)
CORE_DIR=$(dirname "$CORE_P_DIR")
CORE_SIM_DIR=$CORE_DIR/sim
CORE_VERIF_DIR=$CORE_DIR/verif
CORE_TESTS_DIR=$CORE_DIR/tests
: "${CORE_TOP:?}" "${CORE_UNIT:?}" "${CORE_COLOR_ALGS:?}"
: "${CORE_V_FLAGS=}" "${CORE_SIM_MARKER:?}" "${CORE_SIM_EXPECT=}" "${CORE_LEC_TRUST=}" "${CORE_SIM_TB_V=}"
: "${CORE_SIM_CYCLES:?}" "${CORE_SIM_TB_TOP=}"
: "${CORE_SIM_TOP_CYCLES=}" "${CORE_SIM_PROG_CYCLES=}"
WORK=${TEST_TMPDIR:?}
cd "$WORK"

# Where per-test artifacts land: bazel archives this directory into the
# target's outputs.zip. Under plain `bazel run` there is none, so artifacts
# just stay in the work dir.
OUT_DIR=${TEST_UNDECLARED_OUTPUTS_DIR:-$WORK}
METRICS=$OUT_DIR/metrics.jsonl
: >"$METRICS"

# ---- output discipline -------------------------------------------------------
# The test log is meant to stay SHORT: bazel echoes it in full on failure, and
# //bench:show parses it. Only three kinds of line belong there — the `CMD`
# line per lhd invocation, the `METRIC` lines, and one verdict line per
# scenario. A failing step's output is NOT dumped wholesale; `step_failed`
# prints a short excerpt and files the FULL log under OUT_DIR, which lands in
# `bazel-testlogs/bench/<target>/test.outputs/`.
#   bazel test --test_env=BENCH_VERBOSE=1 //bench:<target>   # dump it inline
#   BENCH_FAIL_TAIL=N                                        # resize the excerpt
: "${BENCH_VERBOSE:=0}"
: "${BENCH_FAIL_TAIL:=12}"

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# Every lhd invocation goes through this wrapper: it logs the exact command
# (paths sanitized back to repo-relative form) as a `CMD <step>: lhd ...` line
# on the test's MAIN output — fd 3, saved here, because run_timed redirects
# fd 1 into the per-step log — so `bazel run //bench:show` can list what each
# bench actually executed. This doubles as living flow documentation.
exec 3>&1
CURRENT_STEP=""
lhd() {
  local out="lhd" a
  for a in "$@"; do
    case "$a" in
    "$CORE_P_DIR"*) a="$CORE/pyrope${a#"$CORE_P_DIR"}" ;;
    "$CORE_V_DIR"*) a="$CORE/verilog${a#"$CORE_V_DIR"}" ;;
    "$CORE_SIM_DIR"*) a="$CORE/sim${a#"$CORE_SIM_DIR"}" ;;
    "$CORE_VERIF_DIR"*) a="$CORE/verif${a#"$CORE_VERIF_DIR"}" ;;
    "$CORE_TESTS_DIR"*) a="$CORE/tests${a#"$CORE_TESTS_DIR"}" ;;
    esac
    if [ -n "${HAGENT_TECH_DIR:-}" ]; then
      case "$a" in
      "$HAGENT_TECH_DIR"*) a="\$HAGENT_TECH_DIR${a#"$HAGENT_TECH_DIR"}" ;;
      esac
    fi
    out="$out $a"
  done
  printf 'CMD %s: %s\n' "${CURRENT_STEP:--}" "$out" >&3
  "$LHD_BIN" "$@"
}

# log_cmd STEP CMD... — record a NON-lhd command on the main output in the same
# `CMD <step>: …` shape the wrapper above uses, so //bench:show lists it as part
# of the flow. The only such command today is the sim driver binary that
# `lhd sim` itself built (bench/sim.sh re-runs it to time the simulation apart
# from the host C++ compile).
log_cmd() { local step=$1; shift; printf 'CMD %s: %s\n' "$step" "$*" >&3; }

# metric NAME VALUE UNIT — one greppable human line + one JSONL record that
# bazel collects into the test's outputs.zip.
metric() {
  printf 'METRIC %-32s %12s %s\n' "$1" "$2" "$3"
  printf '{"name":"%s","value":%s,"unit":"%s"}\n' "$1" "$2" "$3" >>"$METRICS"
}

# step_failed LABEL MESSAGE — the ONE way a bench reports a failing step: a
# single-line diagnosis, then a short tail of that step's log. The whole log is
# filed under OUT_DIR, so it survives as a test output and can be read without
# re-running the bench.
#
# Dumping the raw log inline instead (what this used to do, `tail -60`) was the
# worst of both: it buried the diagnosis under screenfuls of per-def solver
# chatter AND still truncated it. Measured on minion_lec — the step log is 364
# lines, of which a 60-line tail showed 14 of the 30 UNKNOWN defs and none of
# the 32 TRUSTED ones, which is how fixme.md came to record "11 UNKNOWN".
step_failed() {
  local label=$1 log="step_${1}.log" where
  echo "FAIL: $2" >&2
  [ -f "$log" ] || return 0
  if [ "$BENCH_VERBOSE" != 0 ]; then
    cat "$log" >&2
    return 0
  fi
  # Where the reader can actually find the whole thing. Under `bazel test` the
  # copy shows up in the target's test.outputs/; under `bazel run` there is no
  # such dir, so the log stays in the (printed) work dir — never point at a
  # bazel-testlogs path that does not exist, and never claim a copy that the
  # cp did not make.
  if [ "$OUT_DIR" != "$WORK" ] && cp -f "$log" "$OUT_DIR/" 2>/dev/null; then
    where="bazel-testlogs/bench/<target>/test.outputs/$log"
  else
    where="$WORK/$log"
  fi
  tail -n "$BENCH_FAIL_TAIL" "$log" >&2
  echo "  [$log: $(wc -l <"$log" | tr -d ' ') lines; full log at $where;" \
    "--test_env=BENCH_VERBOSE=1 prints it all here]" >&2
}

# run_timed LABEL cmd args... — run a step, record wall ms as METRIC LABEL_ms.
# The step's stdout/stderr goes to step_LABEL.log (excerpted on failure).
run_timed() {
  local label=$1
  shift
  local t0 t1 rc=0
  CURRENT_STEP=$label
  t0=$(now_ms)
  "$@" >"step_${label}.log" 2>&1 || rc=$?
  t1=$(now_ms)
  if [ "$rc" -ne 0 ]; then
    step_failed "$label" "step '$label' exited $rc: $*"
    return "$rc"
  fi
  metric "${label}_ms" $((t1 - t0)) ms
  LAST_MS=$((t1 - t0))
}

# run_expect_fail LABEL cmd args... — as run_timed but the step MUST exit
# non-zero (e.g. LEC on an injected bug). A zero exit fails the test.
run_expect_fail() {
  local label=$1
  shift
  local t0 t1 rc=0
  CURRENT_STEP=$label
  t0=$(now_ms)
  "$@" >"step_${label}.log" 2>&1 || rc=$?
  t1=$(now_ms)
  if [ "$rc" -eq 0 ]; then
    step_failed "$label" "step '$label' was expected to detect a problem (non-zero exit) but passed: $*"
    return 1
  fi
  metric "${label}_ms" $((t1 - t0)) ms
  LAST_MS=$((t1 - t0))
}

# abc_incr_counts RESULT_JSON — echo "hits misses hit_ms miss_ms store_failed"
# from the pass.abc incremental report (or "MISSING" when it has none).
#
# The counts alone are NOT a speedup measure: minion once reported 199 hits of
# 264 regions and saved 2% of the runtime, because the regions that missed held
# essentially all the mapping time. `miss_ms` is the number that answers "did
# incremental help", and `store_failed` names the bug behind a stuck one — a
# region the cache could not snapshot re-runs ABC on every iteration forever
# (unlike `uncacheable`, which is a principled, documented refusal).
abc_incr_counts() {
  python3 - "$1" <<'PY'
import json, sys
def find(o, key):
    if isinstance(o, dict):
        if key in o:
            return o[key]
        for v in o.values():
            if (r := find(v, key)) is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            if (r := find(v, key)) is not None:
                return r
    return None
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("MISSING")
    raise SystemExit
inc = find(d, "incremental")
if not isinstance(inc, dict):
    print("MISSING")
    raise SystemExit
regions = find(d, "regions")
regions = regions if isinstance(regions, list) else []
failed = sum(1 for r in regions if r.get("cache") == "store-failed")
print(inc["hits"], inc["misses"], round(inc.get("hit_ms", 0)), round(inc.get("miss_ms", 0)), failed)
PY
}

# qor_totals QOR_JSON — echo "regions gates area max_delay" from the pass.abc
# QoR report's "total" member (or "MISSING").
qor_totals() {
  python3 - "$1" <<'PY'
import json, sys
try:
    t = json.load(open(sys.argv[1])).get("total") or {}
except Exception:
    t = {}
print(" ".join(str(t.get(k, "MISSING")) for k in ("regions", "gates", "area", "max_delay")))
PY
}

# rate NAME NUMERATOR MS UNIT — NAME = NUMERATOR / (MS/1000), guarded.
rate() {
  local ms=$3
  [ "$ms" -gt 0 ] || ms=1
  metric "$1" "$(python3 -c "print(round($2*1000/$ms,1))")" "$4"
}

# loc FILES... / words FILES... — input-size measures for throughput metrics.
loc() { cat "$@" | grep -cve '^[[:space:]]*$' || true; }
words() { cat "$@" | wc -w | tr -d ' '; }

# Verilog source list, resolved from filelist.f (paths are relative to it).
# Blank lines and `//` comments are skipped, matching slang's -F parsing.
core_v_sources() {
  local f
  while IFS= read -r f; do
    case "$f" in
    "" | //*) continue ;;
    esac
    printf '%s\n' "$CORE_V_DIR/$f"
  done <"$CORE_V_DIR/filelist.f"
}

require_tech_dir() {
  local lib="${HAGENT_TECH_DIR:-}/sky130_fd_sc_hd__tt_025C_1v80.lib"
  if [ -z "${HAGENT_TECH_DIR:-}" ] || [ ! -f "$lib" ]; then
    cat >&2 <<'EOF'
FAIL: HAGENT_TECH_DIR is unset or does not contain
sky130_fd_sc_hd__tt_025C_1v80.lib. Install the sky130 PDK (ciel is the
recommended installer — see README.md) and export HAGENT_TECH_DIR to the
directory holding the Liberty file, e.g.:
  export HAGENT_TECH_DIR=$HOME/.ciel/sky130A/libs.ref/sky130_fd_sc_hd/lib
bazel passes it through the test sandbox (test --test_env=HAGENT_TECH_DIR).
EOF
    return 1
  fi
}

# copy_core_pyrope DEST — writable copy of the Pyrope tree for the
# edit/rebuild passes (runfiles are read-only symlinks). manifest.json is
# optional: dino ships one, minion does not.
copy_core_pyrope() {
  mkdir -p "$1"
  cp -L "$CORE_P_DIR"/*.prp "$1"/
  [ -f "$CORE_P_DIR/manifest.json" ] && cp -L "$CORE_P_DIR/manifest.json" "$1"/
  return 0
}

# copy_core_sources DEST — writable copy of both language trees.
copy_core_sources() {
  mkdir -p "$1/verilog"
  cp -L "$CORE_V_DIR"/*.sv "$CORE_V_DIR"/filelist.f "$1/verilog/"
  # .svh includes (minion has them; dino does not)
  cp -L "$CORE_V_DIR"/*.svh "$1/verilog/" 2>/dev/null || true
  copy_core_pyrope "$1/pyrope"
}

# apply_variant NAME DIR — overlay the checked-in <core>/tests/NAME/ files onto
# DIR (same filenames). Variants are ordinary patched source copies, so
# `diff <core>/pyrope/$CORE_UNIT.prp <core>/tests/bug1/$CORE_UNIT.prp` shows
# exactly what a scenario injects: bug1 = the unit's adder flipped to subtract
# (a real bug LEC/formal must catch), comment1 = a comment-only touch (nothing
# really changed; incremental caches must hit).
apply_variant() {
  local vdir="$CORE_TESTS_DIR/$1"
  [ -d "$vdir" ] || { echo "FAIL: variant '$1' not found at $vdir" >&2; return 1; }
  cp -fL "$vdir"/* "$2"/
}
