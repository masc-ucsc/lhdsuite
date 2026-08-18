#!/usr/bin/env bash
# bazel run //bench:ledger -- <add|append|render> ...
#
#   ./bench/matrix.sh xs_alu                     # measure full/cold/incremental
#   bazel run //bench:ledger -- add --config-id baseline-v1 matrix_rows.jsonl
#   bazel run //bench:ledger -- append baseline-v1 dino minion xs_alu xs_rob
#   bazel run //bench:ledger -- render --flow incr
#
# `add` stamps the host/sha/pdk identity block onto the partial rows a
# measurement driver produced and appends them; `append` scrapes the most recent
# `bazel test //bench:...` results out of bazel-testlogs into the same row shape;
# `render` re-derives the scoreboard HTML from the ledger. All three are
# read-only with respect to the benches — run the measurement first.
#
# NOTE: `add` reads its input relative to the directory bazel run started in
# only when given an absolute path; a bare name is resolved against the
# workspace root, since bazel run moves the cwd into the runfiles tree.
set -euo pipefail
RF="${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}"
exec python3 "$RF/_main/bench/ledger.py" "$@"
