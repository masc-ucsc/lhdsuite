#!/usr/bin/env bash
# Hello-world `lhd sim` smoke over real modules of the design under test.
#
# Asserted: the small clocked-unit testbench ($CORE_SIM_TB). It must print
# "hello world" AND, when the core sets $CORE_SIM_EXPECT, the known-good data
# readback. The testbenches now ALSO assert that value in-source; the
# printed-value gate is kept as belt-and-braces, since it also catches a driver
# that runs but never reaches its assert. Anything else fails the target.
#
# THE TIME SPLIT. `lhd sim --setup-only` only WRITES the driver sources; the
# host C++ compile happens inside `--run-only`, which rebuilds drv.bin on every
# invocation (inou.cgen.sim digests the generated sources, but nothing caches
# the built binary). On dino that clang++ -O2 of the Slop headers is 5-8 s
# against a simulation of well under 2 s, so a `sim_run_ms` read as "simulation"
# is really a clang timing — which is why the two MODEs used to differ 2.5x
# while emitting byte-identical C++. So the run is measured twice:
#   sim_run_ms   `lhd sim --run-only`: host C++ compile + link + simulate
#   sim_exec_ms  the drv.bin it just built, re-run with the same arguments:
#                the simulation alone (VCD writing included — sim.vcd is baked
#                into the binary at setup, see below)
#   sim_cc_ms    the remainder, i.e. the C++ compile+link
# and cycles/s is reported both ways: sim_cycles_per_s over the simulation
# alone, sim_cycles_per_s_with_cc over compile+simulation.
#
# Whole-top drivers: $CORE_SIM_TOP_TB and, where the core has one, a
# program-driving testbench ($CORE_SIM_PROG_TB). Both are always reported as
# METRIC sim_cpu_top_ok / sim_cpu_prog_ok; with $CORE_SIM_TOP_ASSERT set they
# ALSO gate the target, so a regression fails it instead of silently flipping a
# metric to 0. dino asserts both — they score 1 in both modes; minion reports
# only, its vpu_top still hitting a derived clock inou.cgen.sim cannot fold
# (fixme issue 12). An empty $CORE_SIM_*_TB skips that driver entirely.
#
#   MODE=pyrope   sim the <core>/pyrope tree directly, at $CORE_TOP.
#   MODE=verilog  first re-emit the Verilog through slang as Pyrope
#                 (--emit-dir pyrope:) — the sim front-end is .prp-only —
#                 then sim that tree with the same testbenches, except that a
#                 core setting $CORE_SIM_TB_V swaps the asserted driver for its
#                 verilog-tree twin (a `struct packed` port re-emits as a tuple
#                 port, which a flat-port driver cannot address; see defs.bzl).
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

# Cycles for the ASSERTED unit smoke, passed explicitly as the `cycles` test
# parameter (every core's sim_tb declares one). It used to ride on the
# testbench's own default of 1000, which simulates in ~10 ms — three orders
# below the host C++ compile in the same step, so the cycle count was pure
# noise. 200k puts the simulation at 0.5-1.6 s on the current cores (VCD a few
# MB), measurable on its own. The whole-top drivers below keep their in-source
# defaults: dino_prog_tb asserts about a program that finishes near cycle 506,
# and the whole-CPU sims are far slower per cycle than a leaf unit.
: "${CYCLES:=200000}"
SIM_TB=$CORE_SIM_TB

case "${MODE:?}" in
pyrope)
  copy_core_pyrope tree
  ;;
verilog)
  run_timed transpile lhd compile verilog --top "$CORE_TOP" \
    --emit-dir pyrope:tree --workdir tw -- -F "$CORE_V_DIR/filelist.f" -DSYNTHESIS $CORE_V_FLAGS
  [ -z "$CORE_SIM_TB_V" ] || SIM_TB=$CORE_SIM_TB_V
  ;;
*)
  echo "FAIL: unknown MODE=$MODE" >&2
  exit 2
  ;;
esac
cp -L "$CORE_SIM_DIR"/*.prp tree/

# sim.vcd is set ONCE, at setup: it is a driver-affecting setting, so the run
# phase reads back what was baked and links hlop's VCD writer accordingly.
run_timed sim_setup lhd sim "tree/$SIM_TB" --setup-only \
  --set sim.vcd=true --workdir SW
# sim.ninja=false PINS the build path. `lhd sim` uses ninja when it finds one on
# PATH and its own parallel compile otherwise — great for a developer's warm
# edit-sim loop, useless here (every target starts from a fresh workdir, so
# nothing is ever incremental) and bad for a benchmark: sim_cc_ms would then
# depend on whether the machine happens to have ninja. Bazel's test PATH does
# not currently carry it, so this only makes today's behaviour explicit and
# immune to that changing. Not a workaround for a failure — the ninja path is
# covered by livehd's own lhd_sim_incremental_test.
run_timed sim_run lhd sim "tree/$SIM_TB" --run-only --arg "cycles=$CYCLES" \
  --set sim.ninja=false --diag-fmt pretty --workdir SW
RUN_MS=$LAST_MS  # compile + simulate; sim_exec below splits it

# sim_gate LABEL — the two output gates, applied to a step's log.
sim_gate() {
  grep -qa "hello world" "step_$1.log" \
    || { step_failed "$1" "sim ran but printed no hello world"; exit 1; }
  [ -n "$CORE_SIM_EXPECT" ] || return 0
  # The data gate. No extra grep: the sim's readback is the last thing it
  # prints, so it is already inside the excerpt step_failed shows.
  grep -qa -- "$CORE_SIM_EXPECT" "step_$1.log" \
    || { step_failed "$1" "sim ran but data is wrong (expected '$CORE_SIM_EXPECT')"; exit 1; }
}
sim_gate sim_run
# A testbench without a `cycles` parameter would silently simulate its own
# default instead of $CYCLES, quietly turning cycles/s into a lie. lhd warns;
# make the warning fatal rather than let a new core drift in unnoticed.
if grep -qa "matches no test parameter" step_sim_run.log; then
  step_failed sim_run "'$SIM_TB' has no \`cycles\` test parameter — the asserted sim smoke needs one"
  exit 1
fi

# The simulation on its own: re-run the driver `lhd sim` just built, with the
# same arguments it passed (`--arg k=v` reaches the binary as `--k v`; the
# result sidecar goes to its own path so lhd's stays untouched). The remainder
# against sim_run_ms is the host C++ compile+link.
#
# BEST of $SIM_REPS, not one sample. This is the shortest thing the suite times
# and the one it most wants to be honest about, and a dev box stalls: measured
# here on ONE unchanged binary, ten back-to-back runs of the same 200k cycles
# gave 8 x ~1.25 s, one 3.0 s and one 17.4 s. A mean carries the stall and a
# single sample IS the stall one run in ten, so take the minimum — the standard
# estimator for "how fast does this go" under one-sided noise. Cheap: the extra
# reps cost ~1 s each against a compile of ten times that. The `+c++` rate stays
# single-shot, because sim_run_ms is the real cost of one `lhd sim`.
: "${SIM_REPS:=3}"
DRV=SW/sim/drv.bin
log_cmd sim_exec "$DRV --cycles $CYCLES --result-json SW/sim/exec_tests.json  (x$SIM_REPS, best)"
EXEC_MS=
for _rep in $(seq "$SIM_REPS"); do
  _t0=$(now_ms)
  CURRENT_STEP=sim_exec "$DRV" --cycles "$CYCLES" \
    --result-json SW/sim/exec_tests.json >step_sim_exec.log 2>&1 \
    || { step_failed sim_exec "the driver lhd built exited non-zero on its own (rep $_rep)"; exit 1; }
  _t1=$(now_ms)
  _ms=$((_t1 - _t0))
  { [ -n "$EXEC_MS" ] && [ "$EXEC_MS" -le "$_ms" ]; } || EXEC_MS=$_ms
  sim_gate sim_exec
done
metric sim_exec_ms "$EXEC_MS" ms
CC_MS=$((RUN_MS - EXEC_MS))
[ "$CC_MS" -ge 0 ] || CC_MS=0  # only reachable if a stall hit the lhd run instead
metric sim_cc_ms "$CC_MS" ms
metric sim_cycles "$CYCLES" cycles
rate sim_cycles_per_s "$CYCLES" "$EXEC_MS" "cycles/s"
rate sim_cycles_per_s_with_cc "$CYCLES" "$RUN_MS" "cycles/s"

# run_top_driver LABEL TB_BASENAME -> echoes 1 (ran), 0 (failed), or - (no such
# driver for this core). Supply the design before the testbench: an `lg:NAME`
# import names a module already compiled in this invocation, rather than a
# source path to discover. Never fails the test itself: the caller decides,
# per $CORE_SIM_TOP_ASSERT, whether a 0 is a metric or a gate.
run_top_driver() {
  local label=$1 tb=$2
  [ -n "$tb" ] || { echo "-"; return 0; }
  if CURRENT_STEP=$label lhd sim "tree/$CORE_TOP.prp" "tree/$tb" --diag-fmt pretty \
    --workdir "SW_$label" >"step_$label.log" 2>&1; then
    echo 1
  else
    echo 0
  fi
}

# Whole-top driver, then (if the core defines one) the program driver.
cpu_ok=$(run_top_driver sim_cpu "$CORE_SIM_TOP_TB")
[ "$cpu_ok" = - ] || metric sim_cpu_top_ok "$cpu_ok" bool

prog_ok=$(run_top_driver sim_cpu_prog "$CORE_SIM_PROG_TB")
if [ "$prog_ok" != - ]; then
  metric sim_cpu_prog_ok "$prog_ok" bool
  [ "$prog_ok" != 1 ] || grep -a "IPC=" step_sim_cpu_prog.log || true
fi

# CORE_SIM_TOP_ASSERT (defs.bzl): does this core's whole-top driver GATE the
# target, or only report a metric? dino's does — both its drivers score 1 in
# both modes — so a regression there fails the target instead of silently
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
echo "PASS: $MODE $SIM_TB hello world ($CYCLES cycles in ${EXEC_MS} ms sim," \
  "${CC_MS} ms host c++)"
