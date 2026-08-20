#!/usr/bin/env bash
# The Verilator side of the simulation benchmark: the SAME Verilog, the same
# program, the same output gates as //bench:<core>_sim_verilog, so the two
# targets can be read metric against metric.
#
# What it answers: how does `lhd sim` compare with the reference open-source
# Verilog simulator, on compile time AND on simulation throughput? Both halves
# matter and they pull in opposite directions — an aggressively optimizing
# translator buys cycles/s with build seconds — so the flow is split into the
# same three steps `lhd sim` is split into, under the same metric names:
#
#   sim_setup_ms  verilator --cc --exe        (front end + C++ emission;
#                 the twin of `lhd sim --setup-only`)
#   sim_cc_ms     make -f V<top>.mk -j        (host C++ compile + link; the
#                 twin of the compile inside `lhd sim --run-only`)
#   sim_exec_ms   the built binary, re-run    (the simulation alone)
#
# FAIRNESS. Three things are deliberately held equal to the lhd side:
#   * the SOURCE — the same `-F <core>/verilog/filelist.f -DSYNTHESIS`, so
#     both simulators read the same RTL rather than one of them reading a
#     re-emission of it;
#   * the GATES — sim_gate applies $CORE_SIM_MARKER and $CORE_SIM_EXPECT to
#     both, and dino/sim/dino_prog_tb_verilator.cpp mirrors the Pyrope driver's
#     stimulus schedule exactly, so the two must agree on the architectural
#     result (they print the same `done at cycle` today) or a target fails;
#   * NO VCD on either side — this script does not pass `--trace` and
#     bench/sim.sh's timed leg runs `--set sim.vcd=false`, so neither binary
#     carries tracing code. See the header of bench/sim.sh for why the tracer
#     came out of the measured interval.
# What is NOT equalized is verilator's own optimization level: this runs it as
# a user would out of the box (whatever -Wno-fatal is needed for the core's
# lint, plus the core's `verilator_flags`), not tuned for the benchmark.
#
# TWO RUNS, and why. The matched run uses $CORE_SIM_CYCLES — the exact count
# the lhd targets use — so sim_exec_ms and sim_cycles_per_s_with_cc line up
# row for row. But it is far too short to MEASURE verilator with: dino at
# 20k cycles takes ~7 ms, i.e. mostly process startup. So a second, long run at
# $CORE_VERILATOR_CYCLES reports the throughput number
# (sim_long_cycles_per_s) — unless the core sets verilator_cycles EQUAL to
# sim_cycles, meaning its matched count is already long enough to measure, in
# which case the matched run IS the throughput run and 3b is skipped.
# Both runs are gated, but not identically: the matched run carries the full
# marker+data gate, since it is the one that has to agree with `lhd sim`, while
# the long run is marker-only — a driver that folds a checksum over the whole
# run prints a different (correct) value at a different count. See step 3b.
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

[ "${MODE:?}" = verilator ] || { echo "FAIL: unknown MODE=$MODE" >&2; exit 2; }
[ -n "$CORE_VERILATOR_TB" ] || {
  echo "FAIL: core '$CORE' has no verilator_tb (this target should not exist)" >&2
  exit 2
}

# Verilator is an OUTSIDE point of comparison, not something the suite is
# responsible for shipping, so a machine without it SKIPS instead of failing.
# The metric is still emitted (0), so //bench:show reports "skipped" rather
# than silently leaving the row blank as if the target had never run.
if ! find_verilator; then
  metric verilator_present 0 bool
  echo "SKIP: verilator is not installed on this machine — skipping the" \
    "verilator comparison (install it with 'brew install verilator' /" \
    "'apt install verilator', or export VERILATOR=<path>; bazel passes" \
    "VERILATOR through the test sandbox)."
  exit 0
fi
metric verilator_present 1 bool

: "${CYCLES:=$CORE_SIM_CYCLES}"
: "${LONG_CYCLES:=$CORE_VERILATOR_CYCLES}"
: "${SIM_REPS:=3}"
VTB=$CORE_SIM_DIR/$CORE_VERILATOR_TB
VOBJ=vobj
VBIN=$VOBJ/V$CORE_TOP
VERSION=$("$VERILATOR_BIN" --version)

# --- 1. verilate: SystemVerilog -> C++ ---------------------------------------
# --cc --exe (not --build) so the C++ compile is a separate, separately timed
# step, exactly as `lhd sim --setup-only` / `--run-only` separate them.
# -Wno-fatal: these are real designs and verilator's lint is not the thing
# under test — dino trips UNOPTFLAT on the whole-`io` struct wires the Chisel
# emitter produces, which verilator handles by iterating (a throughput cost it
# pays honestly, not an error).
# -I$CORE_V_DIR: a core whose RTL `\`include`s a generated header next to it
# (minion's intpipe_csr_file_auto_*.svh) resolves under slang WITHOUT a flag —
# slang looks relative to the INCLUDING file — but verilator only searches its
# -I list, so the same sources fail to verilate. Adding the core's own Verilog
# directory makes the two front ends see the same files, which is the whole
# premise of this comparison. Core-agnostic: it is always the right include
# root, and a core with no such includes is unaffected.
run_timed sim_setup vlt --cc --exe --Mdir "$VOBJ" --top-module "$CORE_TOP" \
  -Wno-fatal $CORE_VERILATOR_FLAGS -DSYNTHESIS -I"$CORE_V_DIR" \
  -F "$CORE_V_DIR/filelist.f" "$VTB"

# --- 2. host C++ compile + link ----------------------------------------------
JOBS=$(cpu_count)
log_cmd sim_cc "make -C $VOBJ -f V$CORE_TOP.mk -j$JOBS V$CORE_TOP"
run_timed sim_cc make -C "$VOBJ" -f "V$CORE_TOP.mk" -j"$JOBS" "V$CORE_TOP"
CC_MS=$LAST_MS  # run_timed already reported it as METRIC sim_cc_ms

# --- 3a. matched run: the cycle count the lhd sim targets use -----------------
log_cmd sim_exec "$VBIN --cycles $CYCLES  (x$SIM_REPS, best)"
best_run sim_exec "$SIM_REPS" "./$VBIN" --cycles "$CYCLES"
EXEC_MS=$BEST_MS
metric sim_exec_ms "$EXEC_MS" ms
metric sim_cycles "$CYCLES" cycles
rate sim_cycles_per_s "$CYCLES" "$EXEC_MS" "cycles/s"
# Everything a cold `verilate + build + simulate` costs, the counterpart of the
# lhd row's sim_run_ms (host compile + simulation) at the same cycle count.
rate sim_cycles_per_s_with_cc "$CYCLES" "$((CC_MS + EXEC_MS))" "cycles/s"

# --- 3b. long run: the throughput number --------------------------------------
# Skipped when the core's verilator_cycles EQUALS its sim_cycles, which is how
# the XiangShan blocks are tuned: their matched count is already sized for a
# 1-2 s verilator run, so a second leg at the same count would measure the same
# thing twice and double the target's wall time. The metrics are still emitted
# (from the matched run) so //bench:show has a row either way. Same
# short-circuit bench/sim.sh applies to its own PERF_CYCLES leg.
#
# When it does run it is MARKER ONLY (SIM_GATE_EXPECT=0), again the same
# relaxation as bench/sim.sh's throughput leg and for the same reason: a
# different cycle count is a different result by construction. dino's
# $CORE_SIM_EXPECT is a readback that holds at any count past ~510 cycles, but a
# driver that folds a CHECKSUM over the whole run prints a different (correct)
# value at a different count. The full gate still applies to the matched run
# above — the leg that has to agree with `lhd sim` — and the marker gate applies
# here, so a long run that died before its report is still a failure.
if [ "$LONG_CYCLES" != "$CYCLES" ]; then
  log_cmd sim_exec_long "$VBIN --cycles $LONG_CYCLES  (x$SIM_REPS, best)"
  SIM_GATE_EXPECT=0 best_run sim_exec_long "$SIM_REPS" "./$VBIN" --cycles "$LONG_CYCLES"
  LONG_MS=$BEST_MS
else
  LONG_MS=$EXEC_MS
fi
metric sim_long_exec_ms "$LONG_MS" ms
metric sim_long_cycles "$LONG_CYCLES" cycles
rate sim_long_cycles_per_s "$LONG_CYCLES" "$LONG_MS" "cycles/s"

LONG_NOTE="$LONG_CYCLES-cycle run for throughput"
[ "$LONG_CYCLES" != "$CYCLES" ] || LONG_NOTE="matched run is the throughput run"
echo "PASS: $VERSION, $CORE_VERILATOR_TB benchmark ($CYCLES cycles in ${EXEC_MS} ms" \
  "sim, ${CC_MS} ms host c++; $LONG_NOTE)"
