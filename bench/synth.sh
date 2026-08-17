#!/usr/bin/env bash
# Coloring + ABC tech-map (sky130) of the design under test, at $CORE_TOP (the
# whole design). Everything here runs with
# the default hier=true; what separates the two colorings is how many
# distinct colors/partitions they create:
#
#   MODE=cold  runs each of this core's colorings ($CORE_COLOR_ALGS) on its
#              own compiled copy of the design and reports timing + QoR for
#              each — the difference matters:
#                * `pass color flat`:  ONE color across the whole hierarchy,
#                  so the design fuses into ONE region (abc.flatten=auto
#                  flattens iff the coloring is flat) — best cross-module
#                  optimization, and by design NO reusable partitions. Does
#                  not scale: a core big enough that one region blows the abc
#                  memory budget omits `flat` from its color_algs;
#                * `pass color synth`: per-(module,color) regions — the
#                  partitions that make abc-cache reuse possible, at the cost
#                  of region-boundary constraints.
#              METRICs: <alg>_color_ms/abc_ms/regions/gates/area/delay.
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
#              (lec_<alg> exists only for cores whose color_algs include <alg>)
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
SYNTH_START_MS=$(now_ms)
printf '{"pdk_version":"%s","target":"%s"}\n' \
  "$PDK_VERSION" "${TEST_TARGET:-$CORE}" >"$OUT_DIR/run_metadata.json"

TOP=$CORE_TOP.$CORE_TOP

compile_p() {  # SRC_DIR OUT_LG
  local stubs=()
  if [ -n "$CORE_P_STUB_DIR" ]; then
    stubs=("$CORE_P_STUB_DIR"/*.prp)
  fi
  lhd compile "$1/$CORE_TOP.prp" "${stubs[@]}" --top "$CORE_TOP" \
    --emit-dir "lg:$2" --workdir "cw_$2"
}

synth_pass() {  # LABEL LG_DIR COLOR_ALG WORKDIR — color in place, abc into net_LABEL
  if [ "$3" = flat ]; then
    run_timed "${1}_color" lhd pass color flat --top "$TOP" "lg:$2" --workdir "$4"
  else
    run_timed "${1}_color" lhd pass color synth --top "$TOP" "lg:$2" --workdir "$4"
  fi
  run_timed "${1}_abc" lhd pass abc --top "$TOP" "lg:$2" \
    --emit-dir "lg:net_$1" --workdir "$4" --result-json "r_$1.json"
  run_timed "${1}_sta" lhd pass opentimer --top "$TOP" "lg:net_$1" \
    "$HAGENT_TECH_DIR/sky130_fd_sc_hd__tt_025C_1v80.lib" --workdir "OT_$1"
  STA_DELAY=$(sta_max_delay "OT_$1/timing.json")
  [ "$STA_DELAY" != MISSING ] || {
    step_failed "${1}_sta" "$1: pass.opentimer did not report a whole-design max_delay"
    exit 1
  }
  metric "${1}_sta_delay" "$STA_DELAY" ns
  ABC_COUNTS=$(abc_incr_counts "r_$1.json")
  if [ "$ABC_COUNTS" != MISSING ]; then
    read -r ic_hits ic_misses ic_hit_ms ic_miss_ms ic_failed <<EOF
$ABC_COUNTS
EOF
    metric "${1}_cache_hits" "$ic_hits" hits
    metric "${1}_cache_misses" "$ic_misses" misses
    # Where the abc time actually went. A high hit RATE over cheap regions is
    # not a speedup — only miss_ms shrinking is.
    metric "${1}_cache_hit_ms" "$ic_hit_ms" ms
    metric "${1}_cache_miss_ms" "$ic_miss_ms" ms
    # A region the cache could not snapshot pays for ABC on every future run:
    # a permanent tax, and a livehd bug rather than a property of the design.
    [ "${ic_failed:-0}" = 0 ] || {
      step_failed "${1}_abc" \
        "$1: $ic_failed region(s) could not be stored in the abc cache — they re-synthesize forever"
      # The offending regions are named by `cache-store` lines; surface a couple
      # so the first one is diagnosable without opening the saved step log.
      # `|| true`, and AFTER step_failed: `ic_failed` comes from the result JSON
      # while these lines come from the log, so a no-match grep is possible —
      # and under `set -e` + `pipefail` it would abort the script right here,
      # swallowing the whole diagnosis.
      grep -h 'cache-store' "step_${1}_abc.log" | head -3 >&2 || true
      exit 1
    }
  fi
}

case "${MODE:?}" in
cold)
  # Coloring runs in place, so each alg gets its own compiled copy. The first
  # compile is the timed one; the rest are identical work.
  first=1
  for alg in $CORE_COLOR_ALGS; do
    if [ "$first" = 1 ]; then
      run_timed compile_setup compile_p "$CORE_P_DIR" "lg_$alg"
      first=0
    else
      compile_p "$CORE_P_DIR" "lg_$alg" >"step_compile_$alg.log" 2>&1 \
        || { echo "FAIL: color-$alg-side compile" >&2; exit 1; }
    fi

    synth_pass "$alg" "lg_$alg" "$alg" "W_$alg"
    read -r q_regions q_gates q_area q_delay q_div_blackbox <<EOF
$(qor_totals "W_$alg/qor.json")
EOF
    [ "$q_regions" != MISSING ] || { echo "FAIL: no QoR total in W_$alg/qor.json" >&2; exit 1; }
    metric "${alg}_regions" "$q_regions" regions
    metric "${alg}_gates" "$q_gates" gates
    metric "${alg}_area" "$q_area" um2
    metric "${alg}_max_delay" "$q_delay" ns
    metric "${alg}_div_blackbox" "$q_div_blackbox" cones
    [ -n "$(ls -A "net_$alg" 2>/dev/null)" ] || { echo "FAIL: empty netlist for $alg" >&2; exit 1; }
  done
  metric synthesis_elapsed_ms "$(( $(now_ms) - SYNTH_START_MS ))" ms
  echo "PASS: QoR reported for coloring(s):$(printf ' color %s' $CORE_COLOR_ALGS) (see METRIC lines)"
  ;;
incr)
  copy_core_pyrope src/pyrope

  run_timed compile_pass1 compile_p src/pyrope lg_p1
  synth_pass pass1 lg_p1 synth W

  cold_miss_ms=$ic_miss_ms

  if [ -n "$CORE_SYNTH_ONLY" ]; then
    apply_synth_only_variant comment1 src/pyrope
  else
    apply_variant comment1 src/pyrope
  fi
  run_timed compile_pass2 compile_p src/pyrope lg_p2
  synth_pass pass2 lg_p2 synth W
  h2=$ic_hits m2=$ic_misses warm_miss_ms=$ic_miss_ms
  [ "${h2:-0}" -gt 0 ] || { echo "FAIL: comment-only pass got no abc cache hits ($ABC_COUNTS)" >&2; exit 1; }
  # The gate that matters. A hit COUNT proves nothing about wall time: minion
  # once hit 199 of 264 regions and saved 2%, because everything expensive was
  # in the 65 that missed. What a comment-only edit must not re-map is time.
  metric abc_warm_speedup "$(python3 -c "print(round($cold_miss_ms/max($warm_miss_ms,1),2))")" x
  [ "$warm_miss_ms" -le $((cold_miss_ms / 2)) ] || {
    echo "FAIL: comment-only pass re-synthesized ${warm_miss_ms}ms of a ${cold_miss_ms}ms cold map" >&2
    echo "      ($h2 hits / $m2 misses — check which regions missed and why)" >&2
    exit 1
  }

  if [ -n "$CORE_SYNTH_ONLY" ]; then
    apply_synth_only_variant bug1 src/pyrope
  else
    apply_variant bug1 src/pyrope
  fi
  run_timed compile_pass3 compile_p src/pyrope lg_p3
  synth_pass pass3 lg_p3 synth W
  h3=$ic_hits m3=$ic_misses
  [ "${m3:-0}" -ge 1 ] || { echo "FAIL: real edit re-synthesized nothing ($ABC_COUNTS)" >&2; exit 1; }
  [ "${h3:-0}" -gt 0 ] || { echo "FAIL: real edit lost every cache hit ($ABC_COUNTS)" >&2; exit 1; }
  metric synthesis_elapsed_ms "$(( $(now_ms) - SYNTH_START_MS ))" ms
  echo "PASS: warm hits=$h2/misses=$m2 (${warm_miss_ms}ms re-mapped of ${cold_miss_ms}ms cold);" \
    "after one-line edit hits=$h3/misses=$m3"
  ;;
lec_flat | lec_synth)
  alg=${MODE#lec_}
  copy_core_pyrope src/pyrope

  run_timed compile_pass1 compile_p src/pyrope lg_p1
  synth_pass pass1 lg_p1 "$alg" W

  apply_variant comment1 src/pyrope
  run_timed compile_pass2 compile_p src/pyrope lg_p2
  synth_pass pass2 lg_p2 "$alg" W
  if [ "$alg" = synth ]; then
    [ "${ic_hits:-0}" -gt 0 ] || { echo "FAIL: 2nd run got no abc cache hits ($ABC_COUNTS) — nothing cloned to validate" >&2; exit 1; }
  fi

  # Behavioral models of every Liberty cell, then netlist-vs-design LEC.
  run_timed gensim lhd pass liberty gensim \
    "$HAGENT_TECH_DIR/sky130_fd_sc_hd__tt_025C_1v80.lib" --emit-dir lg:models --workdir Wm

  # lhd is strict by default, so an UNKNOWN is a failure here, not a
  # shrugged-off pass — the whole point is trusting (or not) the generated
  # netlist. CORE_LEC_TRUST (defs.bzl) assumes the design's latch-holding DEFS
  # equal, so the ref (design) side is not refused for holding state the
  # encoder cannot normalize across a module boundary — the same escape hatch
  # as bench/lec.sh (fixme issue 1). Names absent from the netlist are silently
  # ignored.
  if [ -n "$CORE_LEC_TRUST" ]; then
    run_timed netlist_lec lhd lec --impl lg:net_pass2 --ref lg:lg_p2 \
      --lib lg:models --top "$TOP" \
      --set "formal.lec.trust=$CORE_LEC_TRUST" --workdir LW
  else
    run_timed netlist_lec lhd lec --impl lg:net_pass2 --ref lg:lg_p2 \
      --lib lg:models --top "$TOP" --workdir LW
  fi
  if grep -qia "refut" step_netlist_lec.log; then
    echo "FAIL: pass-2 $alg netlist NOT equivalent to the design" >&2
    exit 1
  fi
  metric synthesis_elapsed_ms "$(( $(now_ms) - SYNTH_START_MS ))" ms
  echo "PASS: pass-2 $alg netlist LEC-equivalent to the design (lec ${LAST_MS} ms)"
  ;;
*)
  echo "FAIL: unknown MODE=$MODE" >&2
  exit 2
  ;;
esac
