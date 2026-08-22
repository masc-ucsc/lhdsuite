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
#   CORE_SIM_TB_UNIT  module CORE_SIM_TB drives, i.e. the name it spells in its
#                     `import("lg:NAME")`. MODE=pyrope compiles that unit's
#                     source ahead of the testbench; MODE=verilog hands over an
#                     `lg:` library rooted at it (NOT at CORE_TOP — `lhd sim`
#                     cgen's every graph it is given). See defs.bzl
#   CORE_SIM_TB_V     MODE=verilog override for CORE_SIM_TB ("" = same driver
#                     for both modes); needed when the two sides declare a port
#                     differently. See defs.bzl
#   CORE_SIM_SETS     extra `--set k=v` flags for this core's `lhd sim` runs
#                     ("" = none); NOT passed to the verilator scenario
#   CORE_SIM_MARKER   string proving the benchmark reached its final report
#   CORE_SIM_EXPECT   string the asserted sim's output must also contain — the
#                     testbench's known-good data readback ("" = skip)
#   CORE_SIM_TOP_TB   whole-top testbench ("" = none)
#   CORE_SIM_TOP_CYCLES  explicit `cycles` value for CORE_SIM_TOP_TB
#   CORE_SIM_PROG_TB  program testbench ("" = none)
#   CORE_SIM_PROG_CYCLES explicit `cycles` value for CORE_SIM_PROG_TB
#   CORE_SIM_PROG_PYROPE_ONLY  "1" = CORE_SIM_PROG_TB drives a module that
#                     exists only in the Pyrope tree, so MODE=verilog skips it
#                     (no lg: compile, no sim_cpu_prog_ok metric); "" = run it
#                     in both modes. See defs.bzl.
#   CORE_SIM_TOP_ASSERT  "1" = the two above GATE the target (a driver that
#                     fails fails the test); "" = report them as metrics only.
#                     Always metrics either way. See defs.bzl.
#   CORE_LEC_TRUST    comma-separated module-def names the LEC scenarios ASSUME
#                     equivalent without proving them (latch escape hatch; ""
#                     = trust nothing). When set, lec.sh also runs strict so a
#                     witness-free UNKNOWN top is a hard fail. See defs.bzl
#   CORE_VERILATOR_TB      C++ testbench for the Verilator comparison ("" = the
#                     core has none, and no sim_verilator target is generated)
#   CORE_VERILATOR_FLAGS   extra verilator options for this core (may be empty)
#   CORE_VERILATOR_CYCLES  cycle count for the LONG verilator throughput run
#                     (see bench/sim_verilator.sh for why the matched-count run
#                     alone cannot measure it).
# Paths are runfiles-relative; resolve them with rloc before use. Scripts run
# inside $TEST_TMPDIR so every pass/workdir is hermetic per test. Scripts set
# RF (runfiles root) before sourcing this file, which also makes plain
# `bazel run //bench:<target>` work for debugging (no TEST_* env).

set -euo pipefail

if [ -z "${TEST_SRCDIR:-}" ]; then
  TEST_SRCDIR="${RF:?source common.sh from a bench script (RF unset)}"
fi
: "${TEST_TMPDIR:=$(mktemp -d "${TMPDIR:-/tmp}/lhdbench.XXXXXX")}" 

# The two largest XiangShan synthesis scenarios have a hard 30-minute
# end-to-end budget. Re-exec the complete scenario under coreutils timeout so
# setup/compile/color/ABC/STA all count, not just one selected command.
if [ -n "${CORE_SYNTH_BUDGET_S:-}" ] && [ -z "${CORE_SYNTH_BUDGET_ACTIVE:-}" ]; then
  export CORE_SYNTH_BUDGET_ACTIVE=1
  set +e
  timeout --foreground "$CORE_SYNTH_BUDGET_S" "$0" "$@"
  budget_rc=$?
  set -e
  if [ "$budget_rc" = 124 ]; then
    echo "FAIL: end-to-end synthesis exceeded ${CORE_SYNTH_BUDGET_S}s budget" >&2
  fi
  exit "$budget_rc"
fi

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
CORE_P_STUB_DIR=
if [ -n "${CORE_P_STUB_TOP:-}" ]; then
  CORE_P_STUB_DIR=$(cd "$(dirname "$(rloc "$CORE_P_STUB_TOP")")" && pwd)
fi
CORE_DIR=$(dirname "$CORE_P_DIR")
CORE_SIM_DIR=$CORE_DIR/sim
CORE_VERIF_DIR=$CORE_DIR/verif
CORE_TESTS_DIR=$CORE_DIR/tests
: "${CORE_TOP:?}" "${CORE_UNIT:?}" "${CORE_COLOR_ALGS:?}"
: "${CORE_SYNTH_ONLY=}" "${CORE_SYNTH_BUDGET_S=}"
: "${CORE_V_FLAGS=}" "${CORE_SIM_MARKER=}" "${CORE_SIM_EXPECT=}" "${CORE_LEC_TRUST=}" "${CORE_SIM_TB_V=}"
: "${CORE_SIM_SETS=}"
: "${CORE_SIM_CYCLES=}" "${CORE_SIM_TB_UNIT=}" "${CORE_SIM_PERF_CYCLES=}"
: "${CORE_SIM_TOP_UNIT=}" "${CORE_SIM_PROG_UNIT=}"
: "${CORE_SIM_TOP_CYCLES=}" "${CORE_SIM_PROG_CYCLES=}"
: "${CORE_SIM_PROG_PYROPE_ONLY=}"
: "${CORE_VERILATOR_TB=}" "${CORE_VERILATOR_FLAGS=}" "${CORE_VERILATOR_CYCLES=}"
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
# sanitize_args ARGS... — echo the arguments with the runfiles paths folded
# back to repo-relative form, so a logged command line is one a reader can
# retype in a checkout.
sanitize_args() {
  local out="" a
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
  printf '%s' "${out# }"
}
lhd() {
  printf 'CMD %s: lhd %s\n' "${CURRENT_STEP:--}" "$(sanitize_args "$@")" >&3
  "$LHD_BIN" "$@"
}
# vlt — the same wrapper for verilator (bench/sim_verilator.sh). Named `vlt`,
# not `verilator`, so that find_verilator's PATH lookup cannot resolve to this
# function instead of the tool.
vlt() {
  printf 'CMD %s: verilator %s\n' "${CURRENT_STEP:--}" "$(sanitize_args "$@")" >&3
  "${VERILATOR_BIN:?call find_verilator first}" "$@"
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

# ---- simulation benchmarks (bench/sim.sh, bench/sim_verilator.sh) -----------

# sim_gate LABEL — the two output gates every simulation bench applies to a
# step's log. $CORE_SIM_MARKER proves the driver reached its final report;
# $CORE_SIM_EXPECT is the testbench's known-good data readback, and guards
# against a sim that runs but computes wrong values (a silently-miscompiled
# schedule prints data=0 and would otherwise go green). Both simulators are
# held to the SAME two strings, so `lhd sim` and verilator disagreeing about
# the design fails a target instead of quietly reporting two numbers.
# SIM_GATE_EXPECT=0 relaxes the gate to the MARKER alone for one call. Two
# callers need that and neither is a loophole: an incremental scenario's pass 3
# deliberately injects a bug, so the checksum MUST move, and the throughput leg
# runs a different cycle count, which is a different checksum by construction.
# The marker gate always applies — a sim that never reached its readback is a
# failure in every mode.
sim_gate() {
  grep -qa -- "$CORE_SIM_MARKER" "step_$1.log" \
    || { step_failed "$1" "sim ran but printed no '$CORE_SIM_MARKER' marker"; exit 1; }
  [ "${SIM_GATE_EXPECT:-1}" != 0 ] || return 0
  [ -n "$CORE_SIM_EXPECT" ] || return 0
  # No extra grep: the sim's readback is the last thing it prints, so it is
  # already inside the excerpt step_failed shows.
  grep -qa -- "$CORE_SIM_EXPECT" "step_$1.log" \
    || { step_failed "$1" "sim ran but data is wrong (expected '$CORE_SIM_EXPECT')"; exit 1; }
}

# best_run LABEL REPS CMD... — run CMD REPS times, apply sim_gate to every run,
# and leave the FASTEST wall time in $BEST_MS.
#
# BEST, not mean, and not one sample. A simulation is the shortest thing this
# suite times and the one it most wants to be honest about, and a dev box
# stalls: measured on ONE unchanged binary, repeated back-to-back runs gave
# 8 x ~1.25 s, one 3.0 s and one 17.4 s. A mean carries the stall and a single
# sample IS the stall one run in ten, so take the minimum — the standard
# estimator for "how fast does this go" under one-sided noise.
best_run() {
  local label=$1 reps=$2
  shift 2
  local rep t0 t1 ms
  BEST_MS=
  for rep in $(seq "$reps"); do
    t0=$(now_ms)
    CURRENT_STEP=$label "$@" >"step_${label}.log" 2>&1 \
      || { step_failed "$label" "'$label' exited non-zero on its own (rep $rep): $*"; exit 1; }
    t1=$(now_ms)
    ms=$((t1 - t0))
    { [ -n "$BEST_MS" ] && [ "$BEST_MS" -le "$ms" ]; } || BEST_MS=$ms
    sim_gate "$label"
  done
}

# cpu_count — cores to hand a parallel host compile. `lhd sim`'s own build uses
# every core, so the verilator side must too or sim_cc_ms compares a parallel
# compile against a serial one.
cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; }

# find_verilator — set $VERILATOR_BIN, or return non-zero if there is no
# verilator on this machine. Verilator is host state, not a bazel input (same
# shape as HAGENT_TECH_DIR): $VERILATOR wins, then PATH, then the usual install
# prefixes, because bazel's test PATH does not carry /opt/homebrew/bin.
#
# Unlike require_tech_dir this does NOT fail the target. A missing tech library
# breaks a scenario the suite is responsible for; a missing verilator only
# removes an outside point of comparison, so bench/sim_verilator.sh SKIPS
# (reporting METRIC verilator_present 0) rather than painting //bench:<core>
# red on every machine that has not installed it.
find_verilator() {
  VERILATOR_BIN=${VERILATOR:-}
  if [ -z "$VERILATOR_BIN" ]; then
    VERILATOR_BIN=$(type -P verilator || true)
  fi
  if [ -z "$VERILATOR_BIN" ]; then
    local c
    for c in /opt/homebrew/bin/verilator /usr/local/bin/verilator /usr/bin/verilator; do
      if [ -x "$c" ]; then
        VERILATOR_BIN=$c
        break
      fi
    done
  fi
  [ -n "$VERILATOR_BIN" ] && "$VERILATOR_BIN" --version >/dev/null 2>&1
}

# abc_incr_counts RESULT_JSON — echo "hits misses hit_ms miss_ms store_failed"
# from the abc incremental report (or "MISSING" when the region cache did not
# run). Read from the envelope's `incremental.abc` member first — the ONE place
# `lhd synth` and `lhd pass abc` both report every reuse tier (enabled=false
# there is an honest cold map, not a missing report) — and only then from the
# pass's own qor object, for an envelope written by an older lhd.
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
tier = (d.get("incremental") or {}).get("abc") if isinstance(d, dict) else None
if isinstance(tier, dict):
    if not tier.get("enabled", False):
        print("MISSING")
        raise SystemExit
    print(tier["hits"], tier["misses"], round(tier.get("hit_ms", 0)), round(tier.get("miss_ms", 0)),
          tier.get("store_failed", 0))
    raise SystemExit
inc = find(d.get("qor", d) if isinstance(d, dict) else d, "incremental")
if not isinstance(inc, dict) or "hits" not in inc:
    print("MISSING")
    raise SystemExit
regions = find(d, "regions")
regions = regions if isinstance(regions, list) else []
failed = sum(1 for r in regions if r.get("cache") == "store-failed")
print(inc["hits"], inc["misses"], round(inc.get("hit_ms", 0)), round(inc.get("miss_ms", 0)), failed)
PY
}

# synth_phase_ms RESULT_JSON — echo "compile color abc sta" (ms, integers) from
# an `lhd synth` envelope's `phases`: the three synth passes by name, and
# `compile` = every other phase (front end, recipe, run_id, library saves).
# Duplicate phase names are summed, as the envelope's contract says.
synth_phase_ms() {
  python3 - "$1" <<'PY'
import json, sys
by = {}
try:
    for p in json.load(open(sys.argv[1])).get("phases", []):
        by[p["name"]] = by.get(p["name"], 0.0) + float(p["ms"])
except Exception:
    pass
color, abc, sta = by.pop("pass.color", 0.0), by.pop("pass.abc", 0.0), by.pop("pass.opentimer", 0.0)
print(round(sum(by.values())), round(color), round(abc), round(sta))
PY
}

# compile_incr_field RESULT_JSON KEY — one counter of the envelope's
# `incremental.compile` tier ("" when the run had no user --workdir).
compile_incr_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))["incremental"]["compile"][sys.argv[2]])
except Exception:
    print("")
PY
}

# qor_totals QOR_JSON — echo "regions gates area max_delay div_blackbox" from the pass.abc
# QoR report's "total" member (or "MISSING").
qor_totals() {
  python3 - "$1" <<'PY'
import json, sys
try:
    t = json.load(open(sys.argv[1])).get("total") or {}
except Exception:
    t = {}
print(" ".join(str(t.get(k, 0 if k == "div_blackbox" else "MISSING"))
               for k in ("regions", "gates", "area", "max_delay", "div_blackbox")))
PY
}

# sta_max_delay TIMING_JSON — echo the worst whole-design OpenTimer delay (or
# MISSING). pass.opentimer currently emits one selected design per invocation;
# max() keeps this helper correct if that envelope grows later.
sta_max_delay() {
  python3 - "$1" <<'PY'
import json, sys
try:
    ds = json.load(open(sys.argv[1])).get("designs") or []
    values = [float(d["max_delay"]) for d in ds if "max_delay" in d]
except Exception:
    values = []
print(max(values) if values else "MISSING")
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

# compile_input_stats RESULT_JSON SOURCE_DIR [STUB_DIR] — print "lines words" for the exact Pyrope
# import cone reported by lhd, rather than every file in a shared source tree.
compile_input_stats() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, os, sys
paths = json.load(open(sys.argv[1])).get("inputs", [])
lines = words = 0
# The explicit top can appear twice in a sandbox envelope (once via the
# command path and once via sibling discovery); a compilation unit is counted
# once, matching `lhd scan`'s build graph.
unique = {os.path.basename(path): path for path in paths}
for base, path in unique.items():
    # lhd's result envelope makes sandbox paths workspace-relative. Those
    # paths are intentionally not meaningful after lhd returns to the shell;
    # every imported unit is present in the resolved runfiles source dir.
    if not os.path.isfile(path):
        path = os.path.join(sys.argv[2], base)
    if not os.path.isfile(path) and sys.argv[3]:
        path = os.path.join(sys.argv[3], base)
    with open(path, "r", errors="replace") as f:
        for line in f:
            lines += 1
            words += len(line.split())
print(lines, words)
PY
}

# scan_cone_stats SCAN_JSON TOP — the same exact-cone source count for the
# generated per-file build, whose individual compile result envelopes cannot
# conveniently be merged.
scan_cone_stats() {
  python3 - "$1" "$2" <<'PY'
import json, os, sys
entries = json.load(open(sys.argv[1]))["scan"]
src = {os.path.basename(e["file"])[:-4]: e["file"] for e in entries}
deps = {os.path.basename(e["file"])[:-4]:
        {i.split(".")[0] for i in e["imports"] if i.split(".")[0] in src}
        for e in entries}
seen, stack = set(), [sys.argv[2]]
while stack:
    unit = stack.pop()
    if unit in seen:
        continue
    seen.add(unit)
    stack.extend(deps[unit])
lines = words = 0
for unit in seen:
    with open(src[unit], "r", errors="replace") as f:
        for line in f:
            lines += 1
            words += len(line.split())
print(lines, words)
PY
}

require_tech_dir() {
  # Resolve the PDK from ciel every time.  In particular, do not trust an
  # inherited HAGENT_TECH_DIR: it can silently pin a benchmark to an older
  # library after `ciel enable` moves on.
  # ciel is host state like verilator (find_verilator): bazel's sanitized test
  # PATH does not carry /opt/homebrew/bin or pip's user bin, so probe the usual
  # install prefixes before giving up.
  if ! command -v ciel >/dev/null 2>&1; then
    local prefix
    for prefix in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/Library/Python/3.9/bin"; do
      if [ -x "$prefix/ciel" ]; then
        PATH="$prefix:$PATH"
        break
      fi
    done
  fi
  command -v ciel >/dev/null 2>&1 || {
    echo "FAIL: synthesis benchmarks require 'ciel' on PATH (see README.md)" >&2
    return 1
  }

  local installed_json hashes count enabled latest rendered dates lib root
  installed_json=$(ciel ls --pdk-family sky130) || {
    echo "FAIL: could not enumerate installed sky130 versions with ciel" >&2
    return 1
  }
  # ("\n", not "\\n": inside the single quotes python must see a real newline
  # escape — the doubled form joined two installed hashes into ONE line, so a
  # two-version install looked like a single bogus version.)
  hashes=$(python3 -c 'import json,sys; print("\n".join(json.loads(sys.stdin.read())))' <<<"$installed_json") || {
    echo "FAIL: ciel returned an invalid installed-version list: $installed_json" >&2
    return 1
  }
  count=$(printf '%s\n' "$hashes" | grep -c . || true)
  [ "$count" -gt 0 ] || {
    echo "FAIL: ciel has no installed sky130 version (see README.md)" >&2
    return 1
  }

  enabled=$(ciel output --pdk-family sky130) || {
    echo "FAIL: ciel has no enabled sky130 version" >&2
    return 1
  }

  if [ "$count" -eq 1 ]; then
    # One installed version is newest regardless of whether ciel can obtain
    # release-date metadata (offline machines commonly cannot).
    latest=$hashes
  else
    # `ciel ls` deliberately emits dates only to a tty.  Give it a small pty
    # and parse the rendered YYYY.MM.DD values; this is portable across the
    # GNU/BSD variants of the external `script` utility.
    #
    # The read loop polls with select() and reaps the child with WNOHANG: on
    # macOS a blocking read() of the pty master does NOT fail with EIO once
    # the child has exited (Linux does), it blocks forever -- which is exactly
    # what every synth target did the first time two sky130 versions were
    # installed on a Mac.
    rendered=$(python3 - <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("ciel", ["ciel", "ls", "--pdk-family", "sky130"])
chunks = []
status = None
deadline = time.monotonic() + 120.0
while time.monotonic() < deadline:
    if status is None:
        wpid, st = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            status = st
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if data:
            chunks.append(data)
            continue
        if status is not None:
            break  # EOF after the child exited: fully drained
        time.sleep(0.05)  # readable-but-empty while the child lives: a pty hiccup, not EOF
        continue
    if status is not None:
        break  # child gone and nothing left to drain
if status is None:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)
os.close(fd)
sys.stdout.buffer.write(b"".join(chunks))
raise SystemExit(os.waitstatus_to_exitcode(status))
PY
    ) || {
      echo "FAIL: could not obtain dated sky130 version list from ciel" >&2
      return 1
    }
    dates=$(python3 -c '
import re,sys
# single backslashes: this is a single-quoted bash string, so python sees
# exactly what is written here (\\s would be a literal backslash + s)
s=re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read())
for h,d in re.findall(r"([0-9a-f]{7,64})\s+\((\d{4}\.\d{2}\.\d{2})\)", s):
    print(d, h)
' <<<"$rendered")
    [ "$(printf '%s\n' "$dates" | grep -c . || true)" -eq "$count" ] || {
      echo "FAIL: ciel listed $count sky130 versions but did not provide all release dates; cannot choose the newest safely" >&2
      printf '%s\n' "$rendered" >&2
      return 1
    }
    latest=$(printf '%s\n' "$dates" | sort -r | head -1 | awk '{print $2}')
  fi

  [ "$latest" = "$enabled" ] || {
    echo "FAIL: newest installed sky130 version ($latest) differs from ciel-enabled version ($enabled)" >&2
    echo "      run 'ciel enable --pdk-family sky130 $latest' or remove the unintended version" >&2
    return 1
  }

  root=$(ciel path --pdk-family sky130 "$latest") || {
    echo "FAIL: ciel could not resolve sky130 version $latest" >&2
    return 1
  }
  HAGENT_TECH_DIR="$root/sky130A/libs.ref/sky130_fd_sc_hd/lib"
  lib="$HAGENT_TECH_DIR/sky130_fd_sc_hd__tt_025C_1v80.lib"
  [ -f "$lib" ] || {
    echo "FAIL: ciel sky130 version $latest does not contain $lib" >&2
    return 1
  }
  PDK_VERSION=$latest
  export HAGENT_TECH_DIR PDK_VERSION
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

# apply_synth_only_variant NAME DIR — synth-only cores deliberately have no
# tests/ overlays. Make equivalent edits to their writable top copy without
# naming any design in this shared script.
apply_synth_only_variant() {
  local name=$1 dir=$2 edit_unit=$CORE_TOP
  if [ "$name" = bug1 ] && [ -n "${CORE_INCR_EDIT_UNIT:-}" ]; then
    edit_unit=$CORE_INCR_EDIT_UNIT
  fi
  local file="$2/$edit_unit.prp" tmp="$2/$edit_unit.prp.tmp"
  case "$name" in
  comment1)
    printf '\n// lhdsuite incremental comment-only touch\n' >>"$file"
    ;;
  bug1)
    # By default every imported XiangShan top drives at least one public output
    # through `... & 1`; invert exactly the first such output. A core may name
    # a small, definitely-instantiated stateful leaf instead: Backend's huge
    # generated output expression makes its cache-disabled cold cprop exceed
    # Bazel's one-hour test ceiling, while inverting DelayN_6.io_out remains a
    # real hierarchical behavior change and keeps H5 runnable.
    #
    # The rewrite REPLACES the whole right-hand side with `(RHS) ^ 1` rather
    # than swapping an inner `&` for a `^`. Both the anchor and the parentheses
    # are load-bearing:
    #   * anchoring the match at end-of-line takes the LAST `& 1`, so the value
    #     being inverted is one bit wide and the assignment cannot narrow;
    #   * parenthesizing keeps Pyrope's shallow precedence happy. Rewriting an
    #     inner `&` in place produced `a & (b >> 8) ^ 1 & 1` on `Rob`, which is
    #     `error[syntax]: operators at the same precedence cannot be mixed
    #     without parentheses` — i.e. xs_rob's bug1 pass could never compile.
    local anchor='^  io_[A-Za-z0-9_.]+ = .+ & 1$'
    if [ "$edit_unit" != "$CORE_TOP" ]; then
      anchor='^  io_[A-Za-z0-9_.]+ = .+$'
    fi
    awk -v anchor="$anchor" '
      !done && $0 ~ anchor {
        eq  = index($0, " = ")
        $0  = substr($0, 1, eq + 2) "(" substr($0, eq + 3) ") ^ 1"
        done = 1
        printf "%d\t%s\n", NR, $0 > "/dev/stderr"
      }
      { print }
      END { if (!done) exit 42 }
    ' "$file" 2>"$dir/.variant_site" >"$tmp" || {
      rm -f "$tmp"
      echo "FAIL: no generic one-line incremental edit found in $edit_unit.prp" >&2
      return 1
    }
    mv "$tmp" "$file"
    ;;
  *)
    echo "FAIL: unknown synth-only variant '$name'" >&2
    return 1
    ;;
  esac
}

# core_variant NAME DIR — apply variant NAME the way THIS core supports it, and
# say on the main output exactly what was injected.
#
# The disclosure is not decoration (T11). A synthesized edit leaves no diff in
# git, so the log line is the only record of the site pass 3 measured; a
# regression that silently moved the edit to a different net would otherwise
# change what the scenario measures with nothing to show for it. A variant that
# finds no site is a hard failure, never a skipped edit.
core_variant() {
  local name=$1 dir=$2
  if [ -n "${CORE_SYNTH_ONLY:-}" ]; then
    apply_synth_only_variant "$name" "$dir" || return 1
    local variant_unit=$CORE_TOP
    if [ "$name" = bug1 ] && [ -n "${CORE_INCR_EDIT_UNIT:-}" ]; then
      variant_unit=$CORE_INCR_EDIT_UNIT
    fi
    if [ -s "$dir/.variant_site" ]; then
      printf 'VARIANT %s: %s.prp:%s\n' "$name" "$variant_unit" \
        "$(tr '\t' ' ' <"$dir/.variant_site" | head -1)" >&3
    else
      printf 'VARIANT %s: appended to %s.prp\n' "$name" "$CORE_TOP" >&3
    fi
    rm -f "$dir/.variant_site"
  else
    apply_variant "$name" "$dir" || return 1
    printf 'VARIANT %s: overlaid %s\n' "$name" \
      "$(cd "$CORE_TESTS_DIR/$name" && echo *)" >&3
  fi
}

# dir_bytes DIR — apparent size of a cache/workdir in bytes, 0 when absent.
# Cache size is a real cost (H6 workdir_bytes), so every incremental scenario
# reports it rather than letting a lever buy time with unbounded disk.
dir_bytes() {
  [ -d "$1" ] || { echo 0; return 0; }
  # -k is the one du unit POSIX guarantees; BSD and GNU disagree on -b/-A.
  echo $(($(du -sk "$1" 2>/dev/null | awk '{print $1}') * 1024))
}

# tree_fingerprint DIR [FIND-ARGS...] — sorted "sha  relpath" listing of a
# generated tree, for the H5 "warm equals cold" check (I2). Content, not
# mtimes: a warm pass that legitimately skips a rewrite must still leave the
# same bytes on disk as a cold pass would have written.
tree_fingerprint() {
  local dir=$1
  shift
  (cd "$dir" 2>/dev/null || exit 0
   find . -type f "$@" -print0 2>/dev/null | LC_ALL=C sort -z \
     | xargs -0 shasum -a 256 2>/dev/null)
}
