#!/usr/bin/env bash
# Hello-world `lhd sim` smoke over real dino modules.
#
# Asserted: the StageReg testbench (dino/sim/stagereg_tb.prp) — setup
# (compile + host C++ build) and run phases timed separately, cycles/s
# reported. Informational: the whole-CPU testbench (dino/sim/dino_tb.prp),
# which today fails with comb-loop-through-instance on the register file;
# its status is METRIC sim_cpu_top_ok, so the flip to 1 is visible the day
# support lands.
#
#   MODE=pyrope   sim the dino/pyrope tree directly.
#   MODE=verilog  first re-emit the Verilog through slang as Pyrope
#                 (--emit-dir pyrope:) — the sim front-end is .prp-only —
#                 then sim that tree with the same testbenches.
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

CYCLES=1000  # stagereg_tb.prp test-parameter default

case "${MODE:?}" in
pyrope)
  mkdir -p tree
  cp -L "$DINO_P_DIR"/*.prp "$DINO_P_DIR"/manifest.json tree/
  ;;
verilog)
  run_timed transpile lhd compile verilog --top PipelinedDualIssueCPU \
    --emit-dir pyrope:tree --workdir tw -- -F "$DINO_V_DIR/filelist.f" -DSYNTHESIS
  ;;
*)
  echo "FAIL: unknown MODE=$MODE" >&2
  exit 2
  ;;
esac
cp -L "$DINO_SIM_DIR"/*.prp tree/

# sim.vcd rides BOTH phases: the run phase compiles the driver and only links
# hlop's VCD writer when the flag is present on that invocation too.
run_timed sim_setup lhd sim tree/stagereg_tb.prp --setup-only \
  --set sim.vcd=true --workdir SW
run_timed sim_run lhd sim tree/stagereg_tb.prp --run-only \
  --set sim.vcd=true --diag-fmt pretty --workdir SW
grep -qa "hello world" step_sim_run.log \
  || { echo "FAIL: sim ran but printed no hello world" >&2; tail -20 step_sim_run.log >&2; exit 1; }
rate sim_cycles_per_s "$CYCLES" "$LAST_MS" "cycles/s"

# Whole-CPU top: informational until lhd sim handles the register-file
# comb-feedback instance pattern (see dino/sim/dino_tb.prp). Two testbenches:
# the NOP-stream smoke, and the real RISC-V program (loop incrementing x2 /
# decrementing x3, counters exposed via stores, IPC printed) — its asserts and
# IPC go live the day the limitation lands.
if lhd sim tree/dino_tb.prp --workdir SW_cpu >step_sim_cpu.log 2>&1; then
  cpu_ok=1
else
  cpu_ok=0
fi
metric sim_cpu_top_ok "$cpu_ok" bool
if CURRENT_STEP=sim_cpu_prog lhd sim tree/dino_prog_tb.prp --diag-fmt pretty \
  --workdir SW_prog >step_sim_cpu_prog.log 2>&1; then
  prog_ok=1
  grep -a "IPC=" step_sim_cpu_prog.log || true
else
  prog_ok=0
fi
metric sim_cpu_prog_ok "$prog_ok" bool
[ "$cpu_ok$prog_ok" = 11 ] || echo "NOTE: whole-CPU sim still unsupported (informational; not a failure)"
echo "PASS: $MODE StageReg hello world ($CYCLES cycles in ${LAST_MS} ms)"
