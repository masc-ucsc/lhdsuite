#!/usr/bin/env bash
set -euo pipefail
rf=${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}
scripts=$rf/_main/mixed_soc/scripts
export PYTHONPATH=$scripts
mode=${1:?simulation mode or topology required}
case "$mode" in
  topology)
    exec python3 -P "$scripts/floorplan.py"
    ;;
  mesh | system)
    exec python3 -P "$scripts/simulate.py" "$mode" --work "${TEST_TMPDIR:?}/connectivity" -j "${LHD_BENCH_JOBS:-4}"
    ;;
  pyrope | verilator)
    lhd=$rf/${2:?LiveHD runfile required}
    exec python3 -P "$scripts/run_sim.py" "$mode" --lhd "$lhd" --work "${TEST_TMPDIR:?}/mixed_sim"
    ;;
  *)
    echo "unknown mixed_soc test mode: $mode" >&2
    exit 2
    ;;
esac
