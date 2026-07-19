# Shared helpers for lhdsuite bench/test scripts. Source this; do not execute.
#
# Contract with bench/BUILD: every sh_test gets
#   MODE          scenario selector within a script family
#   LHD           rlocationpath of @livehd//lhd:lhd
#   DINO_V_FLIST  rlocationpath of dino/verilog/filelist.f
#   DINO_P_TOP    rlocationpath of dino/pyrope/PipelinedDualIssueCPU.prp
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

LHD_BIN=$(rloc "${LHD:?LHD env var unset — set in bench/BUILD}")
DINO_V_DIR=$(cd "$(dirname "$(rloc "${DINO_V_FLIST:?}")")" && pwd)
DINO_P_DIR=$(cd "$(dirname "$(rloc "${DINO_P_TOP:?}")")" && pwd)
DINO_DIR=$(dirname "$DINO_P_DIR")
DINO_SIM_DIR=$DINO_DIR/sim
DINO_VERIF_DIR=$DINO_DIR/verif
DINO_TESTS_DIR=$DINO_DIR/tests
WORK=${TEST_TMPDIR:?}
cd "$WORK"

METRICS=${TEST_UNDECLARED_OUTPUTS_DIR:-$WORK}/metrics.jsonl
: >"$METRICS"

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
    "$DINO_P_DIR"*) a="dino/pyrope${a#"$DINO_P_DIR"}" ;;
    "$DINO_V_DIR"*) a="dino/verilog${a#"$DINO_V_DIR"}" ;;
    "$DINO_SIM_DIR"*) a="dino/sim${a#"$DINO_SIM_DIR"}" ;;
    "$DINO_VERIF_DIR"*) a="dino/verif${a#"$DINO_VERIF_DIR"}" ;;
    "$DINO_TESTS_DIR"*) a="dino/tests${a#"$DINO_TESTS_DIR"}" ;;
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

# metric NAME VALUE UNIT — one greppable human line + one JSONL record that
# bazel collects into the test's outputs.zip.
metric() {
  printf 'METRIC %-32s %12s %s\n' "$1" "$2" "$3"
  printf '{"name":"%s","value":%s,"unit":"%s"}\n' "$1" "$2" "$3" >>"$METRICS"
}

# run_timed LABEL cmd args... — run a step, record wall ms as METRIC LABEL_ms.
# The step's stdout/stderr goes to step_LABEL.log (dumped on failure).
run_timed() {
  local label=$1
  shift
  local t0 t1 rc=0
  CURRENT_STEP=$label
  t0=$(now_ms)
  "$@" >"step_${label}.log" 2>&1 || rc=$?
  t1=$(now_ms)
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: step '$label' exited $rc: $*" >&2
    tail -60 "step_${label}.log" >&2
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
    echo "FAIL: step '$label' was expected to detect a problem (non-zero exit) but passed: $*" >&2
    tail -60 "step_${label}.log" >&2
    return 1
  fi
  metric "${label}_ms" $((t1 - t0)) ms
  LAST_MS=$((t1 - t0))
}

# abc_incr_counts RESULT_JSON — echo "hits misses" from the pass.abc
# incremental counters (or "MISSING" when the envelope has none).
abc_incr_counts() {
  python3 - "$1" <<'PY'
import json, sys
def find(o):
    if isinstance(o, dict):
        if "hits" in o and "misses" in o:
            return o
        for v in o.values():
            if (r := find(v)) is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            if (r := find(v)) is not None:
                return r
    return None
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("MISSING")
    raise SystemExit
inc = d.get("incremental") if isinstance(d, dict) else None
inc = inc if isinstance(inc, dict) else find(d)
print(f'{inc["hits"]} {inc["misses"]}' if inc else "MISSING")
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
dino_v_sources() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && printf '%s\n' "$DINO_V_DIR/$f"
  done <"$DINO_V_DIR/filelist.f"
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

# copy_dino_sources DEST — writable copy of both language trees for the
# edit/rebuild passes (runfiles are read-only symlinks).
copy_dino_sources() {
  mkdir -p "$1/verilog" "$1/pyrope"
  cp -L "$DINO_V_DIR"/*.sv "$DINO_V_DIR"/filelist.f "$1/verilog/"
  cp -L "$DINO_P_DIR"/*.prp "$DINO_P_DIR"/manifest.json "$1/pyrope/"
}

# apply_variant NAME DIR — overlay the checked-in dino/tests/NAME/ files onto
# DIR (same filenames). Variants are ordinary patched source copies, so
# `diff dino/pyrope/ALU.prp dino/tests/bug1/ALU.prp` shows exactly what a
# scenario injects: bug1 = the ALU's 32-bit add flipped to subtract (a real
# bug LEC/formal must catch), comment1 = a comment-only touch (nothing really
# changed; incremental caches must hit).
apply_variant() {
  local vdir="$DINO_TESTS_DIR/$1"
  [ -d "$vdir" ] || { echo "FAIL: variant '$1' not found at $vdir" >&2; return 1; }
  cp -fL "$vdir"/* "$2"/
}
