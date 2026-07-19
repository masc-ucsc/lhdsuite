#!/usr/bin/env bash
# bazel run //bench:show — summarize the last `bazel test //bench:...` results
# (reads bazel-testlogs; it cannot trigger the tests itself, so run
# `bazel test //bench:all` first).
set -euo pipefail
WS="${BUILD_WORKSPACE_DIRECTORY:?must be invoked via: bazel run //bench:show}"
PY=bench/show.py
[ -f "$PY" ] || PY="$0.runfiles/_main/bench/show.py"
exec python3 "$PY" "$WS/bazel-testlogs/bench" "$@"
