#!/usr/bin/env bash
# `lhd sim` benchmark over real modules of the design under test.
#
# Asserted and timed: the per-core benchmark testbench ($CORE_SIM_TB). It must
# print $CORE_SIM_MARKER AND, when the core sets $CORE_SIM_EXPECT, known-good data
# readback. The testbenches now ALSO assert that value in-source; the
# printed-value gate is kept as belt-and-braces, since it also catches a driver
# that runs but never reaches its assert. Anything else fails the target.
#
# Native setup compiles the DUT and testbench objects. sim_run_ms measures the
# public run-only command. sim_exec_ms measures lhd_simrt directly. The timed
# legs disable VCD and checkpoint I/O. Whole-top tests separately exercise VCD.
#
# Additional whole-top correctness drivers: $CORE_SIM_TOP_TB and, where the
# core has one, a program-driving testbench ($CORE_SIM_PROG_TB). They run
# separately from the timed benchmark above, at $CORE_SIM_TOP_CYCLES /
# $CORE_SIM_PROG_CYCLES. Both are always reported as METRIC sim_cpu_top_ok /
# sim_cpu_prog_ok; with $CORE_SIM_TOP_ASSERT set they ALSO gate the target, so
# a regression fails it instead of silently flipping a metric to 0. dino gates
# its extra top smoke; minion reports only, its vpu_top still hitting a derived
# clock inou.cgen.sim cannot fold (fixme issue 12). An empty $CORE_SIM_*_TB
# skips that driver.
#
#   MODE=pyrope   sim the <core>/pyrope tree directly.
#   MODE=pyrope2  the same over <core>/pyrope2 (defs.bzl points CORE_P_TOP there).
#   MODE=verilog  compile the Verilog through slang straight to an lgraph
#                 library (--emit-dir lg:) and sim THAT. It used to detour
#                 through `--emit-dir pyrope:` and sim the re-emitted source,
#                 which measured the Pyrope front end a second time and put an
#                 emitter round trip between the Verilog and the thing being
#                 simulated; `lhd sim` takes `lg:DIR` positionally, so the
#                 detour bought nothing.
#
# EVERY driver names its DUT as `import("lg:NAME")`, and this script supplies
# that module ahead of the testbench: the unit's own source under MODE=pyrope,
# the `lg:` library under MODE=verilog. Which module each driver drives is a
# per-core knob ($CORE_SIM_TB_UNIT and friends) because the lg: library is
# rooted at THAT module, not at $CORE_TOP: `lhd sim` cgen's every graph in the
# library it is handed, so pointing it at the whole-core library makes it
# refuse over modules the testbench never instantiates (minion's tensor RF
# benchmark died on `vpu_ctrl` and `intpipe_csr_file`, neither of them in its
# cone).
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

# Cycles for the asserted benchmark, passed explicitly as the `cycles` test
# parameter (every core's sim_tb declares one). This count does NOT apply to
# the separate whole-top correctness drivers near the end of this script.
: "${CYCLES:=$CORE_SIM_CYCLES}"
SIM_TB=$CORE_SIM_TB

# Several checksum oracles are intentionally pinned to their default cycle
# count. A longer throughput run still has the testbench's in-source assertions
# and required marker, but must not compare its later checksum with the default
# run's value.
if [ "$CYCLES" != "$CORE_SIM_CYCLES" ]; then
  CORE_SIM_EXPECT=
fi

# emit_lg TAG UNIT — MODE=verilog: compile the Verilog cone rooted at UNIT into
# lg:lg_TAG, timed as METRIC compile_lg_TAG_ms. One slang read of the whole
# filelist either way (an -F entry outside --top's cone is parsed and then
# discarded), so the cost that varies here is elaboration + lowering of the
# cone actually being simulated.
emit_lg() {
  run_timed "compile_lg_$1" lhd compile verilog --top "$2" \
    --emit-dir "lg:lg_$1" --workdir "tw_$1" -- \
    -F "$CORE_V_DIR/filelist.f" -DSYNTHESIS $CORE_V_FLAGS
}

# A driver without its unit would silently compile `--top ''` (MODE=verilog) or
# look for `tree/.prp` (MODE=pyrope). Catch a half-filled CORES entry here,
# where the message can name the knob, instead of downstream.
for _d in "SIM_TOP:$CORE_SIM_TOP_TB:$CORE_SIM_TOP_UNIT:sim_top_tb_unit" \
  "SIM_PROG:$CORE_SIM_PROG_TB:$CORE_SIM_PROG_UNIT:sim_prog_tb_unit"; do
  IFS=: read -r _n _tb _unit _knob <<<"$_d"
  [ -z "$_tb" ] || [ -n "$_unit" ] \
    || { echo "FAIL: core '$CORE' sets a $_n driver ('$_tb') but no $_knob" >&2; exit 2; }
done

# The positional design input for each driver, per mode. TOP_INPUT/PROG_INPUT
# stay empty when the core has no such driver.
TOP_INPUT=
PROG_INPUT=
case "${MODE:?}" in
pyrope | pyrope2 | incr)
  copy_core_pyrope tree
  BENCH_INPUT="tree/$CORE_SIM_TB_UNIT.prp"
  [ -z "$CORE_SIM_TOP_TB" ] || TOP_INPUT="tree/$CORE_SIM_TOP_UNIT.prp"
  [ -z "$CORE_SIM_PROG_TB" ] || PROG_INPUT="tree/$CORE_SIM_PROG_UNIT.prp"
  # A synth-only core's tree references DPI cells that exist only as generated
  # sink models. They go in BESIDE the design rather than as extra positional
  # inputs: sibling import discovery then resolves them, and `lhd sim` — which
  # cgen's every graph in the library it is handed — is not asked to emit 20
  # empty modules the testbench never instantiates.
  if [ -n "$CORE_P_STUB_DIR" ]; then
    cp -fL "$CORE_P_STUB_DIR"/*.prp tree/
  fi
  ;;
verilog)
  mkdir -p tree
  emit_lg bench "$CORE_SIM_TB_UNIT"
  BENCH_INPUT="lg:lg_bench"
  [ -z "$CORE_SIM_TB_V" ] || SIM_TB=$CORE_SIM_TB_V
  # A driver whose DUT is the benchmark's DUT reuses the same library; only a
  # different cone (minion: vpu_top vs vpu_tensora_rf) pays a second compile.
  if [ -n "$CORE_SIM_TOP_TB" ]; then
    if [ "$CORE_SIM_TOP_UNIT" = "$CORE_SIM_TB_UNIT" ]; then
      TOP_INPUT=$BENCH_INPUT
    else
      emit_lg top "$CORE_SIM_TOP_UNIT"
      TOP_INPUT="lg:lg_top"
    fi
  fi
  if [ -n "$CORE_SIM_PROG_TB" ]; then
    if [ "$CORE_SIM_PROG_UNIT" = "$CORE_SIM_TB_UNIT" ]; then
      PROG_INPUT=$BENCH_INPUT
    elif [ -n "$TOP_INPUT" ] && [ "$CORE_SIM_PROG_UNIT" = "$CORE_SIM_TOP_UNIT" ]; then
      PROG_INPUT=$TOP_INPUT
    else
      emit_lg prog "$CORE_SIM_PROG_UNIT"
      PROG_INPUT="lg:lg_prog"
    fi
  fi
  ;;
*)
  echo "FAIL: unknown MODE=$MODE" >&2
  exit 2
  ;;
esac
cp -L "$CORE_SIM_DIR"/*.prp tree/

SIM_INPUTS=("$BENCH_INPUT" "tree/$SIM_TB")

metric sim_backend_llvm 1 bool
SIMRT="$(dirname "$LHD_BIN")/lhd_simrt"
[ -x "$SIMRT" ] || { echo "Missing LiveHD native runtime at $SIMRT" >&2; exit 1; }
# Match the parallelism used to build the Verilator model.
case " ${CORE_SIM_SETS:-} " in
  *"lhd.jobs="*) ;;
  *) CORE_SIM_SETS="--set lhd.jobs=$(cpu_count) ${CORE_SIM_SETS:-}" ;;
esac

DRV_SETS=(--no-checkpoint)
for kv in ${CORE_SIM_SETS:-}; do
  case "$kv" in
    lhd.seed=*) DRV_SETS+=(--seed "${kv#*=}") ;;
    sim.init_zero=true) DRV_SETS+=(--init-zero) ;;
    compile.unknown_zero=true) DRV_SETS+=(--set sim.unknown_zero=true) ;;
    sim.warn_undefined=*) DRV_SETS+=(--set "$kv") ;;
  esac
done

# ---- MODE=incr: full plus the three-pass rebuild over ONE workdir ------------
#
# Time only setup. Compare the behavior of each native image against a fresh
# build of the same sources, including when the testbench detects the bug edit.
if [ "$MODE" = incr ]; then
  query_args=()
  if [ -n "${CORE_SIM_EDIT_SIGNAL:-}" ]; then
    python3 - "$CORE_SIM_EDIT_SIGNAL" "$CORE_SIM_EDIT_CYCLE" > edit_query.json <<'PYQUERY'
import json, sys
signal, cycle = sys.argv[1:]
print(json.dumps({"kind": "sim_query", "schema_version": 1, "queries": [
    {"id": "edit", "op": "value", "signal": signal, "at": {"cycle": int(cycle)}}
]}))
PYQUERY
    query_args=(--query edit_query.json)
  fi
  # sim_pass TAG [INCREMENTAL] [WORKDIR] builds the native simulator image.
  # It never launches the binary (sim_exec_built does, untimed).
  sim_pass() {
    local tag=$1 incremental=${2:-true} wd=${3:-SW}
    local incr_args=()
    [ "$incremental" != false ] || incr_args=(--set lhd.incremental=false)
    # shellcheck disable=SC2086  # CORE_SIM_SETS is a token LIST, split on purpose
    run_timed "sim_setup_$tag" lhd sim "${SIM_INPUTS[@]}" --setup-only \
    --set sim.vcd=false $CORE_SIM_SETS --workdir "$wd" \
      ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} \
      ${incr_args[@]+"${incr_args[@]}"} ${query_args[@]+"${query_args[@]}"} || return 1
    metric "workdir_bytes_$tag" "$(dir_bytes "$wd")" bytes
  }

  # sim_exec_built TAG [WORKDIR] — run the native image from sim_pass TAG, once
  # and untimed. Leaves its output in step_sim_exec_TAG.log and its exit status
  # in SIM_EXEC_RC; it does not judge either (the caller knows whether this tree
  # is supposed to pass).
  sim_exec_built() {
    local tag=$1 wd=${2:-SW}
    [ -s "$wd/sim/drv.tb.json" ] && [ -s "$wd/sim/drv.tb.o" ] \
      || { echo "FAIL: missing native testbench in $wd/sim" >&2; return 1; }
    log_cmd "sim_exec_$tag" "$SIMRT $wd/sim +cycles=$CYCLES ${DRV_SETS[*]}"
    SIM_EXEC_RC=0
    CURRENT_STEP=sim_exec_$tag "$SIMRT" "$wd/sim" "+cycles=$CYCLES" "${DRV_SETS[@]}" \
      --result-json "$wd/sim/exec_tests.json" >"step_sim_exec_$tag.log" 2>&1 || SIM_EXEC_RC=$?
    if [ -n "${CORE_SIM_EDIT_SIGNAL:-}" ]; then
      "$SIMRT" "$wd/sim" "+cycles=$CYCLES" "${DRV_SETS[@]}" --query-file edit_query.json \
        --replay-results "$wd/sim/exec_tests.json" --query-json "edit_query_$tag.json" || return 1
      python3 - "edit_query_$tag.json" >"edit_sample_$tag" <<'PYVALUE' || return 1
import json, sys
with open(sys.argv[1]) as request:
    result, = json.load(request)["results"]
if not result["ok"]:
    sys.exit(str(result))
value = result["value"]
if int(value["known_mask"], 16) != (1 << value["bits"]) - 1:
    sys.exit("edit observation contains unknown bits")
print(value["hex"])
PYVALUE
      cat "edit_sample_$tag" >>"step_sim_exec_$tag.log"
    fi
  }

  # sim_exec_same TAG REF [WORKDIR] — run TAG's native image and require the exit
  # status and every printed line REF's run produced.
  sim_exec_same() {
    local tag=$1 ref=$2 wd=${3:-SW}
    sim_exec_built "$tag" "$wd" || exit 1
    echo "$SIM_EXEC_RC" >"rc_sim_exec_$tag"
    if [ "$SIM_EXEC_RC" -eq "$(cat "rc_sim_exec_$ref")" ] \
      && cmp -s "step_sim_exec_$tag.log" "step_sim_exec_$ref.log"; then
      metric "sim_exec_${tag}_equals_${ref}" 1 bool
    else
      metric "sim_exec_${tag}_equals_${ref}" 0 bool
      echo "FAIL: the $tag build (exit $SIM_EXEC_RC) simulates differently from the $ref build (exit $(cat "rc_sim_exec_$ref")):" >&2
      diff "step_sim_exec_$ref.log" "step_sim_exec_$tag.log" | head -20 >&2
      exit 1
    fi
  }

  # Match only the loadable image, excluding cache keys and execution results.
  image_files=( '(' -name '*.o' -o -name '*.dut.json' -o -name 'drv.tb.json' ')' )
  # generated_newer MARKER lists image files touched since MARKER.
  # `find -newer`, not a timestamp read: a whole-second stamp cannot separate
  # two passes that land in the same second, and that makes a no-op pass look
  # green for the wrong reason.
  generated_newer() {
    find SW/sim -maxdepth 1 -type f \
      "${image_files[@]}" \
      -newer "$1" -exec basename {} \; 2>/dev/null | sort | tr '\n' ' '
  }

  rm -rf SW
  sim_pass full false || exit 1
  # The reference behavior of the unedited tree. Informational absolute gate:
  # sim_pyrope owns "is the simulation right".
  sim_exec_built full || exit 1
  echo "$SIM_EXEC_RC" >rc_sim_exec_full
  gate_ok=0
  if [ "$SIM_EXEC_RC" -eq 0 ] && grep -qa -- "$CORE_SIM_MARKER" step_sim_exec_full.log \
    && { [ -z "$CORE_SIM_EXPECT" ] || grep -qa -- "$CORE_SIM_EXPECT" step_sim_exec_full.log; }; then
    gate_ok=1
  else
    echo "NOTE: the from-scratch simulation itself fails the sim gate (exit $SIM_EXEC_RC); see ${CORE}_sim_pyrope. Incremental builds are still held to behaving identically."
  fi
  metric sim_exec_gate_ok "$gate_ok" bool

  rm -rf SW
  sim_pass cold || exit 1
  tree_fingerprint SW/sim "${image_files[@]}" >fp_cold.txt
  sim_exec_same cold full

  # Some old checked-in comment1 fixtures have drifted into structurally
  # different (though equivalent) implementations.  This pass measures a true
  # source-only no-op, so append a comment to the current unit exactly as the
  # compile incremental benchmark does.
  printf '\n// sim incremental comment-only touch\n' >> "tree/$CORE_UNIT.prp"
  echo "VARIANT comment-only: appended to $CORE_UNIT.prp" >&3
  touch marker
  sim_pass comment || exit 1
  rewritten=$(generated_newer marker)
  metric sim_rewritten_comment "$(echo "$rewritten" | wc -w | tr -d ' ')" files
  if [ -n "$rewritten" ]; then
    echo "NOTE: a comment-only edit rewrote $rewritten" >&2
  fi

  # H5, the mechanical "warm equals cold" check (I2). A cache that skipped work
  # must leave the same bytes a cold run would have written; anything else is a
  # miscompile wearing a speedup's clothes.
  tree_fingerprint SW/sim "${image_files[@]}" >fp_warm.txt
  if cmp -s fp_cold.txt fp_warm.txt; then
    metric sim_warm_equals_cold 1 bool
  else
    metric sim_warm_equals_cold 0 bool
    echo "FAIL: warm generated tree differs from cold for a comment-only edit:" >&2
    diff fp_cold.txt fp_warm.txt | head -20 >&2
    exit 1
  fi

  # The comment-only rebuild must still BE the from-scratch simulator, not just
  # look like it on disk.
  sim_exec_same comment full

  # The real edit must touch exactly ONE source file, or the pass cannot say
  # what is incremental and what simply changed everywhere.
  src_sums() { (cd tree && find . -maxdepth 1 -name '*.prp' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256); }
  src_sums >src_before.txt
  core_variant bug1 tree || exit 1
  src_sums >src_after.txt
  edited_files=$({ diff src_before.txt src_after.txt || true; } | sed -n 's/^> [0-9a-f]*  //p' | wc -l | tr -d ' ')
  metric sim_edit_source_files "$edited_files" files
  [ "$edited_files" -eq 1 ] \
    || { echo "FAIL: the incremental edit changed $edited_files source files; it must change exactly 1" >&2; exit 1; }
  touch marker
  sim_pass edit || exit 1
  rewritten=$(generated_newer marker)
  metric sim_rewritten_edit "$(echo "$rewritten" | wc -w | tr -d ' ')" files
  generated_total=$(find SW/sim -maxdepth 1 -type f "${image_files[@]}" | wc -l | tr -d ' ')
  metric sim_generated_total "$generated_total" files
  echo "NOTE: edited one source and rewrote $rewritten" >&2
  [ -n "$rewritten" ] \
    || { echo "FAIL: a real one-line edit rewrote NO generated file — stale cache" >&2; exit 1; }

  # The oracle for the edited tree: the SAME sources, from scratch, caches off,
  # in a workdir of its own. One module changed or the whole tree rebuilt, the
  # simulator must behave the same — exit status and every printed line.
  rm -rf SW_oracle
  sim_pass oracle false SW_oracle || exit 1
  sim_exec_built oracle SW_oracle || exit 1
  echo "$SIM_EXEC_RC" >rc_sim_exec_oracle
  sim_exec_same edit oracle
  if [ -n "${CORE_SIM_EDIT_SIGNAL:-}" ] && cmp -s edit_sample_full edit_sample_edit; then
    echo "FAIL: the edit did not change $CORE_SIM_EDIT_SIGNAL at cycle $CORE_SIM_EDIT_CYCLE" >&2
    exit 1
  fi
  # Informational: byte-identical generated sources would make the equality
  # above true by construction. Not a gate — an incremental compile may order
  # equivalent nodes differently — but a 0 here next to a 1 above is worth a look.
  tree_fingerprint SW/sim "${image_files[@]}" >fp_edit.txt
  # A moved timestamp can still have identical contents. Compare the path and
  # digest of each DUT object with the unedited build; exclude the testbench.
  read -r identical total < <(awk '
    FILENAME == ARGV[1] { before[$0] = 1; next }
    /[.]llvm[.]o$/ { total++; if ($0 in before) identical++ }
    END { print identical + 0, total + 0 }
  ' fp_warm.txt fp_edit.txt)
  metric sim_dut_objects_identical_edit "$identical" files
  metric sim_dut_objects_total_edit "$total" files
  tree_fingerprint SW_oracle/sim "${image_files[@]}" >fp_oracle.txt
  if cmp -s fp_edit.txt fp_oracle.txt; then
    metric sim_edit_tree_equals_oracle 1 bool
  else
    metric sim_edit_tree_equals_oracle 0 bool
  fi

  echo "PASS: sim_incremental built native images for full/cold/no-change/edit; cold and no-change simulate exactly like the caches-off build, the edit exactly like a from-scratch build of the edited tree"
  exit 0
fi

# shellcheck disable=SC2086  # CORE_SIM_SETS is a token LIST, split on purpose
run_timed sim_setup lhd sim "${SIM_INPUTS[@]}" --setup-only \
    --set sim.vcd=false $CORE_SIM_SETS --workdir SW \
  ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"}
# shellcheck disable=SC2086
SETUP_MS=$LAST_MS
run_timed sim_run lhd sim "${SIM_INPUTS[@]}" --run-only --set sim.checkpoint=false --arg "cycles=$CYCLES" \
  $CORE_SIM_SETS --diag-fmt pretty --workdir SW \
  ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"}

sim_gate sim_run
# A testbench without a `cycles` parameter would silently simulate its own
# default instead of $CYCLES, quietly turning cycles/s into a lie. lhd warns;
# make the warning fatal rather than let a new core drift in unnoticed.
if grep -qa "matches no test parameter" step_sim_run.log; then
  step_failed sim_run "'$SIM_TB' has no \`cycles\` test parameter — the asserted benchmark needs one"
  exit 1
fi

: "${SIM_REPS:=3}"
log_cmd sim_exec "$SIMRT SW/sim +cycles=$CYCLES ${DRV_SETS[*]} (x$SIM_REPS, best)"
best_run sim_exec "$SIM_REPS" "$SIMRT" SW/sim "+cycles=$CYCLES" "${DRV_SETS[@]}" \
  --result-json SW/sim/exec_tests.json
EXEC_MS=$BEST_MS
metric sim_exec_ms "$EXEC_MS" ms
metric sim_cycles "$CYCLES" cycles
rate sim_cycles_per_s "$CYCLES" "$EXEC_MS" "cycles/s"
rate sim_cycles_per_s_with_build "$CYCLES" "$((SETUP_MS + EXEC_MS))" "cycles/s"

# run_top_driver LABEL DESIGN_INPUT TB_BASENAME CYCLES -> echoes 1 (ran), 0
# (failed), or - (no such driver for this core). The design input comes first:
# the testbench's `import("lg:NAME")` names a module already compiled in this
# invocation, rather than a source path to discover. This is also where the VCD
# writer stays covered (--set sim.vcd=true), out of the timed path above.
# Never fails the test itself: the caller decides, per $CORE_SIM_TOP_ASSERT,
# whether a 0 is a metric or a gate.
run_top_driver() {
  local label=$1 design=$2 tb=$3 cycles=$4
  [ -n "$tb" ] || { echo "-"; return 0; }
  # shellcheck disable=SC2086
  if CURRENT_STEP=$label lhd sim "$design" "tree/$tb" \
    --arg "cycles=$cycles" --set sim.vcd=true $CORE_SIM_SETS --diag-fmt pretty \
    --workdir "SW_$label" ${PYROPE_ARGS[@]+"${PYROPE_ARGS[@]}"} \
    >"step_$label.log" 2>&1; then
    echo 1
  else
    echo 0
  fi
}

# Whole-top driver, then (if the core defines one) the program driver.
cpu_ok=$(run_top_driver sim_cpu "$TOP_INPUT" "$CORE_SIM_TOP_TB" "$CORE_SIM_TOP_CYCLES")
if [ "$cpu_ok" != - ]; then
  metric sim_cpu_top_ok "$cpu_ok" bool
  metric sim_cpu_top_cycles "$CORE_SIM_TOP_CYCLES" cycles
fi

prog_ok=$(run_top_driver sim_cpu_prog "$PROG_INPUT" "$CORE_SIM_PROG_TB" "$CORE_SIM_PROG_CYCLES")
if [ "$prog_ok" != - ]; then
  metric sim_cpu_prog_ok "$prog_ok" bool
  metric sim_cpu_prog_cycles "$CORE_SIM_PROG_CYCLES" cycles
  [ "$prog_ok" != 1 ] || grep -a "IPC=" step_sim_cpu_prog.log || true
fi

top_gated=0
[ -z "$CORE_SIM_TOP_ASSERT" ] || top_gated=1
metric sim_cpu_top_gated "$top_gated" bool

# CORE_SIM_TOP_ASSERT (defs.bzl): do this core's additional whole-top drivers
# GATE the target, or only report a metric? dino's top smoke does — it scores 1
# in both modes — so a regression there fails the target instead of silently
# flipping a metric to 0. A core still blocked by an lhd gap (minion: a derived
# clock inou.cgen.sim cannot fold, fixme issue 12) leaves it empty and keeps the
# metric, so the flip to 1 stays visible without painting the target red.
if [ -n "$CORE_SIM_TOP_ASSERT" ]; then
  [ "$cpu_ok" != 0 ] \
    || { step_failed sim_cpu "whole-top driver '$CORE_SIM_TOP_TB' failed (MODE=$MODE)"; exit 1; }
  [ "$prog_ok" != 0 ] \
    || { step_failed sim_cpu_prog "program driver '$CORE_SIM_PROG_TB' failed (MODE=$MODE)"; exit 1; }
else
  case "$cpu_ok$prog_ok" in
  11 | 1-) ;;
  *) echo "NOTE: whole-top sim still unsupported (informational; not a failure)" ;;
  esac
fi
echo "PASS: $MODE $SIM_TB benchmark ($SETUP_MS ms setup, $CYCLES cycles in $EXEC_MS ms)"
