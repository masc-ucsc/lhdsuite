#!/usr/bin/env bash
# Verilog -> generated Pyrope -> generated Verilog correctness gate.
#
# Both equivalence checks compare the generated Verilog against the original
# Verilog.  Native lhd LEC must prove.  The independent Yosys/lgcheck backend
# may prove or remain inconclusive after its 10-minute equivalence budget, but a
# counterexample/refutation is always a failure.

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
# shellcheck disable=SC2206
v_flags=($CORE_V_FLAGS)
v_args=(-DSYNTHESIS "${v_flags[@]}")

archive() {
  [ "$OUT_DIR" = "$WORK" ] && return 0
  mkdir -p "$OUT_DIR/gen" "$OUT_DIR/impl_v"
  cp -R gen/. "$OUT_DIR/gen/" 2>/dev/null || true
  cp -R impl_v/. "$OUT_DIR/impl_v/" 2>/dev/null || true
  cp step_*.log "$OUT_DIR/" 2>/dev/null || true
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
run_step gen "$LHD_BIN" compile verilog "${v_sources[@]}" --top "$CORE_TOP" --recipe O1 \
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
  --recipe O0 --emit-dir verilog:impl_v --workdir work_impl

shopt -s nullglob
impl_parts=(impl_v/*.v)
if [ "${#impl_parts[@]}" -eq 0 ]; then
  echo "FAIL: generated Pyrope emitted no Verilog modules" >&2
  archive
  exit 1
fi
mapfile -t impl_parts < <(printf '%s\n' "${impl_parts[@]}" | sort)
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
declare -A unused_sources=()
while IFS= read -r unused || [ -n "$unused" ]; do
  [ -z "$unused" ] && continue
  unused_sources["$(realpath "$unused")"]=1
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
  if [ -n "${unused_sources[$src]+x}" ] \
      && ! grep -Eq '^[[:space:]]*package[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*' "$src"; then
    continue
  fi
  sed -n '1,$p' "$src" >>ref_all.sv
  printf '\n' >>ref_all.sv
done <"$V_FILELIST"
for header in "$V_DIR"/*.svh "$V_DIR"/*.vh; do
  [ -f "$header" ] && cp "$header" .
done

# lgyosys is the independent @livehd//inou/yosys/lgcheck oracle.  lgcheck
# starts LGCHECK_EQUIV_TIMEOUT only after it has read both Verilog hierarchies;
# source parsing is intentionally uncapped.  A proof is a clear pass.  Its
# distinct INCONCLUSIVE result means no counterexample was found within that
# proof budget.  Every real refutation/setup failure remains non-zero.
printf 'CMD lgyosys: LGCHECK_EQUIV_TIMEOUT=600 lhd lec ... --set formal.solver=lgyosys\n'
lgyosys_rc=0
set +e
LGCHECK_EQUIV_TIMEOUT=600 "$LHD_BIN" lec \
  --impl verilog:"$WORK/impl_all.v" --ref verilog:"$WORK/ref_all.sv" \
  --top "$CORE_TOP" --set formal.solver=lgyosys \
  --set formal.lec.gold_reader=slang --set formal.lec.gate_reader=slang \
  --set formal.lec.normalize_split_ports=true \
  --set formal.lec.descend_on_inconclusive=true \
  --workdir work_lgyosys \
  >step_lgyosys.log 2>&1
lgyosys_rc=$?
set -e

case "$lgyosys_rc" in
0)
  if grep -qia 'REFUTED\|not equivalent' step_lgyosys.log; then
    echo "FAIL: lgyosys reported a refutation despite exiting zero" >&2
    tail -40 step_lgyosys.log >&2
    archive
    exit 1
  fi
  if grep -qa 'PROVEN equivalent' step_lgyosys.log; then
    lgyosys_verdict=PROVEN
  elif grep -qa 'INCONCLUSIVE' step_lgyosys.log; then
    lgyosys_verdict=INCONCLUSIVE
  else
    echo "FAIL: lgyosys returned success without a recognized verdict" >&2
    tail -40 step_lgyosys.log >&2
    archive
    exit 1
  fi
  ;;
*)
  echo "FAIL: lgyosys refuted or could not compare $CORE_TOP (rc=$lgyosys_rc)" >&2
  tail -40 step_lgyosys.log >&2
  archive
  exit "$lgyosys_rc"
  ;;
esac

# Native lhd LEC is the mandatory proof.  Run it AFTER the bounded independent
# oracle: a very large native proof is intentionally unbounded and must not
# prevent the requested lgyosys check from ever starting. The implementation
# input is the generated Verilog (not the intermediate Pyrope/LGraph); ref_lg
# came directly from the original Verilog in the generation step above. These
# tops intentionally exceed the interactive one-million-node admission guard,
# so this correctness gate explicitly accepts the memory risk instead of
# reporting that policy refusal as an equivalence result. Keep definition jobs
# serial so one oversize proof owns the memory budget at a time.
printf 'CMD lec:'
printf ' %q' "$LHD_BIN" lec --impl verilog:"$WORK/impl_all.v" \
  --ref lg:"$WORK/ref_lg" --top "$CORE_TOP" --set formal.timeout=0 \
  --set formal.allow_oversize=true --set formal.jobs=1 \
  --workdir work_lec
printf '\n'
lec_rc=0
set +e
"$LHD_BIN" lec --impl verilog:"$WORK/impl_all.v" \
  --ref lg:"$WORK/ref_lg" --top "$CORE_TOP" --set formal.timeout=0 \
  --set formal.allow_oversize=true --set formal.jobs=1 \
  --workdir work_lec >step_lec.log 2>&1
lec_rc=$?
set -e
native_ok=1
if [ "$lec_rc" -ne 0 ] || grep -qia 'refut' step_lec.log || ! grep -qa 'PROVEN equivalent' step_lec.log; then
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

echo "PASS: $CORE/$CORE_TOP original Verilog == generated Verilog; lhd=PROVEN lgyosys=$lgyosys_verdict"
