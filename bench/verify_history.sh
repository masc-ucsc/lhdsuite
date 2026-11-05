#!/usr/bin/env bash
# Formal verification along a design's REAL commit history: the core's own
# assertions, on every version, three ways.
#
#   cold  every version from scratch, a fresh --workdir each (formal.reuse=none):
#         the reference answer
#   hash  baseline, one --workdir over the history: a verdict is reused when the
#         assertion's cone hash is unchanged (formal.reuse=hash)
#   lpr   Layered Proof Reuse, one --workdir: same cone, then an equivalent cone
#         (ABC dsec), then the old counterexample replayed, then the old PDR
#         invariant re-checked (formal.reuse=all)
#
# PASS == no assertion is proven by one method and refuted by another on the
# same version. Proven-full vs proven-bounded is not a mismatch: PDR stops at a
# wall-clock limit, so whether it finishes depends on load (counted as
# history_full_bounded_flips). The speed-ups are METRICs, not gates.
#
# The versions come from <core>/tests/history/history.jsonl.gz (CORE_HISTORY); see
# that directory's make_history.py. HISTORY_VERSIONS picks a slice: the default
# is the first 10 versions (minutes); `--test_env=HISTORY_VERSIONS=all` runs the
# whole chain (hours, one version at a time).
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

: "${CORE_HISTORY:?this core has no history; the target should not have been generated}"
: "${CORE_HISTORY_TOP:?}" "${CORE_HISTORY_SETS=}"
: "${HISTORY_VERSIONS:=0-9}"
HIST=$(rloc "$CORE_HISTORY")
PY=$RF/_main/bench/history.py

python3 "$PY" expand "$HIST" versions "$HISTORY_VERSIONS" >version_list.txt
[ -s version_list.txt ] || { echo "FAIL: no versions in $HISTORY_VERSIONS" >&2; exit 1; }
: >times.jsonl

hrun() {  # FILE WORKDIR REUSE
  # shellcheck disable=SC2086  # CORE_HISTORY_SETS is a token LIST, split on purpose
  lhd formal verify "$1" --top "$CORE_HISTORY_TOP" --workdir "$2" --diag-fmt pretty \
    --set formal.reuse="$3" --set formal.pdr=true --set formal.abc=true \
    --set formal.simfail_run=false --set compile.formal.on_refute=warn $CORE_HISTORY_SETS
}

for method in cold hash lpr; do
  reuse=$method
  [ "$method" != cold ] || reuse=none
  [ "$method" != lpr ] || reuse=all
  rm -rf "wd_$method"
  while read -r i; do
    v=$(printf 'v%03d' "$i")
    wd=wd_$method
    [ "$method" != cold ] || { wd=wd_cold_$v; rm -rf "$wd"; }
    rm -f "$wd/formal_report.json"  # a front-end failure must not read the last version's report
    # Timed directly: run_timed fails the step on exit 10 (a refuted assertion
    # is an answer here), and run_timed_deadline polls in 5 s steps, coarser
    # than a reused version takes. The bazel timeout is the backstop.
    CURRENT_STEP=history_${method}_$v
    t0=$(now_ms)
    LAST_RC=0
    hrun "versions/$v.sv" "$wd" "$reuse" >"step_$CURRENT_STEP.log" 2>&1 || LAST_RC=$?
    LAST_MS=$(($(now_ms) - t0))
    metric "${CURRENT_STEP}_ms" "$LAST_MS" ms
    props=null
    # 0 = all proven, 10 = something refuted: both carry a report. Anything else
    # (a front-end failure) is a version that did not load, the same for all methods.
    if [ "$LAST_RC" = 0 ] || [ "$LAST_RC" = 10 ]; then
      [ ! -f "$wd/formal_report.json" ] || props=$(python3 "$PY" verdicts "$wd/formal_report.json")
    fi
    printf '{"method":"%s","idx":%d,"rc":%s,"s":%s,"props":%s}\n' \
      "$method" "$i" "$LAST_RC" "$(python3 -c "print($LAST_MS/1000)")" "$props" >>times.jsonl
    [ "$method" != cold ] || rm -rf "$wd"
  done <version_list.txt
done
cp times.jsonl "$OUT_DIR/history_times.jsonl" 2>/dev/null || true

rc=0
python3 "$PY" judge . hash lpr >judge.txt || rc=$?
grep -v '^METRICLINE ' judge.txt || true
while read -r _ name value unit; do metric "$name" "$value" "$unit"; done < <(grep '^METRICLINE ' judge.txt)
if [ "$rc" != 0 ]; then
  echo "FAIL: a reuse method changed a proven/refuted verdict (WRONG lines above)" >&2
  exit 1
fi
echo "PASS: $(wc -l <version_list.txt) $CORE versions, hash and lpr verdicts match cold"
