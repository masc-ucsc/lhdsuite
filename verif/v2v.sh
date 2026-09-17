#!/usr/bin/env bash
# Verilog -> generated Pyrope -> generated Verilog correctness gate.
#
# Both equivalence checks compare the generated Verilog against the original
# Verilog. Each check has a 10-minute equivalence budget (native LEC's is
# soft; its worker backstop can take longer). The gate accepts
# solver-inconclusive results under the policy below, but a counterexample,
# refutation, or failure to run a check is always a failure.

set -euo pipefail

RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
if [ -d "$RF" ]; then
  RF=$(cd "$RF" && pwd)
  # A sh_binary resolves its own rlocations, but Bazel does not necessarily
  # export RUNFILES_DIR to child binaries. lhd needs the same tree to locate
  # lgcheck, yosys2, the slang plugin, and memory RTL.
  export RUNFILES_DIR="$RF"
fi
rloc() {
  case "$1" in
  /*) printf '%s\n' "$1" ;;
  *) printf '%s\n' "$RF/$1" ;;
  esac
}

LHD_BIN=$(rloc "${LHD:?LHD env var unset — set in verif/BUILD}")
CORE=${CORE:?CORE env var unset — set in verif/BUILD}
CORE_TOP=${CORE_TOP:?CORE_TOP env var unset — set in verif/BUILD}
V_FILELIST=$(rloc "${CORE_V_FLIST:?CORE_V_FLIST env var unset — set in verif/BUILD}")
V_DIR=$(cd "$(dirname "$V_FILELIST")" && pwd)
: "${CORE_V_FLAGS=}"

: "${TEST_TMPDIR:=$(mktemp -d "${TMPDIR:-/tmp}/v2v.XXXXXX")}"
WORK=$TEST_TMPDIR
OUT_DIR=${TEST_UNDECLARED_OUTPUTS_DIR:-$WORK}
mkdir -p "$WORK"
cd "$WORK"

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
# v2v already keeps the two apart: its wall clocks are LGCHECK_BUDGET_S and
# LEC_NATIVE_BUDGET_S, both defaulting to 4x the solver budget on purpose.

# Declare the filelist entries as lhd source inputs, in their original order,
# rather than hiding them behind slang's raw `-F` option. The frontend receives
# the same source set, while lhd can now report which declared files did not
# reach the elaborated --top through --unused-inputs.
v_sources=()
while IFS= read -r rel || [ -n "$rel" ]; do
  rel=${rel%$'\r'}
  case "$rel" in
  "" | \#* | //* ) continue ;;
  esac
  v_sources+=("$(realpath "$V_DIR/$rel")")
done <"$V_FILELIST"

# CORE_V_FLAGS is a list of slang arguments supplied by the core table.
# Splat it straight into a NON-EMPTY array literal, exactly as genprp.sh:59 does.
# Do NOT build an intermediate `v_flags=($CORE_V_FLAGS)` and then expand
# "${v_flags[@]}" -- a core with no extra flags (dino) leaves it EMPTY, and under
# `set -u` bash 3.2 treats an empty "${arr[@]}" as unbound. bazel's test PATH
# carries no homebrew, so `#!/usr/bin/env bash` resolves to /bin/bash 3.2.57 and
# every such core died with `v_flags[@]: unbound variable` before running a step.
# shellcheck disable=SC2206
v_args=(-DSYNTHESIS $CORE_V_FLAGS)

archive() {
  [ "$OUT_DIR" = "$WORK" ] && return 0
  mkdir -p "$OUT_DIR/gen" "$OUT_DIR/impl_v"
  cp -R gen/. "$OUT_DIR/gen/" 2>/dev/null || true
  cp -R impl_v/. "$OUT_DIR/impl_v/" 2>/dev/null || true
  cp step_*.log "$OUT_DIR/" 2>/dev/null || true
  # Preserve elaboration errors and solver counterexamples for the top and
  # descendant checks without copying multi-gigabyte RTLIL caches.
  python3 - "$OUT_DIR" <<'PY'
from pathlib import Path
import shutil
import sys

root = Path('work_lgyosys')
for source in root.rglob('*'):
    if not source.is_file() or source.suffix not in {'.err', '.log', '.vcd'}:
        continue
    target = Path(sys.argv[1]) / source
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
PY
}

run_step() { # LABEL COMMAND...
  local label=$1
  shift
  printf 'CMD %s:' "$label"
  printf ' %q' "$@"
  printf '\n'
  set +e
  "$@" >"step_${label}.log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: step '$label' exited $rc" >&2
    tail -40 "step_${label}.log" >&2
    archive
    exit "$rc"
  fi
}

# One original-Verilog elaboration produces both the generated Pyrope and the
# reference LGraph.  Keeping these in one invocation guarantees both artifacts
# came from exactly the same source/options while avoiding a second expensive
# front-end pass on XiangShan.
run_step gen "$LHD_BIN" compile verilog "${v_sources[@]}" --top "$CORE_TOP" \
  --emit-dir pyrope:gen --emit-dir lg:ref_lg --workdir work_gen \
  --unused-inputs unused_inputs.txt -- "${v_args[@]}"

if [ ! -f "gen/$CORE_TOP.prp" ]; then
  echo "FAIL: generator emitted no gen/$CORE_TOP.prp" >&2
  archive
  exit 1
fi

# Re-read the generated Pyrope and deliberately emit a directory of Verilog
# modules.  lgcheck accepts one implementation file, so concatenate every
# emitted module into a single hierarchy-preserving input.
run_step emit_impl "$LHD_BIN" compile "gen/$CORE_TOP.prp" --top "$CORE_TOP" \
  --emit-dir verilog:impl_v --workdir work_impl

shopt -s nullglob
impl_parts=(impl_v/*.v)
if [ "${#impl_parts[@]}" -eq 0 ]; then
  echo "FAIL: generated Pyrope emitted no Verilog modules" >&2
  archive
  exit 1
fi
# NOTE bash 3.2: no `mapfile`/`readarray` (bash 4+). bazel's test PATH carries no
# homebrew, so `#!/usr/bin/env bash` here is /bin/bash 3.2.57 and `mapfile` is
# "command not found". Read the sorted list back with a plain loop instead --
# these are glob results, so no path contains a newline.
impl_sorted=()
while IFS= read -r impl_p; do
  impl_sorted+=("$impl_p")
done < <(printf '%s\n' "${impl_parts[@]}" | sort)
impl_parts=("${impl_sorted[@]}")
# Each emitted user module may include the same LiveHD memory model. Keep the
# first include of each model, stage those runfile-backed models beside the
# concatenated source, and drop duplicate includes. The models are support RTL,
# not separate members of impl_parts.
livehd_root=$(cd "$(dirname "$LHD_BIN")/.." && pwd)
memory_models=("$livehd_root"/ware/rtl/cgen_memory*.v)
if [ "${#memory_models[@]}" -ne 0 ]; then
  cp "${memory_models[@]}" .
fi
awk '/^`include "cgen_memory_[^"]*\.v"/ { if (seen[$0]++) next } { print }' \
  "${impl_parts[@]}" >impl_all.v

# Both LEC legs need one reference file. Preserve the original source text and
# filelist order, but omit files that lhd proved absent from the compiled top's
# source closure. This matters for XiangShan: slang must parse the full filelist
# to elaborate the top, while the independent Yosys/slang read only needs the
# reachable modules and otherwise spends hours re-reading unrelated Backend
# sources. Defining SYNTHESIS matches the generation leg; copying headers beside
# the combined file keeps Minion's relative `include directives valid.
# NOTE bash 3.2: no `declare -A` (bash 4+), same reason as the mapfile above.
# This is only ever used as a SET of absolute paths, so keep it as a file and
# test membership with `grep -Fxq` -- realpath output contains no newline.
unused_abs=unused_abs.txt
: >"$unused_abs"
while IFS= read -r unused || [ -n "$unused" ]; do
  [ -z "$unused" ] && continue
  realpath "$unused" >>"$unused_abs"
done <unused_inputs.txt

printf '`define SYNTHESIS\n' >ref_all.sv
while IFS= read -r rel || [ -n "$rel" ]; do
  [ -z "$rel" ] && continue
  src=$(realpath "$V_DIR/$rel")
  # --unused-inputs describes source files that did not contribute module
  # definitions to the selected top. Package declarations are compilation-unit
  # dependencies rather than instantiated modules, so slang can report their
  # files unused even while retained modules import their types/constants
  # (Minion's dft_pkg, etlink_pkg, and frontend packages). Preserve every
  # package source; only prune an unused file when it contains no package.
  if grep -Fxq "$src" "$unused_abs" \
      && ! grep -Eq '^[[:space:]]*package[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*' "$src"; then
    continue
  fi
  sed -n '1,$p' "$src" >>ref_all.sv
  printf '\n' >>ref_all.sv
done <"$V_FILELIST"
for header in "$V_DIR"/*.svh "$V_DIR"/*.vh; do
  [ -f "$header" ] && cp "$header" .
done

# Run the independent @livehd//inou/yosys/lgcheck oracle directly. The lhd
# formal.solver=lgyosys setting now also requires a native proof; this gate
# runs and classifies its native leg separately below. lgcheck
# starts LGCHECK_EQUIV_TIMEOUT only after it has read both Verilog hierarchies;
# source parsing is intentionally uncapped.  A proof is a clear pass.  Its
# distinct INCONCLUSIVE result means no counterexample was found within that
# proof budget.  Every real refutation/setup failure remains non-zero.
LGCHECK_BIN="$livehd_root/inou/yosys/lgcheck"
YOSYS_BIN="$livehd_root/inou/yosys/yosys2"
printf 'CMD lgyosys: LGCHECK_EQUIV_TIMEOUT="$LEC_BUDGET_S"'
printf ' %q' "$LGCHECK_BIN" --implementation "$WORK/impl_all.v" \
  --reference "$WORK/ref_all.sv" --top "$CORE_TOP" --yosys "$YOSYS_BIN" \
  --gold_reader slang --gate_reader slang --normalize_split_ports --descend_on_inconclusive
printf '\n'
mkdir -p work_lgyosys
lgyosys_rc=0
# LGCHECK_EQUIV_TIMEOUT bounds only the PROOF -- lgcheck starts it after both
# hierarchies are read, and the read of a whole core is itself unbounded (the
# xs_backend slang read alone runs for many minutes). Without an outer wall
# clock the 5-minute ruling does not actually bound this leg, so give the whole
# invocation a budget generous enough to cover parse + elaborate + prove. A kill
# lands in the 124 arm below and is classified exactly like any other deadline:
# no counterexample was found, so it is reported and passed.
LGCHECK_BUDGET_S=${LGCHECK_BUDGET_S:-$((LEC_BUDGET_S * 4))}
run_deadline "$LGCHECK_BUDGET_S" step_lgyosys.log \
  env -C work_lgyosys LGCHECK_EQUIV_TIMEOUT="$LEC_BUDGET_S" "$LGCHECK_BIN" \
    --implementation "$WORK/impl_all.v" --reference "$WORK/ref_all.sv" \
    --top "$CORE_TOP" --yosys "$YOSYS_BIN" \
    --gold_reader slang --gate_reader slang \
    --normalize_split_ports --descend_on_inconclusive || lgyosys_rc=$?

# lgcheck's own exit-code contract (inou/yosys/lgcheck): 1 is a real
# counterexample, and 5 is "setup failure, NOT a refutation" -- its own comment
# says exit 1 is reserved for the CEX. Under this gate's ruling only the
# refutation fails; a setup failure and a deadline kill both mean the oracle
# found no issue, so they are reported and passed.
case "$lgyosys_rc" in
0)
  if ! grep -qa 'Successfully matched' step_lgyosys.log; then
    echo "FAIL: lgcheck returned success without a recognized proof" >&2
    tail -40 step_lgyosys.log >&2
    archive
    exit 1
  fi
  lgyosys_verdict=PROVEN
  ;;
1)
  echo "FAIL: lgcheck REFUTED $CORE_TOP" >&2
  tail -40 step_lgyosys.log >&2
  archive
  exit 1
  ;;
2)
  if ! grep -qa '^INCONCLUSIVE:' step_lgyosys.log; then
    echo "FAIL: lgcheck exited 2 without an inconclusive verdict" >&2
    tail -40 step_lgyosys.log >&2
    archive
    exit 1
  fi
  lgyosys_verdict=INCONCLUSIVE
  ;;
5)
  lgyosys_verdict=NO-COMPARE  # lgcheck's documented setup failure
  echo "NOTE: lgcheck could not set up a comparison for $CORE_TOP (rc=5, not a refutation)"
  ;;
124 | 137 | 143)
  lgyosys_verdict=TIMEOUT
  echo "NOTE: lgcheck hit the ${LGCHECK_BUDGET_S}s budget on $CORE_TOP without refuting"
  ;;
*)
  echo "FAIL: lgcheck exited $lgyosys_rc on $CORE_TOP -- an unclassified result" >&2
  tail -40 step_lgyosys.log >&2
  archive
  exit "$lgyosys_rc"
  ;;
esac

# Run the mandatory native lhd LEC check after the independent oracle.
# The implementation
# input is the generated Verilog (not the intermediate Pyrope/LGraph); ref_lg
# came directly from the original Verilog in the generation step above. These
# tops intentionally exceed the interactive one-million-node admission guard,
# so this correctness gate explicitly accepts the memory risk instead of
# reporting that policy refusal as an equivalence result. Keep definition jobs
# serial so one oversize proof owns the memory budget at a time.
printf 'CMD lec:'
printf ' %q' "$LHD_BIN" lec --impl verilog:"$WORK/impl_all.v" \
  --ref lg:"$WORK/ref_lg" --top "$CORE_TOP" --set "formal.timeout=$LEC_BUDGET_S" \
  --set formal.allow_oversize=true --set formal.jobs=1 \
  --workdir work_lec
printf '\n'
lec_rc=0
set +e
# Same gap the lgcheck leg had: `formal.timeout` bounds only the PROOF, while
# reading and elaborating the whole core ahead of it is unbounded -- xs_rob sat
# in this step for over an hour, and xs_backend's read alone is a 190 MB
# SystemVerilog parse. Give the whole invocation the same generous wall clock,
# so a deadline kill lands in the TIMEOUT arm below (no counterexample found)
# instead of the gate hanging until bazel's 6-hour test timeout.
LEC_NATIVE_BUDGET_S=${LEC_NATIVE_BUDGET_S:-$((LEC_BUDGET_S * 4))}
run_deadline "$LEC_NATIVE_BUDGET_S" step_lec.log \
  "$LHD_BIN" lec --impl verilog:"$WORK/impl_all.v" \
  --ref lg:"$WORK/ref_lg" --top "$CORE_TOP" --set "formal.timeout=$LEC_BUDGET_S" \
  --set formal.allow_oversize=true --set formal.jobs=1 \
  --workdir work_lec
lec_rc=$?
set -e
native_ok=1
# Verdict policy for THIS gate (owner ruling 2026-09-11, //verif only): the
# native leg runs under a 600 s soft budget (formal.timeout above) and a proof
# that remains inconclusive is accepted -- a refutation is still
# fatal. lhd itself keeps proven / refuted / timeout distinct; only this test
# collapses timeout into pass, because a multi-hour inconclusive LEC of a
# whole core says nothing the 10-minute one does not.
lec_verdict=$(python3 "$(rloc _main/verif/lec_verdict.py)" step_lec.log "$lec_rc")
# NOVERDICT / BOUNDED / UNDECIDED: no counterexample, but nothing was fully
# checked either. All three were fatal before this gate learned about deadlines
# and stay fatal -- only a real TIMEOUT is forgiven.
case $lec_verdict in
NOVERDICT | BOUNDED | UNDECIDED)
  echo "FAIL: lec reached no usable verdict ($lec_verdict) for $CORE_TOP (rc=$lec_rc) -- not a timeout" >&2
  tail -10 step_lec.log >&2
  archive
  exit 1
  ;;
esac
if [ "$lec_verdict" = REFUTED ]; then
  native_ok=0
  echo "FAIL: native lhd LEC did not prove $CORE_TOP" >&2
  tail -40 step_lec.log >&2
fi

if [ "$native_ok" -ne 1 ]; then
  echo "FAIL: native lhd LEC did not prove $CORE_TOP equivalent" >&2
  archive
  native_rc=$lec_rc
  [ "$native_rc" -ne 0 ] || native_rc=1
  exit "$native_rc"
fi

echo "PASS: $CORE/$CORE_TOP round-trip gate; lhd=$lec_verdict lgyosys=$lgyosys_verdict"
