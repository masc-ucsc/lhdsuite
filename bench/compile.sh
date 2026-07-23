#!/usr/bin/env bash
# Lgraph-creation throughput: source -> compiled lg: library.
#   MODE=verilog  slang front-end via the filelist (-F, -DSYNTHESIS, plus the
#                 core's $CORE_V_FLAGS). LoC/words count the WHOLE filelist,
#                 since slang parses every file in it.
#   MODE=pyrope   top .prp; sibling import discovery pulls the whole tree
#   MODE=pyrope_parallel
#                 per-file separate compilation: `lhd scan` (lexer-only import
#                 discovery) builds the dependency picture, every import-free
#                 file compiles in PARALLEL into its own ln:+lg: emission, and
#                 dependents reuse them by naming each one as a POSITIONAL
#                 `ln:DIR` input — never a flag (pre-compiled units ride in;
#                 stateful mod/pipe interfaces are not re-elaborated). The
#                 dependent's lg: emission is a COMPLETE
#                 design library — same shape as the monolithic compile. On a
#                 design this small, process overhead eats the speedup; the
#                 value is demonstrating the flow (and scaling on big trees).
# Reports LoC/s and words/s over the language's sources.
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

case "${MODE:?}" in
verilog)
  n_loc=$(loc $(core_v_sources))
  n_words=$(words $(core_v_sources))
  run_timed compile_verilog lhd compile verilog --top "$CORE_TOP" \
    --emit-dir lg:out_lg --workdir w -- -F "$CORE_V_DIR/filelist.f" -DSYNTHESIS $CORE_V_FLAGS
  ;;
pyrope)
  n_loc=$(loc "$CORE_P_DIR"/*.prp)
  n_words=$(words "$CORE_P_DIR"/*.prp)
  run_timed compile_pyrope lhd compile "$CORE_P_DIR/$CORE_TOP.prp" \
    --top "$CORE_TOP" --emit-dir lg:out_lg --workdir w
  ;;
pyrope_parallel)
  n_loc=$(loc "$CORE_P_DIR"/*.prp)
  n_words=$(words "$CORE_P_DIR"/*.prp)
  NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)

  run_timed scan lhd scan "$CORE_P_DIR"/*.prp -q --result-json scan.json --workdir sw
  # Split the scan into import-free files (parallel wave) and dependents in
  # topological order (each sees every previously built unit as an ln: input).
  python3 - scan.json <<'PY'
import json, sys
sc = json.load(open(sys.argv[1]))["scan"]
imp = {e["file"]: set(e["imports"]) for e in sc}
stem = lambda f: f.rsplit("/", 1)[-1].split(".")[0]
stems = {f: stem(f) for f in imp}
open("leaves.txt", "w").write("\n".join(f for f, i in imp.items() if not i) + "\n")
done = {s for f, s in stems.items() if not imp[f]}
order = []
pending = {f for f, i in imp.items() if i}
while pending:
    ready = [f for f in pending if {i.split(".")[0] for i in imp[f]} <= done]
    if not ready:  # imports outside this tree: compile them last, discovery resolves
        ready = sorted(pending)
    for f in sorted(ready):
        order.append(f)
        done.add(stems[f])
        pending.discard(f)
open("deps.txt", "w").write("\n".join(order) + "\n")
PY

  pkg_only=0  # type/constant-only leaves, counted by compile_leaves below
  compile_leaves() {  # all import-free files, NPROC at a time
    local n=0 f b
    while IFS= read -r f; do
      b=$(basename "$f" .prp)
      lhd compile "$f" --emit-dir "ln:ln_$b" --emit-dir "lg:lg_$b" --workdir "cw_$b" \
        >"leaf_$b.log" 2>&1 &
      n=$((n + 1))
      [ $((n % NPROC)) -ne 0 ] || wait
    done <leaves.txt
    wait
    # A type/constant-only leaf (a `_pkg` file) legitimately produces no
    # lgraph: lhd emits an EMPTY lg: library and warns, so it is an ordinary
    # pass. Count those warnings for the metric; any non-pass is a real failure.
    for f in leaf_*.log; do
      grep -q '"status":"pass"' "$f" \
        || { echo "FAIL: leaf compile ${f%.log}:" >&2; tail -5 "$f" >&2; return 1; }
      if grep -q 'produced no graphs' "$f"; then
        pkg_only=$((pkg_only + 1))
      fi
    done
  }
  run_timed leaves_parallel compile_leaves
  wave1_ms=$LAST_MS
  metric leaves_pkg_only "$pkg_only" files

  compile_deps() {  # dependents in topo order, reusing every built ln: unit
    local f b ins d
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b=$(basename "$f" .prp)
      ins=""
      # IR inputs are POSITIONAL — `lhd compile <src> ln:DIR …` (`lhd compile
      # --help`: files = path[] and/or ln:DIR|lg:DIR). There is no flag form:
      # passing a pre-compiled unit as an option is an error, so keep these
      # bare in $ins.
      for d in ln_*; do ins="$ins ln:$d"; done
      # shellcheck disable=SC2086
      lhd compile "$f" $ins --emit-dir "ln:ln_$b" --emit-dir lg:out_lg --workdir "cw_$b" \
        >"dep_$b.log" 2>&1 || { tail -10 "dep_$b.log" >&2; return 1; }
    done <deps.txt
  }
  run_timed deps_reuse compile_deps
  LAST_MS=$((LAST_MS + wave1_ms))
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
