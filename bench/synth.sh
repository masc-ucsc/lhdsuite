#!/usr/bin/env bash
# Coloring + ABC tech-map (sky130) of the dino CPU. Everything here runs with
# the default hier=true; what separates the two colorings is how many
# distinct colors/partitions they create:
#
#   MODE=cold  runs BOTH colorings on the same compiled design and reports
#              timing + QoR for each — the difference matters:
#                * `pass color flat`:  ONE color across the whole hierarchy,
#                  so the design fuses into ONE region (abc.flatten=auto
#                  flattens iff the coloring is flat) — best cross-module
#                  optimization, and by design NO reusable partitions;
#                * `pass color synth`: per-(module,color) regions — the
#                  partitions that make abc-cache reuse possible, at the cost
#                  of region-boundary constraints.
#              METRICs: {flat,synth}_color_ms/abc_ms/regions/gates/area/delay.
#   MODE=incr  `color synth` + abc over three passes sharing one --workdir
#              (the abc_cache lives under it):
#                pass 1: cold — every region really synthesizes;
#                pass 2: comment1 variant (nothing really changed) — regions
#                        must HIT the cache (asserted);
#                pass 3: bug1 variant (a real one-line logic edit) — only the
#                        touched region re-synthesizes (asserted: >=1 miss,
#                        untouched regions still hit).
#              Incremental needs the different colors/partitions that
#              `color synth` creates and `color flat` intentionally does not
#              (one region = nothing to reuse).
#   MODE=lec_flat | lec_synth
#              Netlist integrity: synthesize TWICE (pass 1 cold, pass 2 after
#              a comment1 touch — for lec_synth pass 2 is largely CLONED from
#              the abc cache, the case worth distrusting), then LEC the pass-2
#              netlist directly against the compiled design:
#                lhd pass liberty gensim $LIB --emit-dir lg:models
#                lhd lec --impl lg:netlist --ref lg:design --lib lg:models
#              (--lib supplies behavioral models for the mapped sky130 cells;
#              without it they are opaque Subs and the proof degrades to
#              UNKNOWN.)
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"
require_tech_dir

TOP=PipelinedDualIssueCPU.PipelinedDualIssueCPU

compile_p() {  # SRC_DIR OUT_LG
  lhd compile "$1/PipelinedDualIssueCPU.prp" --top PipelinedDualIssueCPU \
    --emit-dir "lg:$2" --workdir "cw_$2"
}

synth_pass() {  # LABEL LG_DIR COLOR_ALG WORKDIR — color in place, abc into net_LABEL
  if [ "$3" = flat ]; then
    run_timed "${1}_color" lhd pass color flat --top "$TOP" "lg:$2" --workdir "$4"
  else
    run_timed "${1}_color" lhd pass color synth --top "$TOP" \
      --set color.absorb=false "lg:$2" --workdir "$4"
  fi
  run_timed "${1}_abc" lhd pass abc --top "$TOP" "lg:$2" \
    --emit-dir "lg:net_$1" --workdir "$4" --result-json "r_$1.json"
  ABC_COUNTS=$(abc_incr_counts "r_$1.json")
  if [ "$ABC_COUNTS" != MISSING ]; then
    metric "${1}_cache_hits" "${ABC_COUNTS% *}" hits
    metric "${1}_cache_misses" "${ABC_COUNTS#* }" misses
  fi
}

case "${MODE:?}" in
cold)
  run_timed compile_setup compile_p "$DINO_P_DIR" lg_flat
  compile_p "$DINO_P_DIR" lg_synth >step_compile_synth.log 2>&1 \
    || { echo "FAIL: color-synth-side compile" >&2; exit 1; }

  for alg in flat synth; do
    synth_pass "$alg" "lg_$alg" "$alg" "W_$alg"
    read -r q_regions q_gates q_area q_delay <<EOF
$(qor_totals "W_$alg/qor.json")
EOF
    [ "$q_regions" != MISSING ] || { echo "FAIL: no QoR total in W_$alg/qor.json" >&2; exit 1; }
    metric "${alg}_regions" "$q_regions" regions
    metric "${alg}_gates" "$q_gates" gates
    metric "${alg}_area" "$q_area" um2
    metric "${alg}_max_delay" "$q_delay" ns
    [ -n "$(ls -A "net_$alg" 2>/dev/null)" ] || { echo "FAIL: empty netlist for $alg" >&2; exit 1; }
  done
  echo "PASS: color flat vs color synth QoR reported (see METRIC lines)"
  ;;
incr)
  copy_dino_sources src

  run_timed compile_pass1 compile_p src/pyrope lg_p1
  synth_pass pass1 lg_p1 synth W

  apply_variant comment1 src/pyrope
  run_timed compile_pass2 compile_p src/pyrope lg_p2
  synth_pass pass2 lg_p2 synth W
  read -r h2 m2 <<EOF
$ABC_COUNTS
EOF
  [ "${h2:-0}" -gt 0 ] || { echo "FAIL: comment-only pass got no abc cache hits ($ABC_COUNTS)" >&2; exit 1; }

  apply_variant bug1 src/pyrope
  run_timed compile_pass3 compile_p src/pyrope lg_p3
  synth_pass pass3 lg_p3 synth W
  read -r h3 m3 <<EOF
$ABC_COUNTS
EOF
  [ "${m3:-0}" -ge 1 ] || { echo "FAIL: real edit re-synthesized nothing ($ABC_COUNTS)" >&2; exit 1; }
  [ "${h3:-0}" -gt 0 ] || { echo "FAIL: real edit lost every cache hit ($ABC_COUNTS)" >&2; exit 1; }
  echo "PASS: warm hits=$h2/misses=$m2; after one-line edit hits=$h3/misses=$m3"
  ;;
lec_flat | lec_synth)
  alg=${MODE#lec_}
  copy_dino_sources src

  run_timed compile_pass1 compile_p src/pyrope lg_p1
  synth_pass pass1 lg_p1 "$alg" W

  apply_variant comment1 src/pyrope
  run_timed compile_pass2 compile_p src/pyrope lg_p2
  synth_pass pass2 lg_p2 "$alg" W
  if [ "$alg" = synth ]; then
    read -r h2 m2 <<EOF
$ABC_COUNTS
EOF
    [ "${h2:-0}" -gt 0 ] || { echo "FAIL: 2nd run got no abc cache hits ($ABC_COUNTS) — nothing cloned to validate" >&2; exit 1; }
  fi

  # Behavioral models of every Liberty cell, then netlist-vs-design LEC.
  run_timed gensim lhd pass liberty gensim \
    "$HAGENT_TECH_DIR/sky130_fd_sc_hd__tt_025C_1v80.lib" --emit-dir lg:models --workdir Wm

  # strict: an UNKNOWN is a failure here, not a shrugged-off pass — the whole
  # point is trusting (or not) the generated netlist.
  run_timed netlist_lec lhd lec --impl lg:net_pass2 --ref lg:lg_p2 \
    --lib lg:models --top "$TOP" --set formal.strict=true --workdir LW
  if grep -qia "refut" step_netlist_lec.log; then
    echo "FAIL: pass-2 $alg netlist NOT equivalent to the design" >&2
    exit 1
  fi
  echo "PASS: pass-2 $alg netlist LEC-equivalent to the design (lec ${LAST_MS} ms)"
  ;;
*)
  echo "FAIL: unknown MODE=$MODE" >&2
  exit 2
  ;;
esac
