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
    "${P_STUBS[@]}" \
    --top "$CORE_TOP" --emit-dir lg:out_lg --workdir w --result-json compile_pyrope.json
  read -r n_loc n_words <<EOF
$(compile_input_stats compile_pyrope.json "$CORE_P_DIR" "$CORE_P_STUB_DIR")
EOF
  [[ "$n_loc" =~ ^[0-9]+$ && "$n_words" =~ ^[0-9]+$ ]] || {
    echo "FAIL: could not count the compiled Pyrope cone" >&2
    exit 1
  }
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
    "$LHD_BIN" scan "$CORE_P_DIR"/*.prp "${P_STUBS[@]}" -q --result-json scan.json --workdir sw
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
