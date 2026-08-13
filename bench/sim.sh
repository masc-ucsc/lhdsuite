#!/usr/bin/env bash
# Asserted `lhd sim` benchmark over real modules of the design under test.
#
# Asserted and timed: the per-core benchmark testbench ($CORE_SIM_TB). It must
# print $CORE_SIM_MARKER AND, when the core sets $CORE_SIM_EXPECT, known-good data
# readback. The testbenches now ALSO assert that value in-source; the
# printed-value gate is kept as belt-and-braces, since it also catches a driver
# that runs but never reaches its assert. Anything else fails the target.
#
# THE TIME SPLIT. `lhd sim --setup-only` only WRITES the driver sources; the
# host C++ compile happens inside `--run-only`, which rebuilds drv.bin on every
# invocation (inou.cgen.sim digests the generated sources, but nothing caches
# the built binary). On dino that clang++ -O2 of the Slop headers is 5-8 s
# against a simulation of a couple of seconds, so a `sim_run_ms` read as
# "simulation" is really a clang timing — which is why the two MODEs used to
# differ 2.5x while emitting byte-identical C++. So the run is measured twice:
#   sim_run_ms   `lhd sim --run-only`: host C++ compile + link + simulate
#   sim_exec_ms  the drv.bin it just built, re-run with the same arguments:
#                the simulation alone
#   sim_cc_ms    the remainder, i.e. the C++ compile+link
# and cycles/s is reported both ways: sim_cycles_per_s over the simulation
# alone, sim_cycles_per_s_with_cc over compile+simulation.
#
# NO VCD IN THE TIMED PATH. The timed leg runs `--set sim.vcd=false`. It used
# to bake a VCD in, and that made `sim_exec_ms` mostly a tracer stopwatch: on
# dino at 2000 cycles the writer produced 9.8 MB and cost 40-75% of the
# measured interval, with a 0.36 s / 0.91 s spread on ONE unchanged binary as
# the filesystem stalled — a benchmark measuring two things, the exact trap
# AGENTS.md records for `sim_run_ms`. It also made the //bench:*_sim_verilator
# comparison meaningless, since verilator built without `--trace` carries no
# tracing code at all (`sim.vcd=false` likewise emits none: the generated
# .hpp drops from 29 vcd references to 2). The VCD writer is still covered by
# the suite — the untimed whole-top correctness drivers below run with
# `--set sim.vcd=true`.
#
# Additional whole-top correctness drivers: $CORE_SIM_TOP_TB and, where the
# core has one, a program-driving testbench ($CORE_SIM_PROG_TB). They run
# separately from the timed benchmark above, at $CORE_SIM_TOP_CYCLES /
# $CORE_SIM_PROG_CYCLES. Both are always reported as METRIC sim_cpu_top_ok /
# sim_cpu_prog_ok; with
# $CORE_SIM_TOP_ASSERT set they ALSO gate the target, so a regression fails it
# instead of silently flipping a metric to 0. dino gates its extra top smoke;
# minion reports only, its vpu_top still hitting a derived clock inou.cgen.sim
# cannot fold (fixme issue 12). An empty $CORE_SIM_*_TB skips that driver.
#
#   MODE=pyrope   sim the <core>/pyrope tree directly.
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
pyrope)
  copy_core_pyrope tree
  BENCH_INPUT="tree/$CORE_SIM_TB_UNIT.prp"
  [ -z "$CORE_SIM_TOP_TB" ] || TOP_INPUT="tree/$CORE_SIM_TOP_UNIT.prp"
  [ -z "$CORE_SIM_PROG_TB" ] || PROG_INPUT="tree/$CORE_SIM_PROG_UNIT.prp"
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

# The setup phase WRITES the driver sources; sim.vcd is read back from what was
# baked, so it is fixed here and not at --run-only. See the header for why the
# timed leg keeps the tracer out.
# shellcheck disable=SC2086  # CORE_SIM_SETS is a token LIST, split on purpose
run_timed sim_setup lhd sim "${SIM_INPUTS[@]}" --setup-only \
  --set sim.vcd=false $CORE_SIM_SETS --workdir SW
# sim.ninja=false PINS the build path. `lhd sim` uses ninja when it finds one on
# PATH and its own parallel compile otherwise — great for a developer's warm
# edit-sim loop, useless here (every target starts from a fresh workdir, so
# nothing is ever incremental) and bad for a benchmark: sim_cc_ms would then
# depend on whether the machine happens to have ninja. Bazel's test PATH does
# not currently carry it, so this only makes today's behaviour explicit and
# immune to that changing. Not a workaround for a failure — the ninja path is
# covered by livehd's own lhd_sim_incremental_test.
# shellcheck disable=SC2086
run_timed sim_run lhd sim "${SIM_INPUTS[@]}" --run-only --arg "cycles=$CYCLES" \
  --set sim.ninja=false $CORE_SIM_SETS --diag-fmt pretty --workdir SW
RUN_MS=$LAST_MS  # compile + simulate; sim_exec below splits it

sim_gate sim_run
# A testbench without a `cycles` parameter would silently simulate its own
# default instead of $CYCLES, quietly turning cycles/s into a lie. lhd warns;
# make the warning fatal rather than let a new core drift in unnoticed.
if grep -qa "matches no test parameter" step_sim_run.log; then
  step_failed sim_run "'$SIM_TB' has no \`cycles\` test parameter — the asserted benchmark needs one"
  exit 1
fi

# The simulation on its own: re-run the driver `lhd sim` just built, with the
# same arguments it passed (`--arg k=v` reaches the binary as `--k v`; the
# result sidecar goes to its own path so lhd's stays untouched). The remainder
# against sim_run_ms is the host C++ compile+link. BEST of $SIM_REPS, not one
# sample — see best_run in common.sh. The `+c++` rate stays single-shot,
# because sim_run_ms is the real cost of one `lhd sim`.
: "${SIM_REPS:=3}"
DRV=SW/sim/drv.bin
log_cmd sim_exec "$DRV --cycles $CYCLES --result-json SW/sim/exec_tests.json  (x$SIM_REPS, best)"
best_run sim_exec "$SIM_REPS" "$DRV" --cycles "$CYCLES" \
  --result-json SW/sim/exec_tests.json
EXEC_MS=$BEST_MS
metric sim_exec_ms "$EXEC_MS" ms
CC_MS=$((RUN_MS - EXEC_MS))
[ "$CC_MS" -ge 0 ] || CC_MS=0  # only reachable if a stall hit the lhd run instead
metric sim_cc_ms "$CC_MS" ms
metric sim_cycles "$CYCLES" cycles
rate sim_cycles_per_s "$CYCLES" "$EXEC_MS" "cycles/s"
rate sim_cycles_per_s_with_cc "$CYCLES" "$RUN_MS" "cycles/s"

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
    --workdir "SW_$label" >"step_$label.log" 2>&1; then
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
echo "PASS: $MODE $SIM_TB benchmark ($CYCLES cycles in ${EXEC_MS} ms sim," \
  "${CC_MS} ms host c++)"
