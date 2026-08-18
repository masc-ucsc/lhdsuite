#!/usr/bin/env bash
set -euo pipefail
WS="${BUILD_WORKSPACE_DIRECTORY:?must be invoked via: bazel run //bench:ledger}"
PY=bench/ledger.py
[ -f "$PY" ] || PY="$0.runfiles/_main/bench/ledger.py"
exec python3 "$PY" "$WS" "$@"
