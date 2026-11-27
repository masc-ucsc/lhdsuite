#!/usr/bin/env bash
set -euo pipefail
rf=${TEST_SRCDIR:-${RUNFILES_DIR:-$0.runfiles}}
scripts=$rf/_main/mixed_soc/scripts
export PYTHONPATH=$scripts
mode=${1:?simulation mode or topology required}
case "$mode" in
  topology)
    exec python3 -m floorplan
    ;;
  mesh | system)
    exec python3 -m simulate "$mode" --work "${TEST_TMPDIR:?}/connectivity" -j "${LHD_BENCH_JOBS:-4}"
    ;;
  coherent_harts | interrupt_harts | interrupt_mmio)
    lhd=$rf/${2:?LiveHD runfile required}
    design=$rf/_main/mixed_soc
    inputs=("$design/sim/$mode.prp")
    case "$mode" in
      interrupt_harts) inputs=("$design/pyrope/MixedSocTop.prp" "${inputs[@]}") ;;
      coherent_harts) inputs=("$design/pyrope/CoherentMixedSoc.prp" "${inputs[@]}") ;;
    esac
    exec "$lhd" sim "${inputs[@]}" \
      --set compile.unknown_zero=true --set sim.init_zero=true --workdir "${TEST_TMPDIR:?}/coherent"
    ;;
  pyrope | verilator)
    lhd=$rf/${2:?LiveHD runfile required}
    exec python3 -m run_sim "$mode" --lhd "$lhd" --work "${TEST_TMPDIR:?}/mixed_sim"
    ;;
  *)
    echo "unknown mixed_soc test mode: $mode" >&2
    exit 2
    ;;
esac
