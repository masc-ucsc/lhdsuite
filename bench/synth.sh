#!/usr/bin/env bash
# Coloring + ABC tech-map (sky130) + OpenTimer STA of the design under test, at
# $CORE_TOP (the whole design). Everything here runs with the default
# hier=true; what separates the two colorings is how many distinct
# colors/partitions they create:
#
#   * `color synth`: per-(module,color) regions — the partitions that make
#     abc-cache reuse possible, at the cost of region-boundary constraints.
#     This is the ONE-SHOT flow, `lhd synth` (compile -> color synth -> abc
#     -> opentimer over one in-memory design, one --workdir, one Liberty):
#
#       lhd synth <core>/pyrope/<top>.prp --top <top> --workdir W \
#           --emit-dir lg:net_<label> --result-json r_<label>.json --stats
#
#     The per-step numbers (compile / color / abc / sta) come from lhd's own
#     `phases` account of the run, and the reuse counters from the envelope's
#     `incremental.{compile,abc}` member — the one-shot reports exactly what
#     the manual steps did, under the same metric names.
#   * `color flat`: ONE color across the whole hierarchy, so the design fuses
#     into ONE region (abc.flatten=auto flattens iff the coloring is flat) —
#     best cross-module optimization, and by design NO reusable partitions.
#     Does not scale: a core big enough that one region blows the abc memory
#     budget omits `flat` from its color_algs. `lhd synth` always colors with
#     `synth`, so flat stays the MANUAL flow (compile, then the three passes
#     one at a time):
#
#       lhd compile <top>.prp --top <top> --emit-dir lg:L --workdir cw
#       lhd pass color flat --top <top>.<top> lg:L --workdir W
#       lhd pass abc --top <top>.<top> lg:L --emit-dir lg:net --workdir W
#       lhd pass opentimer --top <top>.<top> lg:net $LIB --workdir OT
#
#   MODE=cold  runs each of this core's colorings ($CORE_COLOR_ALGS) and
#              reports timing + QoR for each — METRICs:
#              <alg>_color_ms/abc_ms/sta_ms/regions/gates/area/delay/sta_delay.
#   MODE=incr  `lhd synth` over three passes sharing ONE --workdir (both the
#              compile cache and the abc_cache live under it):
#                pass 1: cold — every region really synthesizes;
#                pass 2: comment1 variant (nothing really changed) — regions
#                        must HIT the cache (asserted), and the compile tier
#                        reuses the unchanged units;
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
#              UNKNOWN. For lec_synth the design side is the one-shot's own
#              compiled library, W/synth/lg.)
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"
require_tech_dir
SYNTH_START_MS=$(now_ms)
SYNTH_DOWNSTREAM_FAILURES=0
printf '{"pdk_version":"%s","target":"%s"}\n' \
  "$PDK_VERSION" "${TEST_TARGET:-$CORE}" >"$OUT_DIR/run_metadata.json"

TOP=$CORE_TOP.$CORE_TOP
LIB="$HAGENT_TECH_DIR/sky130_fd_sc_hd__tt_025C_1v80.lib"

# Experiment-only synthesis knobs. Bazel tests can set BENCH_ABC_*=...,
# BENCH_COLOR_SYNTH_ALG=pipe|synth, or BENCH_COLOR_REDUCE=1 so one candidate is
# applied uniformly across targets without editing LiveHD defaults between
# measurements. The reduction step is timed separately as <alg>_reduce_ms (the
# manual flow only: `lhd synth` has no reduce step, by design).
ABC_ARGS=()
[ -z "${BENCH_ABC_ADDER:-}" ] || ABC_ARGS+=(--set "abc.adder=$BENCH_ABC_ADDER")
[ -z "${BENCH_ABC_BLOCK_SIZE:-}" ] || ABC_ARGS+=(--set "abc.block_size=$BENCH_ABC_BLOCK_SIZE")
[ -z "${BENCH_ABC_DELAY:-}" ] || ABC_ARGS+=(--set "abc.delay=$BENCH_ABC_DELAY")
[ -z "${BENCH_ABC_LOAD:-}" ] || ABC_ARGS+=(--set "abc.load=$BENCH_ABC_LOAD")
[ -z "${BENCH_ABC_FLOW:-}" ] || ABC_ARGS+=(--set "abc.flow=$BENCH_ABC_FLOW")
[ -z "${BENCH_ABC_CACHE:-}" ] || ABC_ARGS+=(--set "lhd.incremental=$BENCH_ABC_CACHE")
# The suite's shared soft resource envelope. pass.abc refuses a projected
# oversize region early; GNU time checks the actual process-tree peak after the
# run. This is intentionally uniform across cores.
ABC_ARGS+=(--set "abc.memory_budget_mb=${BENCH_ABC_MEMORY_BUDGET_MB:-16384}")
ABC_ARGS+=(--set "abc.time_budget_ms=${BENCH_ABC_TIME_BUDGET_MS:-900000}")
ABC_ARGS+=(--set "abc.verbose=${BENCH_ABC_VERBOSE:-true}")
COLOR_ARGS=()
[ -z "${BENCH_COLOR_SYNTH_ALG:-}" ] || COLOR_ARGS+=(--set "color.synth_alg=$BENCH_COLOR_SYNTH_ALG")
[ -z "${BENCH_COLOR_MAX_GE:-}" ] || COLOR_ARGS+=(--set "color.max_ge=$BENCH_COLOR_MAX_GE")

stubs=()
if [ -n "$CORE_P_STUB_DIR" ]; then
  stubs=("$CORE_P_STUB_DIR"/*.prp)
fi

compile_p() {  # SRC_DIR OUT_LG
  lhd compile "$1/$CORE_TOP.prp" ${stubs[@]+"${stubs[@]}"} --top "$CORE_TOP" \
    --emit-dir "lg:$2" --workdir "cw_$2"
}

# report_abc LABEL RESULT_JSON ABC_LOG — the abc reuse counters and the
# store-failed gate, shared by both flows. Sets ic_hits/ic_misses/ic_hit_ms/
# ic_miss_ms (empty when the cache did not run).
report_abc() {
  ic_hits="" ic_misses="" ic_hit_ms="" ic_miss_ms=""
  ABC_COUNTS=$(abc_incr_counts "$2")
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
      grep -h 'cache-store' "$3" | head -3 >&2 || true
      exit 1
    }
  fi
}

# report_sta LABEL TIMING_JSON — the whole-design max_delay gate + metric.
report_sta() {
  cp "$2" "$OUT_DIR/${1}_timing.json"
  STA_DELAY=$(sta_max_delay "$2")
  [ "$STA_DELAY" != MISSING ] || {
    step_failed "${1}_sta" "$1: pass.opentimer did not report a whole-design max_delay"
    exit 1
  }
  metric "${1}_sta_delay" "$STA_DELAY" ns
}

# synth_oneshot LABEL SRC_DIR WORKDIR — `lhd synth`: compile + color synth +
# abc + opentimer in ONE process over ONE in-memory design. The mapped netlist
# is relocated to net_LABEL (lec wants the pass-2 one by name); the compiled
# design stays at WORKDIR/synth/lg (the compile cache's artifact), the QoR and
# timing reports at WORKDIR/synth/{qor,timing}.json.
#
# The per-step metrics keep the manual flow's names — compile_LABEL_ms,
# LABEL_color_ms, LABEL_abc_ms, LABEL_sta_ms — but are read from lhd's own
# `phases` (compile = every phase that is not one of the three synth passes:
# the front end, the recipe, run_id, the library saves). LABEL_synth_ms is the
# one-shot's wall clock, i.e. what an edit costs end to end.
synth_oneshot() {
  local label=$1 src=$2 wd=$3 incremental=${4:-true}
  local incr_args=()
  [ "$incremental" != false ] || incr_args=(--set lhd.incremental=false)
  local rc=0
  lhd_timed_rss "${label}_synth" synth "$src/$CORE_TOP.prp" ${stubs[@]+"${stubs[@]}"} --top "$CORE_TOP" \
    --workdir "$wd" --emit-dir "lg:net_$label" --result-json "r_$label.json" --stats \
    ${COLOR_ARGS[@]+"${COLOR_ARGS[@]}"} ${ABC_ARGS[@]+"${ABC_ARGS[@]}"} \
    ${incr_args[@]+"${incr_args[@]}"} || rc=$?
  # A failed STA still completed compile/color/ABC. Keep those phase timers in
  # the ledger so a red full row is diagnosable rather than one opaque
  # time-to-failure number.
  if [ -f "r_$label.json" ]; then
    read -r ph_compile ph_color ph_abc ph_sta <<EOF
$(synth_phase_ms "r_$label.json")
EOF
    metric "compile_${label}_ms" "$ph_compile" ms
    metric "${label}_color_ms" "$ph_color" ms
    metric "${label}_abc_ms" "$ph_abc" ms
    metric "${label}_sta_ms" "$ph_sta" ms
    cp "r_$label.json" "$OUT_DIR/${label}_result.json"
  fi
  cp "step_${label}_synth.log" "$OUT_DIR/${label}_synth.log"
  if [ -f "$wd/synth/qor.json" ]; then
    cp "$wd/synth/qor.json" "$OUT_DIR/${label}_qor.json"
    QOR_JSON="$wd/synth/qor.json"
    report_qor "$label" "$QOR_JSON"
  fi
  if [ "$rc" != 0 ]; then
    # pass.opentimer is downstream of a complete mapped netlist. Preserve its
    # red result, but do not let it erase the cold/warm ABC experiment: a
    # non-zero STA phase plus complete QoR proves compile/color/ABC finished.
    # Resource refusals and ABC failures have no such STA phase and still stop
    # immediately because continuing would manufacture invalid cache evidence.
    if [ -n "${ph_sta:-}" ] && [ "${ph_sta:-0}" -gt 0 ] && [ -f "$wd/synth/qor.json" ]; then
      # A failed one-shot envelope only retains compile-tier incremental
      # counters; the already-written QoR file is the authoritative ABC tier.
      report_abc "$label" "$wd/synth/qor.json" "step_${label}_synth.log"
      SYNTH_DOWNSTREAM_FAILURES=$((SYNTH_DOWNSTREAM_FAILURES + 1))
      return 0
    fi
    return "$rc"
  fi
  read -r ph_compile ph_color ph_abc ph_sta <<EOF
$(synth_phase_ms "r_$label.json")
EOF
  # Successful runs emitted these phase metrics above too; do not duplicate
  # them in metrics.jsonl.
  # Preserve the reports even when a later gate fails (netlist LEC, budget):
  # the run remains measurable without weakening the downstream gate.
  report_sta "$label" "$wd/synth/timing.json"
  report_abc "$label" "r_$label.json" "step_${label}_synth.log"
}

# synth_pass LABEL LG_DIR COLOR_ALG WORKDIR — the MANUAL flow: color in place,
# abc into net_LABEL, opentimer on that netlist. What `lhd synth` fuses, one
# pass at a time; the only way to run a coloring other than `synth`.
synth_pass() {
  if [ -n "${BENCH_COLOR_REDUCE:-}" ]; then
    run_timed "${1}_reduce" lhd pass color reduce --top "$TOP" "lg:$2" --workdir "$4"
  fi
  if [ "$3" = flat ]; then
    run_timed "${1}_color" lhd pass color flat --top "$TOP" "lg:$2" --workdir "$4"
  else
    run_timed "${1}_color" lhd pass color synth --top "$TOP" "lg:$2" --workdir "$4" ${COLOR_ARGS[@]+"${COLOR_ARGS[@]}"}
  fi
  lhd_timed_rss "${1}_abc" pass abc --top "$TOP" "lg:$2" \
    --emit-dir "lg:net_$1" --workdir "$4" --result-json "r_$1.json" ${ABC_ARGS[@]+"${ABC_ARGS[@]}"}
  cp "$4/qor.json" "$OUT_DIR/${1}_qor.json"
  cp "step_${1}_abc.log" "$OUT_DIR/${1}_abc.log"
  run_timed "${1}_sta" lhd pass opentimer --top "$TOP" "lg:net_$1" "$LIB" --workdir "OT_$1"
  report_sta "$1" "OT_$1/timing.json"
  report_abc "$1" "r_$1.json" "step_${1}_abc.log"
  QOR_JSON="$4/qor.json"
}

report_qor() {  # ALG QOR_JSON — the whole-design QoR totals
  read -r q_regions q_gates q_area q_delay q_div_blackbox <<EOF
$(qor_totals "$2")
EOF
  [ "$q_regions" != MISSING ] || { echo "FAIL: no QoR total in $2" >&2; exit 1; }
  metric "${1}_regions" "$q_regions" regions
  metric "${1}_gates" "$q_gates" gates
  metric "${1}_area" "$q_area" um2
  metric "${1}_max_delay" "$q_delay" ns
  metric "${1}_div_blackbox" "$q_div_blackbox" cones
  q_max_region_ms=$(qor_max_region_ms "$2")
  [ "$q_max_region_ms" = MISSING ] || {
    metric "${1}_max_region_ms" "$q_max_region_ms" ms
    [ "$q_max_region_ms" -le "${BENCH_ABC_TIME_BUDGET_MS:-900000}" ] || {
      step_failed "${1}_abc" \
        "$1: one ABC color took ${q_max_region_ms}ms (soft limit ${BENCH_ABC_TIME_BUDGET_MS:-900000}ms); reduce color.max_ge"
      exit 1
    }
  }
  q_abc_peak_rss_kb=$(qor_abc_peak_rss_kb "$2")
  [ "$q_abc_peak_rss_kb" = MISSING ] || \
    metric "${1}_abc_peak_rss_kb" "$q_abc_peak_rss_kb" KiB
  while read -r bucket count ge_sum ms_sum; do
    metric "${1}_color_${bucket}_count" "$count" colors
    metric "${1}_color_${bucket}_ge_sum" "$ge_sum" GE
    metric "${1}_color_${bucket}_ms_sum" "$ms_sum" ms
  done <<EOF
$(qor_color_hist "$2")
EOF
}

case "${MODE:?}" in
cold)
  for alg in $CORE_COLOR_ALGS; do
    if [ "$alg" = synth ]; then
      # The one-shot, straight from the checked-in sources (read-only; the
      # compiled design lands in W_synth/synth/lg).
      synth_oneshot synth "$CORE_P_DIR" W_synth
    else
      # The manual flow colors IN PLACE, so each alg gets its own compiled copy.
      run_timed "compile_$alg" compile_p "$CORE_P_DIR" "lg_$alg"
      synth_pass "$alg" "lg_$alg" "$alg" "W_$alg"
      report_qor "$alg" "$QOR_JSON"
    fi
    [ -n "$(ls -A "net_$alg" 2>/dev/null)" ] || { echo "FAIL: empty netlist for $alg" >&2; exit 1; }
  done
  metric synthesis_elapsed_ms "$(( $(now_ms) - SYNTH_START_MS ))" ms
  echo "PASS: QoR reported for coloring(s):$(printf ' color %s' $CORE_COLOR_ALGS) (see METRIC lines)"
  ;;
incr)
  copy_core_pyrope src/pyrope

  synth_oneshot full src/pyrope W_full false
  synth_oneshot pass1 src/pyrope W
  cold_miss_ms=$ic_miss_ms

  if [ -n "$CORE_SYNTH_ONLY" ]; then
    apply_synth_only_variant comment1 src/pyrope
  else
    apply_variant comment1 src/pyrope
  fi
  synth_oneshot pass2 src/pyrope W
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
  # The compile tier shares the workdir now, so the comment-only pass must
  # also have reused the unchanged units (a miss here means a source unit was
  # reparsed; the touched file itself is the one honest miss).
  c2_misses=$(compile_incr_field r_pass2.json misses)
  metric pass2_compile_misses "${c2_misses:-0}" misses

  if [ -n "$CORE_SYNTH_ONLY" ]; then
    apply_synth_only_variant bug1 src/pyrope
  else
    apply_variant bug1 src/pyrope
  fi
  synth_oneshot pass3 src/pyrope W
  h3=$ic_hits m3=$ic_misses
  [ "${m3:-0}" -ge 1 ] || { echo "FAIL: real edit re-synthesized nothing ($ABC_COUNTS)" >&2; exit 1; }
  [ "${h3:-0}" -gt 0 ] || { echo "FAIL: real edit lost every cache hit ($ABC_COUNTS)" >&2; exit 1; }
  metric synthesis_elapsed_ms "$(( $(now_ms) - SYNTH_START_MS ))" ms
  echo "PASS: warm hits=$h2/misses=$m2 (${warm_miss_ms}ms re-mapped of ${cold_miss_ms}ms cold);" \
    "after one-line edit hits=$h3/misses=$m3"
  [ "$SYNTH_DOWNSTREAM_FAILURES" = 0 ] || {
    echo "FAIL: $SYNTH_DOWNSTREAM_FAILURES synthesis invocation(s) completed ABC but failed downstream STA; cold/warm metrics were retained" >&2
    exit 1
  }
  ;;
lec_flat | lec_synth)
  alg=${MODE#lec_}
  copy_core_pyrope src/pyrope

  if [ "$alg" = synth ]; then
    synth_oneshot pass1 src/pyrope W
    apply_variant comment1 src/pyrope
    synth_oneshot pass2 src/pyrope W
    [ "${ic_hits:-0}" -gt 0 ] || { echo "FAIL: 2nd run got no abc cache hits ($ABC_COUNTS) — nothing cloned to validate" >&2; exit 1; }
    design=W/synth/lg  # the one-shot's compiled design, as of pass 2
  else
    run_timed compile_pass1 compile_p src/pyrope lg_p1
    synth_pass pass1 lg_p1 "$alg" W
    apply_variant comment1 src/pyrope
    run_timed compile_pass2 compile_p src/pyrope lg_p2
    synth_pass pass2 lg_p2 "$alg" W
    design=lg_p2
  fi

  # Behavioral models of every Liberty cell, then netlist-vs-design LEC.
  run_timed gensim lhd pass liberty gensim "$LIB" --emit-dir lg:models --workdir Wm

  # lhd is strict by default, so an UNKNOWN is a failure here, not a
  # shrugged-off pass — the whole point is trusting (or not) the generated
  # netlist. CORE_LEC_TRUST (defs.bzl) assumes the design's latch-holding DEFS
  # equal, so the ref (design) side is not refused for holding state the
  # encoder cannot normalize across a module boundary — the same escape hatch
  # as bench/lec.sh (fixme issue 1). Names absent from the netlist are silently
  # ignored.
  if [ -n "$CORE_LEC_TRUST" ]; then
    run_timed netlist_lec lhd lec --impl lg:net_pass2 --ref "lg:$design" \
      --lib lg:models --top "$TOP" \
      --set "formal.lec.trust=$CORE_LEC_TRUST" --workdir LW
  else
    run_timed netlist_lec lhd lec --impl lg:net_pass2 --ref "lg:$design" \
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
