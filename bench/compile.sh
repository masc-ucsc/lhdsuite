#!/usr/bin/env bash
# Lgraph-creation throughput: source -> compiled lg: library.
#   MODE=verilog  slang front-end via the filelist (-F, -DSYNTHESIS, plus the
#                 core's $CORE_V_FLAGS). LoC/words count the WHOLE filelist,
#                 since slang parses every file in it.
#   MODE=pyrope   top .prp; sibling import discovery pulls the whole tree
#   MODE=pyrope_parallel
#                 per-file separate compilation driven by a REAL BUILD SYSTEM.
#                 `lhd scan` (lexer-only import discovery) reports every file's
#                 imports; bench/gen_build.py turns that into a Makefile with
#                 one rule per file, prerequisites = that file's DIRECT imports,
#                 pruned to the cone of --top. `make -j` then derives the
#                 parallel schedule itself — the bench does not hand-roll
#                 topological waves, and an edit rebuilds only the affected
#                 subtree. The same generator also emits a BUILD.bazel to show
#                 what gazelle-style generation off `lhd scan` looks like; it is
#                 syntax-checked and archived, never executed (a nested bazel
#                 inside a bazel test would need repo fetching and would put a
#                 server start + analysis phase inside the measured window).
#                 Dependencies ride in PRE-LOWERED as positional `lg:DIR`
#                 inputs, falling back to `ln:DIR` for type/constant-only
#                 packages that emit no lgraph. That choice is the whole
#                 ballgame: an `ln:` input is re-elaborated from the AST on
#                 every load, so passing a `comb` unit that way costs the same
#                 as recompiling it from source. `--emit-dir lg:` is
#                 transitively closed, so lg_<top> is already the COMPLETE
#                 design library — same shape as the monolithic compile, with
#                 no final link step.
# Reports LoC/s and words/s over the language's sources.
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

P_STUBS=()
if [ -n "$CORE_P_STUB_DIR" ]; then
  P_STUBS=("$CORE_P_STUB_DIR"/*.prp)
fi

case "${MODE:?}" in
verilog)
  n_loc=$(loc $(core_v_sources))
  n_words=$(words $(core_v_sources))
  run_timed compile_verilog lhd compile verilog --top "$CORE_TOP" \
    --emit-dir lg:out_lg --workdir w -- -F "$CORE_V_DIR/filelist.f" -DSYNTHESIS $CORE_V_FLAGS
  ;;
pyrope)
  run_timed compile_pyrope lhd compile "$CORE_P_DIR/$CORE_TOP.prp" \
    ${P_STUBS[@]+"${P_STUBS[@]}"} \
    --top "$CORE_TOP" --emit-dir lg:out_lg --workdir w --result-json compile_pyrope.json
  read -r n_loc n_words <<EOF
$(compile_input_stats compile_pyrope.json "$CORE_P_DIR" "$CORE_P_STUB_DIR")
EOF
  [[ "$n_loc" =~ ^[0-9]+$ && "$n_words" =~ ^[0-9]+$ ]] || {
    echo "FAIL: could not count the compiled Pyrope cone" >&2
    exit 1
  }
  ;;
incr)
  # The four-pass FRONT-END rebuild over one --workdir and one lg: output:
  # full, cold, comment-only touch, one real edit. There is no front-end cache today,
  # so on day one this scenario's job is to put honest cold numbers in the
  # ledger and make a future lever attributable — which is why it gates on WALL
  # TIME and never on a hit count. A hit count would go green the moment
  # something starts hitting, whether or not any time was saved.
  copy_core_pyrope tree
  if [ -n "$CORE_P_STUB_DIR" ]; then
    cp -fL "$CORE_P_STUB_DIR"/*.prp tree/
  fi

  compile_pass() {
    local tag=$1
    shift
    run_timed "compile_$tag" lhd compile "tree/$CORE_TOP.prp" \
      --top "$CORE_TOP" --emit-dir lg:out_lg --workdir w \
      --result-json "compile_$tag.json" "$@"
  }

  compile_cache_metrics() {  # TOKEN RESULT_JSON
    local token=$1 result=$2
    read -r hits misses redone refused failed <<EOF
$(python3 - "$result" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        c = json.load(f).get("incremental", {}).get("compile", {})
    print(c.get("hits", 0), c.get("misses", 0), c.get("redone_ms", 0),
          c.get("refused", 0), c.get("store_failed", 0))
except Exception:
    print(0, 0, 0, 0, 0)
PY
)
EOF
    metric "hits_$token" "$hits" units
    metric "misses_$token" "$misses" units
    metric "redone_ms_$token" "$redone" ms
    metric "refused_$token" "$refused" units
    metric "store_failed_$token" "$failed" units
  }

  rm -rf w out_lg
  compile_pass full --set lhd.incremental=false || exit 1
  compile_cache_metrics full compile_full.json
  metric workdir_bytes_full "$(dir_bytes w)" bytes

  rm -rf w out_lg cold_lg
  compile_pass cold || exit 1
  compile_cache_metrics cold compile_cold.json
  metric workdir_bytes_cold "$(dir_bytes w)" bytes
  cp -R out_lg cold_lg

  # The checked-in dino tests/comment1/ALU.prp has drifted into a genuinely
  # different (though equivalent) implementation. The compile-cache contract
  # needs an actual comment-only byte edit, so make one directly on the current
  # top instead of weakening the semantic key to accommodate that fixture.
  printf '\n// compile incremental comment-only touch\n' >> "tree/$CORE_TOP.prp"
  echo "VARIANT comment-only: appended to $CORE_TOP.prp"
  compile_pass comment || exit 1
  compile_cache_metrics comment compile_comment.json
  metric workdir_bytes_comment "$(dir_bytes w)" bytes
  warm_equal=0
  comment_diff=$(lhd tool diff lg:cold_lg lg:out_lg --structural -q 2>/dev/null)
  [ "$comment_diff" = identical ] && warm_equal=1
  [ "$comment_diff" = identical ] || echo "H5 comment mismatch: $comment_diff" >&2

  # Backend's cache-disabled full and cold builds each take about 40 minutes.
  # Its semantic-edit reference is another cache-disabled build and is not part
  # of the requested full/cold/warm axis, so matrix refreshes may omit that
  # optional fourth pass without weakening the comment-only H5 comparison.
  if [ -n "${BENCH_SKIP_EDIT:-}" ]; then
    metric compile_warm_equals_cold "$warm_equal" bool
    [ "$warm_equal" = 1 ] || { echo "FAIL: comment-only incremental compile differs structurally from cold" >&2; exit 1; }
    if [ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]; then
      cp compile_full.json compile_cold.json compile_comment.json \
        "$TEST_UNDECLARED_OUTPUTS_DIR"/ 2>/dev/null || true
    fi
    echo "PASS: compile_incremental (full/cold/comment over one workdir; semantic edit skipped)"
    exit 0
  fi

  core_variant bug1 tree || exit 1
  compile_pass edit || exit 1
  compile_cache_metrics edit compile_edit.json
  metric workdir_bytes_edit "$(dir_bytes w)" bytes

  # H5 for the semantic edit too: compare the incremental result against an
  # honestly cache-disabled compile of the edited tree. Verification is outside
  # run_timed, so it never contaminates compile_edit_ms.
  rm -rf edit_cold_lg edit_cold_w
  lhd compile "tree/$CORE_TOP.prp" --top "$CORE_TOP" --emit-dir lg:edit_cold_lg \
    --workdir edit_cold_w --set lhd.incremental=false -q --result-json edit_cold.json \
    || { echo "FAIL: cache-disabled H5 reference compile failed" >&2; exit 1; }
  edit_diff=$(lhd tool diff lg:edit_cold_lg lg:out_lg --structural -q 2>/dev/null)
  [ "$edit_diff" = identical ] || warm_equal=0
  if [ "$edit_diff" != identical ]; then
    echo "H5 edit mismatch: $edit_diff" >&2
    lhd tool diff lg:edit_cold_lg lg:out_lg --top "$CORE_TOP" --max 80 -q >&2 || true
  fi
  edit_changed=0
  cold_edit_diff=$(lhd tool diff lg:cold_lg lg:edit_cold_lg --structural -q 2>/dev/null)
  [ "$cold_edit_diff" != identical ] && edit_changed=1
  metric compile_edit_changes_cold "$edit_changed" bool
  [ "$edit_changed" = 1 ] \
    || { echo "FAIL: semantic edit fixture did not change the compiled graph" >&2; exit 1; }
  metric compile_warm_equals_cold "$warm_equal" bool
  [ "$warm_equal" = 1 ] || { echo "FAIL: incremental compile differs structurally from cold" >&2; exit 1; }

  # Preserve the per-pass timers alongside the scalar METRIC lines. The ledger
  # scraper consumes the latter, while optimization work needs the former to
  # attribute residual wall time without rerunning a large cold build.
  if [ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]; then
    cp compile_full.json compile_cold.json compile_comment.json compile_edit.json edit_cold.json \
      "$TEST_UNDECLARED_OUTPUTS_DIR"/ 2>/dev/null || true
  fi

  read -r n_loc n_words <<EOF
$(compile_input_stats compile_cold.json tree "")
EOF
  [[ "$n_loc" =~ ^[0-9]+$ && "$n_words" =~ ^[0-9]+$ ]] || {
    echo "FAIL: could not count the compiled Pyrope cone" >&2
    exit 1
  }
  echo "PASS: compile_incremental (cold/comment/edit over one workdir)"
  exit 0
  ;;
pyrope_parallel)
  NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)
  GEN="$RF/_main/bench/gen_build.py"
  command -v make >/dev/null || { echo "FAIL: make not on PATH" >&2; exit 1; }

  # Avoid expanding 1088 source paths into the human CMD line. The command is
  # still exact and retypable: the shell glob is the source-tree contract.
  scan_tree() {
    printf 'CMD %s: lhd scan %s/pyrope/*.prp -q --result-json scan.json --workdir sw\n' \
      "${CURRENT_STEP:--}" "$CORE" >&3
    "$LHD_BIN" scan "$CORE_P_DIR"/*.prp ${P_STUBS[@]+"${P_STUBS[@]}"} -q --result-json scan.json --workdir sw
  }
  run_timed scan scan_tree
  scan_ms=$LAST_MS
  read -r n_loc n_words <<EOF
$(scan_cone_stats scan.json "$CORE_TOP")
EOF

  # scan.json -> build.mk (+ an illustrative BUILD.bazel). --top prunes to the
  # cone actually reachable from the whole-design top; both cores currently
  # ship a tree where that is every file, so `pruned` reads 0 — the pruning is
  # there so a core with dead .prp files does not pay to compile them.
  printf 'CMD %s: %s\n' generate \
    "python3 bench/gen_build.py scan.json --top $CORE_TOP --mk build.mk --bazel BUILD.bazel" >&3
  run_timed generate python3 "$GEN" scan.json --top "$CORE_TOP" \
    --mk build.mk --bazel BUILD.bazel
  gen_ms=$LAST_MS
  for k in units pruned depth widest; do
    metric "parallel_$k" "$(awk -v k="$k" '$1==k{print $2}' step_generate.log)" files
  done

  # make -j owns the scheduling from here: the dependency graph is the build
  # graph. Recipes log per-unit to u_<unit>.log; build.mk records every command
  # it runs, and both generated files are archived into the test outputs.
  printf 'CMD %s: %s\n' build "make -f build.mk -j$NPROC" >&3
  run_timed build make -f build.mk -j"$NPROC" LHD="$LHD_BIN"
  LAST_MS=$((LAST_MS + scan_ms + gen_ms))
  if [ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]; then
    cp build.mk BUILD.bazel "$TEST_UNDECLARED_OUTPUTS_DIR"/ 2>/dev/null || true
  fi
  ;;

*)
  echo "FAIL: unknown MODE=$MODE" >&2
  exit 2
  ;;
esac

[ -n "$(ls -A out_lg 2>/dev/null)" ] || { echo "FAIL: empty lg: emission" >&2; exit 1; }
metric "${MODE}_loc" "$n_loc" lines
metric "${MODE}_words" "$n_words" words
rate "${MODE}_loc_per_s" "$n_loc" "$LAST_MS" "lines/s"
rate "${MODE}_words_per_s" "$n_words" "$LAST_MS" "words/s"
echo "PASS: $MODE -> lg: ($n_loc LoC in ${LAST_MS} ms)"
