#!/usr/bin/env bash
# Hello-world `lhd sim` smoke over real modules of the design under test.
#
# Asserted: the small clocked-unit testbench ($CORE_SIM_TB) — setup (compile +
# host C++ build) and run phases timed separately, cycles/s reported. It must
# print "hello world" AND, when the core sets $CORE_SIM_EXPECT, the known-good
# data readback. The testbenches now ALSO assert that value in-source; the
# printed-value gate is kept as belt-and-braces, since it also catches a driver
# that runs but never reaches its assert. Anything else fails the target.
#
# Informational: the whole-top testbench ($CORE_SIM_TOP_TB) and, where the
# core has one, a program-driving testbench ($CORE_SIM_PROG_TB). Both are
# reported as METRIC sim_cpu_top_ok / sim_cpu_prog_ok rather than asserted, so
# the flip to 1 is visible the day the underlying lhd support lands. dino's
# whole-CPU drivers score 1 on the checked-in Pyrope tree but 0 on the
# re-emitted Verilog one, where cgen spells a child instance's tuple port two
# different ways and the driver fails to build (fixme.md issue 6); promote
# them to asserted once that is fixed. An empty $CORE_SIM_*_TB skips that
# driver entirely.
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

CYCLES=1000  # testbench `cycles` test-parameter default
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
run_timed sim_run lhd sim "tree/$SIM_TB" --run-only \
  --diag-fmt pretty --workdir SW
grep -qa "hello world" step_sim_run.log \
  || { echo "FAIL: sim ran but printed no hello world" >&2; tail -20 step_sim_run.log >&2; exit 1; }
if [ -n "$CORE_SIM_EXPECT" ]; then
  grep -qa -- "$CORE_SIM_EXPECT" step_sim_run.log \
    || { echo "FAIL: sim ran but data is wrong (expected '$CORE_SIM_EXPECT'):" >&2
      grep -a "hello world" step_sim_run.log >&2; exit 1; }
fi
rate sim_cycles_per_s "$CYCLES" "$LAST_MS" "cycles/s"

# run_informational LABEL TB_BASENAME -> echoes 1/0 (never fails the test).
run_informational() {
  local label=$1 tb=$2
  [ -n "$tb" ] || { echo "-"; return 0; }
  if CURRENT_STEP=$label lhd sim "tree/$tb" --diag-fmt pretty \
    --workdir "SW_$label" >"step_$label.log" 2>&1; then
    echo 1
  else
    echo 0
  fi
}

# Whole-top driver, then (if the core defines one) the program driver.
cpu_ok=$(run_informational sim_cpu "$CORE_SIM_TOP_TB")
[ "$cpu_ok" = - ] || metric sim_cpu_top_ok "$cpu_ok" bool

prog_ok=$(run_informational sim_cpu_prog "$CORE_SIM_PROG_TB")
if [ "$prog_ok" != - ]; then
  metric sim_cpu_prog_ok "$prog_ok" bool
  [ "$prog_ok" != 1 ] || grep -a "IPC=" step_sim_cpu_prog.log || true
fi

case "$cpu_ok$prog_ok" in
11 | 1-) ;;
*) echo "NOTE: whole-top sim still unsupported (informational; not a failure)" ;;
esac
echo "PASS: $MODE $SIM_TB hello world ($CYCLES cycles in ${LAST_MS} ms)"
