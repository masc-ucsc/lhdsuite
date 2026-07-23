#!/usr/bin/env bash
# Formal assert/assume: the <core>/verif/$CORE_UNIT.verify.prp sidecar proves
# arithmetic facts about one real module of the design (dino: the ALU's ADDW
# sum + sign-extension; minion: the TxFMA 64-bit adder). Strict mode: an
# UNKNOWN fails the run, so PASS == all PROVEN.
#
#   MODE=cold  one proving run.
#   MODE=incr  three runs sharing one --workdir (formal_cache.json under it):
#              cold, identical warm re-run (obligation cache hits asserted),
#              then a comment1 recompile (obligations unchanged — still warm).
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

copy_core_pyrope src/pyrope

vrun() {
  lhd formal verify "src/pyrope/$CORE_UNIT.prp" "$CORE_VERIF_DIR/$CORE_UNIT.verify.prp" \
    --top "$CORE_UNIT" --set formal.bound=2 --set formal.strict=true --workdir FW
}

check_proven() {  # LOG — both sidecar asserts must be PROVEN
  n=$(grep -ca "PROVEN" "$1" || true)
  [ "$n" -ge 2 ] || { echo "FAIL: expected >=2 PROVEN obligations, got $n ($1)" >&2; exit 1; }
}

case "${MODE:?}" in
cold)
  run_timed verify_cold vrun
  check_proven step_verify_cold.log
  echo "PASS: $CORE_UNIT assert/assume all PROVEN (${LAST_MS} ms)"
  ;;
incr)
  run_timed verify_cold vrun
  check_proven step_verify_cold.log

  run_timed verify_warm vrun
  check_proven step_verify_warm.log
  grep -qaE "formal\[cache\]: [1-9][0-9]* obligation hit" step_verify_warm.log \
    || { echo "FAIL: warm identical re-run reported no obligation-cache hits" >&2; exit 1; }

  apply_variant comment1 src/pyrope
  run_timed verify_touch vrun
  check_proven step_verify_touch.log
  echo "PASS: cold/warm/comment-touch verify runs all PROVEN"
  ;;
*)
  echo "FAIL: unknown MODE=$MODE" >&2
  exit 2
  ;;
esac
