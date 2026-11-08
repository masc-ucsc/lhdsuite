#!/usr/bin/env bash
# Verilator vs `lhd sim` (Verilog, Pyrope, Pyrope2) on one core: build times,
# honest two-point-fit cycles/s and the printed marker lines, in one table.
# Standalone — no bazel, no runfiles — so it can run against a FROZEN lhd copy:
#
#   LHD=../livehd/bazel-bin/lhd/lhd bench/simcmp.sh                 # minion
#   bench/simcmp.sh --core dino --lhd /tmp/lhd-snapshot/lhd
#   bench/simcmp.sh --help
#
# See bench/simcmp.py for the method and the fairness rules.
exec python3 "$(dirname "$0")/simcmp.py" "$@"
