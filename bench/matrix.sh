#!/usr/bin/env bash
# bench/matrix.sh — the full x cold x incremental measurement matrix.
#
#   ./bench/matrix.sh <core> [phase ...]      # run from the lhdsuite checkout
#
# phases: compile | synth | sim | sim_llvm | lec   (default: all five)
#
# Produces one JSON-LINES row per (phase, mode) on stdout-adjacent
# $MATRIX_OUT (default matrix_rows.jsonl), ready for
#
#   bazel run //bench:ledger -- add --config-id <id> matrix_rows.jsonl
#
# which stamps the host/sha/pdk identity block and appends to bench/ledger.jsonl.
# Nothing here writes the ledger directly: the ledger is DERIVED, and a row
# without an identity block is unusable (docs/opt_loop_incr.md H6).
#
# WHY THIS EXISTS SEPARATELY FROM THE bazel BENCHES. The //bench targets answer
# "is this scenario green and how long did it take". This answers a different
# question — where does the time GO, and what does each layer of caching
# actually buy — across four flows and three cache states, which is 12 runs per
# core and far past a test's business. It is deliberately runnable outside
# bazel, because the matrix takes tens of minutes and wants to be resumable.
#
# THE THREE MODES, and they are not interchangeable:
#
#   full         every cache is off (the ONE switch: lhd.incremental=false covers
#                the compile, pass.abc and formal caches), every output directory
#                fresh. What the flow
#                costs with no incremental machinery at all.
#   cold         caches on, every directory still fresh. Same work as `full`
#                PLUS the cost of populating the caches. `cold - full` is
#                therefore the price of admission for incrementality, and it is
#                a number worth watching: a cache that costs 20% on every clean
#                build is not free.
#   incremental  the identical command again over the same workdir, after a
#                COMMENT-ONLY touch to the design. Nothing semantic changed, so
#                every content-keyed cache must hit.
#
#   `compile` full sets lhd.incremental=false; `sim` still has no cache off-switch,
#   so its full and cold commands are expected to match within noise.
#
# TRAP T12 (docs/opt_loop_incr.md): this class of machine drifts. An M5 Max was
# measured taking 86.8 s and later 144.4 s for one identical, untouched command
# after hours of load. So every phase runs its three modes BACK TO BACK, and a
# fixed control command is timed at the start and end of the whole matrix; the
# drift between them is recorded in a `control` row. Never compare a number here
# against one from a different sitting.
set -u -o pipefail

CORE=${1:?usage: bench/matrix.sh <core> [phase ...]}
shift || true
PHASES=${*:-compile synth sim sim_llvm lec}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LHD=${LHD:-$ROOT/../livehd/bazel-bin/lhd/lhd}
[ -x "$LHD" ] || { echo "FAIL: no lhd at $LHD (set \$LHD)" >&2; exit 2; }
OUT=${MATRIX_OUT:-$ROOT/matrix_rows.jsonl}
WORK=${MATRIX_WORK:-${TMPDIR:-/tmp}/lhd_matrix_$CORE}

# One config_id per SITTING, not per core: a matrix run over several cores is
# one measurement of one build, and the scoreboard's baseline->current gate
# compares config_ids. Pass MATRIX_CONFIG_ID to group several cores into one.
CONFIG_ID=${MATRIX_CONFIG_ID:-matrix-$(date +%Y%m%d-%H%M)}
# The live scoreboard. Rendered after EVERY row (see publish), so the page is a
# status display during the run rather than an artifact produced after it.
HTML=${MATRIX_HTML:-$ROOT/../livehd/docs/current_opt_loop_incr.html}

# ---- per-core knobs, mirroring the CORES table in bench/defs.bzl -------------
# Kept as a small case rather than parsed out of defs.bzl: this script runs
# outside bazel, and a silent mismatch would be worse than a visible duplicate.
case "$CORE" in
dino)
  TOP=PipelinedDualIssueCPU; SIM_UNIT=$TOP; SIM_TB=dino_tb.prp
  # 2M, not 200k: at 200k the throughput run measured 38 ms, which is process
  # startup, not the simulator (T1). Re-check after any large sim speedup.
  SIM_CYCLES=1000; DEFAULT_PERF_CYCLES=2000000
  COLOR_ALG=synth; HAS_LEC=1; V_FLAGS=""; STUB_DIR="" ;;
minion)
  TOP=minion_top; SIM_UNIT=minion_top; SIM_TB=minion_prog_tb.prp
  SIM_CYCLES=20000; DEFAULT_PERF_CYCLES=200000
  # minion's RTL assigns enums from plain bits and references identifiers above
  # their declaration; without both relaxations the Verilog REFERENCE does not
  # compile and every lec mode records `passed:false`. Same flags as the
  # `v_flags` in bench/defs.bzl.
  COLOR_ALG=synth; HAS_LEC=1
  V_FLAGS="--relax-enum-conversions --allow-use-before-declare"; STUB_DIR="" ;;
xs_alu)
  TOP=Alu; SIM_UNIT=Alu; SIM_TB=xs_alu_tb.prp
  # 5M, not 500k: 500k measured 32 ms of mostly startup (T1). Alu runs at
  # ~15.6M cycles/s, so 5M keeps the throughput sample around a third of a
  # second and the I3 guardrail able to see a real regression.
  SIM_CYCLES=1000; DEFAULT_PERF_CYCLES=5000000
  COLOR_ALG=synth; HAS_LEC=0; V_FLAGS="--single-unit"
  STUB_DIR=${XS_STUB_DIR:-$ROOT/bazel-bin/xiangshan/Backend/synth_stubs} ;;
xs_renametable)
  # The medium XS target: 5,973 lines at the top, but a hierarchy of five
  # near-identical RenameTable* children plus three DPI wrappers, so it is the
  # block that exercises hierarchical + replica reuse at a size where the whole
  # five-phase matrix still fits the iteration budget (cold compile ~25 s, cold
  # sim ~63 s, against Rob's ~90 s / ~180 s). Its checksum is cross-validated:
  # the Pyrope and Verilog trees both print sum=7374455199715033088.
  TOP=RenameTableWrapper; SIM_UNIT=RenameTableWrapper; SIM_TB=xs_renametable_tb.prp
  SIM_CYCLES=1000; DEFAULT_PERF_CYCLES=5000
  COLOR_ALG=synth; HAS_LEC=0; V_FLAGS="--single-unit"
  STUB_DIR=${XS_STUB_DIR:-$ROOT/bazel-bin/xiangshan/Backend/synth_stubs} ;;
xs_rob)
  TOP=Rob; SIM_UNIT=Rob; SIM_TB=xs_rob_tb.prp
  SIM_CYCLES=1000; DEFAULT_PERF_CYCLES=20000
  COLOR_ALG=synth; HAS_LEC=0; V_FLAGS="--single-unit"
  STUB_DIR=${XS_STUB_DIR:-$ROOT/bazel-bin/xiangshan/Backend/synth_stubs} ;;
xs_backend)
  # The whole Backend: the largest block in the set, and the last of the four
  # XiangShan drivers under xiangshan/Backend/sim/ to get a matrix entry.
  #
  # DEFAULT_PERF_CYCLES is a PLACEHOLDER pending its first measurement (T1).
  # The other XS blocks were tuned from a known rate — Rob at ~15k cycles/s
  # takes 20k, RenameTableWrapper at ~26k takes 5k — and nothing has ever
  # simulated Backend here, so 2000 is a guess sized for a design an order of
  # magnitude bigger than Rob. Read the first `sim_exec_ms` this produces and
  # re-tune: a count that lands in the tens of ms is measuring process startup,
  # not the simulator, and the I3 guardrail cannot reject anything from it.
  TOP=Backend; SIM_UNIT=Backend; SIM_TB=xs_backend_tb.prp
  SIM_CYCLES=1000; DEFAULT_PERF_CYCLES=2000
  COLOR_ALG=synth; HAS_LEC=0; V_FLAGS="--single-unit"
  STUB_DIR=${XS_STUB_DIR:-$ROOT/bazel-bin/xiangshan/Backend/synth_stubs} ;;
*)
  echo "FAIL: unknown core '$CORE' (add it to the case in bench/matrix.sh)" >&2; exit 2 ;;
esac

case "$CORE" in
xs_*) PKG_DIR=$ROOT/xiangshan/Backend ;;
*)    PKG_DIR=$ROOT/$CORE ;;
esac
P_DIR=$PKG_DIR/pyrope
V_DIR=$PKG_DIR/verilog
SIM_DIR=$PKG_DIR/sim

# ---- PDK, resolved the same way bench/common.sh does ------------------------
PDK_VERSION=${PDK_VERSION:-}
if [ -z "${HAGENT_TECH_DIR:-}" ] || [ -z "$PDK_VERSION" ]; then
  if command -v ciel >/dev/null 2>&1; then
    _v=$(ciel output --pdk-family sky130 2>/dev/null || true)
    if [ -n "$_v" ]; then
      HAGENT_TECH_DIR="$HOME/.ciel/ciel/sky130/versions/$_v/sky130A/libs.ref/sky130_fd_sc_hd/lib/"
      PDK_VERSION=$_v
    fi
  fi
fi
export HAGENT_TECH_DIR PDK_VERSION

# The I3 guardrail is only a guardrail if its measurement clears the noise
# floor. $SIM_CYCLES is the functional/marker count; $SIM_PERF_CYCLES is the
# count `best_exec` times, tuned per core so `sim_exec_ms` is hundreds of ms
# rather than the tens that are mostly process startup (trap T1). Re-check it
# after any large sim speedup: a benchmark that has outrun its own cycle count
# reports startup and would let an I3 violation through.
SIM_PERF_CYCLES=${SIM_PERF_CYCLES:-$DEFAULT_PERF_CYCLES}

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# loadavg — the 1-minute run-queue length, sampled per row. The control probe
# is SINGLE-THREADED and therefore blind to the contention that matters most
# here: one desktop app pinning one core leaves the control at 36 ms while
# tripling a parallel host C++ build. Measured during this matrix, so this is
# not hypothetical. A row carrying a high load is not wrong, it is uncertain,
# and the page has to be able to say which.
loadavg() { uptime | sed -E 's/.*averages?: *([0-9.]+).*/\1/' | tr -d ' ' ; }

# ---- one row per (phase, mode), built from ONE OR MORE commands -------------
#
# A "phase" is rarely one command: synthesis is `pass color` then `pass abc`,
# and a sim rebuild is `--setup-only` then `--run-only`. The rebuild an edit
# costs is their SUM, so they belong in one row — and their result-jsons must be
# snapshotted between commands, because the second invocation overwrites the
# first's file. group_begin/step/group_end does both.
GRP_MS=0
GRP_OK=1
GRP_SNAPS=()
GRP_N=0

group_begin() {
  STEP_LAST_RC=0
  GRP_MS=0
  GRP_OK=1
  GRP_SNAPS=()
  GRP_N=$((GRP_N + 1))
}

# step PHASE MODE RESULT_JSON -- cmd...
step() {
  local phase=$1 mode=$2 rjson=$3
  shift 3
  [ "${1:-}" = -- ] && shift
  local log snap t0 t1 rc=0
  log="$WORK/log_${phase}_${mode}_${#GRP_SNAPS[@]}.log"
  echo "  [$CORE $phase/$mode] $*" >&2
  t0=$(now_ms)
  "$@" >"$log" 2>&1 || rc=$?
  t1=$(now_ms)
  GRP_MS=$((GRP_MS + t1 - t0))
  case " ${STEP_OK_CODES:-0} " in
  *" $rc "*) ;;                       # a completed measurement, whatever it decided
  *) GRP_OK=0; echo "    !! exited $rc — see $log" >&2 ;;
  esac
  [ "$rc" = 0 ] || STEP_LAST_RC=$rc
  # Snapshot immediately: the next command in this group reuses the same path.
  if [ -f "$rjson" ]; then
    snap="$WORK/snap_${GRP_N}_${#GRP_SNAPS[@]}.json"
    cp -f "$rjson" "$snap"
    GRP_SNAPS+=("$snap")
  fi
  return 0  # a failing mode is DATA (it renders as not-passed), never a stop
}

# group_end PHASE MODE [EXTRA_JSON] — merge every snapshot's `phases` and write
# the row. The breakdown is lhd's own account of itself, not this script's
# guess; duplicate step names across the group's commands are summed.
#
# AND THEN PUBLISH IT IMMEDIATELY. The scoreboard is a STATUS page, not a
# report: a matrix takes tens of minutes and the whole point of having it
# rendered is to watch it fill in and catch a wrong number while the run that
# produced it is still on screen. So every row is stamped, appended to the
# ledger and re-rendered the moment it exists — never batched to the end, where
# a crash in phase 4 would throw away phases 1-3 as well.
group_end() {
  local phase=$1 mode=$2 extra=${3:-{\}} row="$WORK/row.json"
  python3 - "$phase" "$mode" "$GRP_MS" "$GRP_OK" "$extra" "$CORE" "$(loadavg)" "${GRP_SNAPS[@]:-}" >"$row" <<'PY'
import json, sys
phase, mode, wall, ok, extra, target, load = sys.argv[1:8]
phases = {}
for path in (p for p in sys.argv[8:] if p):
    try:
        with open(path) as f:
            for p in json.load(f).get("phases", []):
                phases[p["name"]] = round(phases.get(p["name"], 0.0) + float(p["ms"]), 3)
    except Exception:
        pass  # a command with no --result-json still contributes its wall time
row = {"target": target, "phase": phase, "mode": mode, "wall_ms": float(wall),
       "passed": ok == "1", "phases": phases}
if load:
    row["loadavg"] = float(load)
row.update(json.loads(extra))
print(json.dumps(row, sort_keys=True))
PY
  cat "$row" >>"$OUT"
  publish "$row"
}

# publish ROW_JSON — stamp the identity block onto one row, append it to the
# shared ledger, and re-render the scoreboard. Failures here are reported and
# then IGNORED: a broken renderer must never take the measurement run down with
# it, because the measurement is the expensive part and $MATRIX_OUT still has
# every row for a later replay.
publish() {
  [ "${MATRIX_LIVE:-1}" != 0 ] || return 0
  # BUILD_WORKSPACE_DIRECTORY is how ledger.py finds the checkout, because it is
  # normally run via `bazel run`. Outside bazel it defaults to the CWD — and this
  # script has cd'd into its scratch dir, so without this the ledger is silently
  # created at $WORK/bench/ledger.jsonl and the real one never grows.
  BUILD_WORKSPACE_DIRECTORY="$ROOT" python3 "$ROOT/bench/ledger.py" \
      add --config-id "$CONFIG_ID" "$1" >/dev/null 2>>"$WORK/publish.log" \
    || { echo "    !! ledger add failed — see $WORK/publish.log" >&2; return 0; }
  BUILD_WORKSPACE_DIRECTORY="$ROOT" python3 "$ROOT/bench/ledger.py" \
      render --flow incr --out "$HTML" >/dev/null 2>>"$WORK/publish.log" \
    || echo "    !! ledger render failed — see $WORK/publish.log" >&2
  return 0
}

# abc_extra RESULT_JSON — the ABC incremental counters, as an extra-JSON blob
# for the row. `miss_ms` is the number that says whether the cache HELPED; a
# high hit COUNT over cheap regions is not a speedup (docs/opt_loop_incr.md I4),
# and `store_failed` names a region that will re-synthesize forever.
abc_extra() {
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
out = {}
try:
    d = json.load(open(sys.argv[1]))
    # The envelope's `incremental.abc` member is the one place every reuse tier
    # is reported (enabled=false = an honest cold map); the qor object is the
    # fallback for an envelope written by an older lhd.
    tier = (d.get("incremental") or {}).get("abc")
    inc = tier if isinstance(tier, dict) and tier.get("enabled", False) else find(d.get("qor", d), "incremental")
    if isinstance(inc, dict) and "hits" in inc:
        out["abc_hits"]    = inc.get("hits")
        out["abc_misses"]  = inc.get("misses")
        out["abc_hit_ms"]  = round(inc.get("hit_ms", 0))
        out["abc_miss_ms"] = round(inc.get("miss_ms", 0))
    if isinstance(tier, dict):
        out["abc_regions"] = tier.get("regions")
        out["abc_store_failed"] = tier.get("store_failed")
    else:
        regions = find(d, "regions")
        if isinstance(regions, list):
            out["abc_regions"] = len(regions)
            out["abc_store_failed"] = sum(1 for r in regions if r.get("cache") == "store-failed")
except Exception:
    pass
print(json.dumps({k: v for k, v in out.items() if v is not None}))
PY
}

# compile_extra RESULT_JSON WORKDIR [WARM_EQUALS_COLD] — the Pyrope compile
# cache counters plus its persistent footprint. Missing telemetry stays absent
# (old lhd binary), while an explicit lhd.incremental=false row reports zeros.
compile_extra() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, os, sys
out = {}
try:
    with open(sys.argv[1]) as f:
        cache = json.load(f).get("incremental", {}).get("compile", {})
    for key in ("hits", "misses", "redone_ms", "store_failed", "refused"):
        if key in cache:
            out[key] = cache[key]
except Exception:
    pass
total = 0
for root, _, files in os.walk(sys.argv[2]):
    for name in files:
        try:
            total += os.path.getsize(os.path.join(root, name))
        except OSError:
            pass
out["workdir_bytes"] = total
if sys.argv[3]:
    out["compile_warm_equals_cold"] = sys.argv[3] == "1"
print(json.dumps(out, sort_keys=True))
PY
}

# best_exec BIN CYCLES — the SIMULATION alone, best of 3, by re-running the
# binary `lhd sim` just built. BEST, not mean: a dev box stalls, and the
# standard estimator for "how fast does this go" under one-sided noise is the
# minimum. These runs are a MEASUREMENT, not part of the rebuild, so they happen
# after the last timed step and never enter wall_ms.
best_exec() {
  local bin=$1 cycles=$2 best= t0 t1 ms i
  [ -x "$bin" ] || { echo ""; return 0; }
  for i in 1 2 3; do
    t0=$(now_ms)
    "$bin" --cycles "$cycles" >/dev/null 2>&1 || { echo ""; return 0; }
    t1=$(now_ms)
    ms=$((t1 - t0))
    { [ -n "$best" ] && [ "$best" -le "$ms" ]; } || best=$ms
  done
  echo "$best"
}

# dir_bytes DIR — cache size is a real cost (H6 workdir_bytes), so a lever that
# buys time with unbounded disk is visible rather than free.
dir_bytes() {
  [ -d "$1" ] || { echo 0; return 0; }
  echo $(($(du -sk "$1" 2>/dev/null | awk '{print $1}') * 1024))
}

# sim_extra WORKDIR SETUP_MS RUN_MS — the I3 guardrail block for a sim row.
# sim_exec_ms is the number that must NOT regress no matter what happens to the
# build time: a change that cuts the host compile by slowing the simulation is a
# net loss, and only a per-mode measurement can see it.
sim_extra() {
  local wd=$1 setup_ms=$2 run_ms=$3 exec_ms cc_ms
  exec_ms=$(best_exec "$wd/sim/drv.bin" "$SIM_PERF_CYCLES")
  if [ -z "$exec_ms" ]; then
    printf '{"sim_setup_ms":%s,"sim_run_ms":%s,"workdir_bytes":%s}' \
      "$setup_ms" "$run_ms" "$(dir_bytes "$wd")"
    return 0
  fi
  # sim_cc_ms is the HOST BUILD: the `--run-only` wall minus the simulation it
  # contained. That simulation ran $SIM_CYCLES, not $SIM_PERF_CYCLES, so scale.
  local gate_exec_ms=$((exec_ms * SIM_CYCLES / SIM_PERF_CYCLES))
  cc_ms=$((run_ms - gate_exec_ms))
  [ "$cc_ms" -ge 0 ] || cc_ms=0   # only reachable if a stall hit the lhd run
  printf '{"sim_setup_ms":%s,"sim_run_ms":%s,"sim_exec_ms":%s,"sim_cc_ms":%s,"sim_cycles":%s,"workdir_bytes":%s}' \
    "$setup_ms" "$run_ms" "$exec_ms" "$cc_ms" "$SIM_PERF_CYCLES" "$(dir_bytes "$wd")"
}

# warm_phase LABEL -- cmd...  — run a throwaway invocation into a scratch dir,
# then delete it. Absorbs the cold start of whatever EXTERNAL tool the phase
# reaches for the first time in this process's life.
#
# NOT optional, and not paranoia. `full` is always the first of the three modes,
# so without this it silently pays for everything the others find warm.
# Measured on dino BEFORE this existed: lec full 3006 ms vs cold 184 ms — a 16x
# "cache cost" that was really cvc5 + abc starting up, and sim full 5527 ms vs
# cold 4513 ms, which was clang++. Both would have been read as the incremental
# machinery making clean builds dramatically cheaper, which is backwards.
#
# The scratch dir is separate and discarded, so the warm-up cannot leave a cache
# behind for the mode it is protecting. `compile` and `synth` need no warm-up:
# the control probe and the prerequisite compile already ran `lhd` (measured:
# dino compile 95/96/96, synth full FASTER than cold).
warm_phase() {
  local label=$1
  shift
  echo "  [$CORE warmup] $label" >&2
  "$@" >"$WORK/warmup_${label}.log" 2>&1 || true
  return 0
}

# A prerequisite that must NOT be counted in the row being measured (the
# compile that feeds a synth or lec mode is the `compile` phase's business).
untimed() {
  local what=$1; shift
  echo "  [$CORE prereq] $what" >&2
  "$@" >"$WORK/prereq_${what}.log" 2>&1 \
    || echo "    !! prereq '$what' exited $? — see $WORK/prereq_${what}.log" >&2
  return 0
}

# A fixed, cheap, untouched command, timed at both ends of the matrix. Its
# drift is the honest error bar on everything between (trap T12).
#
# WARMED FIRST, deliberately. The very first invocation pays process start, page
# faults and a cold filesystem — measured 2369 ms against 35 ms for the same
# command a moment later. Reporting that as the opening control would have made
# every matrix look like the machine got 68x FASTER during the run.
control() {
  local t0 t1
  t0=$(now_ms)
  "$LHD" compile "$WORK/ctl/ctl.prp" --top ctl --workdir "$WORK/ctl/w" >/dev/null 2>&1
  t1=$(now_ms)
  echo $((t1 - t0))
}

comment_touch() { printf '\n// lhdsuite matrix comment-only touch\n' >>"$1"; }

# ---- fresh scratch ----------------------------------------------------------
# One matrix per core at a time. $WORK is a FIXED path per core, and the driver
# rm -rf's it at startup, so a second run of the same core silently deletes the
# first's tree/ and workdirs out from under it and both then publish garbage
# into the shared ledger. Observed exactly that: an overlapping xs_rob run left
# a single `incremental` row from a process whose inputs had been deleted.
#
# An OS advisory lock, so a killed owner releases it automatically and there is
# no stale lockfile to clean up by hand.
mkdir -p "$WORK"
exec 9>"$WORK/.matrix.lock"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { echo "FAIL: another matrix.sh is already running for '$CORE' ($WORK)" >&2; exit 3; }
else
  # macOS has no flock(1); shlock-style pid file with a liveness check.
  if [ -s "$WORK/.matrix.pid" ] && kill -0 "$(cat "$WORK/.matrix.pid")" 2>/dev/null; then
    echo "FAIL: another matrix.sh is already running for '$CORE' (pid $(cat "$WORK/.matrix.pid"), $WORK)" >&2
    exit 3
  fi
fi
rm -rf "$WORK"; mkdir -p "$WORK/ctl"
echo $$ >"$WORK/.matrix.pid"
trap 'rm -f "$WORK/.matrix.pid"' EXIT
cd "$WORK"
: >"$OUT"

cat >"$WORK/ctl/ctl.prp" <<'EOF'
pub comb ctl(a:u16, b:u16) -> (s:u16, d:u16) {
  s = (a + b)#[0..=15]
  d = (a ^ b)#[0..=15]
}
EOF

prep_tree() {  # a writable copy of the Pyrope sources, plus drivers and stubs
  rm -rf tree; mkdir -p tree
  cp -L "$P_DIR"/*.prp tree/
  [ -f "$P_DIR/manifest.json" ] && cp -L "$P_DIR/manifest.json" tree/
  [ -d "$SIM_DIR" ] && cp -L "$SIM_DIR"/*.prp tree/ 2>/dev/null
  if [ -n "$STUB_DIR" ] && [ -d "$STUB_DIR" ]; then
    cp -L "$STUB_DIR"/*.prp tree/
  fi
  return 0
}

control >/dev/null   # warm: discard the cold-start sample (see control() above)
CTL_START=$(control)
echo "== $CORE: control=${CTL_START}ms  phases='$PHASES'  work=$WORK" >&2

# BENCH_PYROPE_SETS="k=v k=v": `--set` flags for every Pyrope front-end run in
# this matrix (compile, synth, sim, the lec impl side) — e.g.
# `compile.unroll=true` to run a loop benchmark with its source loops unrolled
# (the default keeps an eligible loop as one replicated Sub). Fully-qualified
# keys only: `lhd sim` rejects the bare `unroll`.
PYROPE_ARGS=()
for kv in ${BENCH_PYROPE_SETS:-}; do PYROPE_ARGS+=(--set "$kv"); done

compile_into() {  # OUT_LG WORKDIR RESULT_JSON [EXTRA_ARGS...]
  local out=$1 workdir=$2 result=$3
  shift 3
  "$LHD" compile "tree/$TOP.prp" --top "$TOP" --emit-dir "lg:$out" --workdir "$workdir" --result-json "$result" \
    ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} "$@"
}

# ---------------------------------------------------------------- compile ----
if [[ " $PHASES " == *" compile "* ]]; then
  prep_tree
  rm -rf c_full cw_full
  group_begin
  step compile full c_full.json -- compile_into c_full cw_full c_full.json --set lhd.incremental=false
  group_end compile full "$(compile_extra c_full.json cw_full)"

  rm -rf c_cold cw_warm
  group_begin
  step compile cold c_cold.json -- compile_into c_cold cw_warm c_cold.json
  cp -R c_cold c_cold_ref
  group_end compile cold "$(compile_extra c_cold.json cw_warm)"

  comment_touch "tree/$TOP.prp"
  group_begin
  step compile incremental c_incr.json -- compile_into c_cold cw_warm c_incr.json
  compile_equal=0
  [ "$("$LHD" tool diff lg:c_cold_ref lg:c_cold --structural -q 2>/dev/null)" = identical ] && compile_equal=1
  group_end compile incremental "$(compile_extra c_incr.json cw_warm "$compile_equal")"
fi

# ------------------------------------------------------------------ synth ----
# The synth row is the ONE-SHOT `lhd synth`: compile -> color synth -> abc ->
# opentimer over one in-memory design and one --workdir. The compile is inside
# the row now (it used to be an untimed prerequisite), and that is the point:
# the row is what an edit costs end to end, and lhd's own `phases` account
# keeps every step attributable — the compile tier's reuse shows up as the
# front-end phases collapsing on the incremental row, the abc tier's as the
# `abc_*` counters, so neither cache hides behind the other.
if [[ " $PHASES " == *" synth "* ]]; then
  if [ -z "${HAGENT_TECH_DIR:-}" ]; then
    echo "  [$CORE synth] SKIPPED: no sky130 from ciel and no HAGENT_TECH_DIR" >&2
  else
    prep_tree
    synth_group() {  # MODE WORKDIR [EXTRA_SETS...]
      local mode=$1 wd=$2
      shift 2
      group_begin
      step synth "$mode" "sy_${mode}.json" -- "$LHD" synth "tree/$TOP.prp" \
        --top "$TOP" --workdir "$wd" --emit-dir "lg:net_$mode" \
        --result-json "sy_${mode}.json" ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} "$@"
      group_end synth "$mode" "$(abc_extra "sy_${mode}.json")"
    }
    rm -rf sw_full net_full
    synth_group full sw_full --set lhd.incremental=false

    rm -rf sw_warm net_cold
    synth_group cold sw_warm

    comment_touch "tree/$TOP.prp"
    rm -rf net_incremental
    synth_group incremental sw_warm
  fi
fi

# -------------------------------------------------------------------- sim ----
# Two commands per mode: `--setup-only` is codegen, `--run-only` is the host C++
# build plus the simulation. One row, because the rebuild an edit costs is their
# sum; the per-pass breakdown separates them again (inou.cgen.sim vs
# sim.hostbuild vs sim.run).
if [[ " $PHASES " == *" sim "* ]]; then
  if [ ! -f "$SIM_DIR/$SIM_TB" ]; then
    echo "  [$CORE sim] SKIPPED: no driver at $SIM_DIR/$SIM_TB" >&2
  else
    prep_tree
    sim_group() {  # MODE WORKDIR
      local mode=$1 wd=$2
      local setup_ms run_ms
      group_begin
      step sim "$mode" "sim_${mode}_setup.json" -- "$LHD" sim ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} \
        "tree/$SIM_UNIT.prp" "tree/$SIM_TB" --setup-only \
        --workdir "$wd" --result-json "sim_${mode}_setup.json"
      setup_ms=$GRP_MS
      step sim "$mode" "sim_${mode}_run.json" -- "$LHD" sim ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} \
        "tree/$SIM_UNIT.prp" "tree/$SIM_TB" --run-only --arg "cycles=$SIM_CYCLES" \
 --diag-fmt pretty --workdir "$wd" \
        --result-json "sim_${mode}_run.json"
      run_ms=$((GRP_MS - setup_ms))
      group_end sim "$mode" "$(sim_extra "$wd" "$setup_ms" "$run_ms")"
    }
    rm -rf SW_warm0
    warm_phase sim "$LHD" sim ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} "tree/$SIM_UNIT.prp" "tree/$SIM_TB" \
      --arg "cycles=$SIM_CYCLES" --workdir SW_warm0
    rm -rf SW_warm0
    rm -rf SW_full; sim_group full SW_full
    rm -rf SW_warm; sim_group cold SW_warm
    comment_touch "tree/$SIM_UNIT.prp"
    sim_group incremental SW_warm
  fi
fi

# --------------------------------------------------------------- sim_llvm ----
# The SECOND simulator backend, as its own (target, phase) row rather than a
# variant of `sim`. It is not a knob on the same flow: `sim.backend=llvm`
# replaces the per-color Slop C++ with a native object plus an ABI adapter, so
# its codegen cost, its host build and its cycles/s are all different numbers
# and belong in different cells. Reuse has to hold for BOTH backends or the
# incremental work is only half done.
if [[ " $PHASES " == *" sim_llvm "* ]]; then
  if [ ! -f "$SIM_DIR/$SIM_TB" ]; then
    echo "  [$CORE sim_llvm] SKIPPED: no driver at $SIM_DIR/$SIM_TB" >&2
  else
    prep_tree
    simllvm_group() {  # MODE WORKDIR
      local mode=$1 wd=$2
      local setup_ms run_ms
      group_begin
      step sim_llvm "$mode" "siml_${mode}_setup.json" -- "$LHD" sim ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} \
        "tree/$SIM_UNIT.prp" "tree/$SIM_TB" --setup-only \
        --set sim.backend=llvm --workdir "$wd" --result-json "siml_${mode}_setup.json"
      setup_ms=$GRP_MS
      step sim_llvm "$mode" "siml_${mode}_run.json" -- "$LHD" sim ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} \
        "tree/$SIM_UNIT.prp" "tree/$SIM_TB" --run-only --arg "cycles=$SIM_CYCLES" \
 --set sim.backend=llvm --diag-fmt pretty \
        --workdir "$wd" --result-json "siml_${mode}_run.json"
      run_ms=$((GRP_MS - setup_ms))
      group_end sim_llvm "$mode" "$(sim_extra "$wd" "$setup_ms" "$run_ms")"
    }
    rm -rf SL_warm0
    warm_phase sim_llvm "$LHD" sim ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} "tree/$SIM_UNIT.prp" "tree/$SIM_TB" \
      --arg "cycles=$SIM_CYCLES" --set sim.backend=llvm \
      --workdir SL_warm0
    rm -rf SL_warm0
    rm -rf SL_full; simllvm_group full SL_full
    rm -rf SL_warm; simllvm_group cold SL_warm
    comment_touch "tree/$SIM_UNIT.prp"
    simllvm_group incremental SL_warm
  fi
fi

# -------------------------------------------------------------------- lec ----
if [[ " $PHASES " == *" lec "* ]] && [ "$HAS_LEC" = 1 ]; then
  prep_tree
  # The Verilog reference is the same library for all three modes, so it is a
  # prerequisite too — LEC's own cost is the proof, not the front end.
  # shellcheck disable=SC2086
  untimed lec_ref "$LHD" compile verilog --top "$TOP" --emit-dir lg:ref.lg \
    --workdir cw_ref -- -F "$V_DIR/filelist.f" -DSYNTHESIS $V_FLAGS
  lec_group() {  # MODE IMPL_LG WORKDIR [EXTRA...]
    local mode=$1 lg=$2 wd=$3
    shift 3
    group_begin
    # 10 = REFUTED: the prover finished and the two sides differ. That is a
    # verdict, so the timing is valid; the gate sees it via `refuted`.
    STEP_OK_CODES="0 10" \
      step lec "$mode" "lec_$mode.json" -- "$LHD" lec --impl "lg:$lg" --ref lg:ref.lg \
        --top "$TOP" --workdir "$wd" --result-json "lec_$mode.json" "$@"
    group_end lec "$mode" "{\"refuted\": $([ "${STEP_LAST_RC:-0}" = 10 ] && echo true || echo false)}"
  }
  rm -rf l_full lw_full lw_warm0
  untimed lec_pre_full compile_into l_full cw_l_full pre_l_full.json
  warm_phase lec "$LHD" lec --impl "lg:l_full" --ref lg:ref.lg --top "$TOP" \
    --workdir lw_warm0 --set lhd.incremental=false
  rm -rf lw_warm0
  lec_group full l_full lw_full --set lhd.incremental=false

  rm -rf l_cold lw_warm
  untimed lec_pre_cold compile_into l_cold cw_l_cold pre_l_cold.json
  lec_group cold l_cold lw_warm

  comment_touch "tree/$TOP.prp"
  rm -rf l_incr
  untimed lec_pre_incr compile_into l_incr cw_l_incr pre_l_incr.json
  lec_group incremental l_incr lw_warm
fi

CTL_END=$(control)
python3 - "$CORE" "$CTL_START" "$CTL_END" >"$WORK/row.json" <<'PY'
import json, sys
core, a, b = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
# The error bar on this whole sitting. A `drift` far from 1.0 means the box
# changed speed underneath the matrix and NO absolute number in it is
# comparable to another sitting's (trap T12).
print(json.dumps({"target": core, "phase": "control", "mode": "control",
                  "wall_ms": b, "passed": True, "phases": {},
                  "control_start_ms": a, "control_end_ms": b,
                  "drift": round(b / a, 3) if a else None}, sort_keys=True))
PY
cat "$WORK/row.json" >>"$OUT"
publish "$WORK/row.json"

echo "== $CORE done. control drift: ${CTL_START}ms -> ${CTL_END}ms" >&2
echo "== scoreboard: $HTML" >&2
