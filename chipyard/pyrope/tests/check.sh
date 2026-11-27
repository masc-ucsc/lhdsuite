#!/usr/bin/env bash
set -euo pipefail

lhd="$TEST_SRCDIR/$1"
cd "$TEST_SRCDIR/_main"
for source in chipyard/pyrope/*.prp; do
  top=${source##*/}
  top=${top%.prp}
  work="$TEST_TMPDIR/$top"
  "$lhd" compile "$source" --top "$top" --workdir "$work" --emit-dir "lg:$work/out"
done
"$lhd" sim chipyard/pyrope/MaxPeriodFibonacciLFSR.prp chipyard/pyrope/tests/lfsr_tb.prp --workdir "$TEST_TMPDIR/lfsr_sim"
