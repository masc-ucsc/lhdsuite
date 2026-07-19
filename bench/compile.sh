#!/usr/bin/env bash
# Lgraph-creation throughput: source -> compiled lg: library.
#   MODE=verilog  slang front-end via the filelist (-F, -DSYNTHESIS)
#   MODE=pyrope   top .prp; sibling import discovery pulls the whole tree
#   MODE=pyrope_parallel
#                 per-file separate compilation: `lhd scan` (lexer-only import
#                 discovery) builds the dependency picture, every import-free
#                 file compiles in PARALLEL into its own ln:+lg: emission, and
#                 dependents compile with `--in-dir ln:` reuse (pre-compiled
#                 units ride in; stateful mod/pipe interfaces are not
#                 re-elaborated). The dependent's lg: emission is a COMPLETE
#                 design library — same shape as the monolithic compile. On a
#                 design this small, process overhead eats the speedup; the
#                 value is demonstrating the flow (and scaling on big trees).
# Reports LoC/s and words/s over the language's sources.
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
. "$RF/_main/bench/common.sh"

case "${MODE:?}" in
verilog)
  n_loc=$(loc $(dino_v_sources))
  n_words=$(words $(dino_v_sources))
  run_timed compile_verilog lhd compile verilog --top PipelinedDualIssueCPU \
    --emit-dir lg:out_lg --workdir w -- -F "$DINO_V_DIR/filelist.f" -DSYNTHESIS
  ;;
pyrope)
  n_loc=$(loc "$DINO_P_DIR"/*.prp)
  n_words=$(words "$DINO_P_DIR"/*.prp)
  run_timed compile_pyrope lhd compile "$DINO_P_DIR/PipelinedDualIssueCPU.prp" \
    --top PipelinedDualIssueCPU --emit-dir lg:out_lg --workdir w
  ;;
pyrope_parallel)
  n_loc=$(loc "$DINO_P_DIR"/*.prp)
  n_words=$(words "$DINO_P_DIR"/*.prp)
  NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)

  run_timed scan lhd scan "$DINO_P_DIR"/*.prp -q --result-json scan.json --workdir sw
  # Split the scan into import-free files (parallel wave) and dependents in
  # topological order (each sees every previously built unit via --in-dir).
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
    for f in leaf_*.log; do
      grep -q '"status":"pass"' "$f" \
        || { echo "FAIL: leaf compile ${f%.log}:" >&2; tail -5 "$f" >&2; return 1; }
    done
  }
  run_timed leaves_parallel compile_leaves
  wave1_ms=$LAST_MS

  compile_deps() {  # dependents in topo order, reusing every built ln: unit
    local f b ins d
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b=$(basename "$f" .prp)
      ins=""
      for d in ln_*; do ins="$ins --in-dir ln:$d"; done
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
