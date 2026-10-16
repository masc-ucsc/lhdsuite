#!/usr/bin/env python3
"""Classify native LEC's final result for the verif gate (verif/genprp.sh, verif/v2v.sh).

Reads lhd's one-line result envelope (`{"tool":"lhd","command":"lec",...}`)
from the step log and prints ONE class word, in lhd's own outcome vocabulary
(livehd pass/lec/property_types.hpp `Outcome`), from the record's `lec.verdict`:

  lec.verdict           exit         class               gate
  proven-full           0            PROVEN-full         PASS  unbounded proof
  proven-bounded        0            PROVEN-bounded(n)   PASS  n = lec.bound design cycles
  tested-sampled        0            TESTED-sampled(N)   PASS  N = lec.vectors, no mismatch
  timeout-time          0            TIMEOUT-time        PASS  formal.timeout reached, nothing claimed
  timeout-memory        0            TIMEOUT-memory      PASS  out of memory, nothing claimed
  (harness kill)        124/137/143  TIMEOUT-deadline    PASS  this script's wall clock, not lhd's
  refuted-cex           10           REFUTED-cex         FAIL  a real counterexample
  refuted-<why>         7            REFUTED-<why>       FAIL  no answer: interface, unsupported,
                                                               unchecked, vacuous, unexplained
  anything else                      NOVERDICT           FAIL  no record, a truncated one, a record
                                                               whose exit code disagrees, a legacy word

Policy (owner rulings 2026-09-15 and 2026-10-14): ONLY a refutation fails --
any REFUTED-*, not just REFUTED-cex, because an undecided top is a failure to
answer, never a pass. TIMEOUT-* and bounded proofs are accepted. The gates
pass on an ALLOWLIST (PROVEN-* | TESTED-* | TIMEOUT-*), so a class this file
does not know fails closed.

The pre-2026-10-14 classes map onto these: PROVEN -> PROVEN-full; BOUNDED and
BOUNDED_EFFORT -> PROVEN-bounded(n) (accepted under any effort now: ruling);
TESTED -> TESTED-sampled(N); INCONCLUSIVE (the solver ran out) -> lhd reports
that as TIMEOUT-time; TIMEOUT -> TIMEOUT-deadline; UNDECIDED (an encoder or
admission refusal) -> REFUTED-unsupported (and the other REFUTED-<why>), still
fatal; REFUTED -> REFUTED-cex; NOVERDICT unchanged."""

import json
import re
import sys


# A hard deadline kill. The wrappers enforce the budget with a shell watchdog
# (the sandbox PATH has no `timeout`), so the process is gone before it can
# write a verdict record -- that is a TIMEOUT, not a crash.
TIMEOUT_RETURNCODES = frozenset((124, 137, 143))

# lhd's exit-0 outcomes (json word -> printed word). Every one is believed only
# when the record's exit code AND the process exit code are both 0.
PASSING = {
    'proven-full': 'PROVEN-full',
    'proven-bounded': 'PROVEN-bounded',
    'tested-sampled': 'TESTED-sampled',
    'timeout-time': 'TIMEOUT-time',
    'timeout-memory': 'TIMEOUT-memory',
}


def _depth(lec, key):
    value = lec.get(key)
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return '(%d)' % value
    return ''


def classify(log, returncode):
    result = None
    for line in log.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and record.get('tool') == 'lhd' and record.get('command') == 'lec':
            result = record
    lec = (result or {}).get('lec', {})
    if not isinstance(lec, dict):
        lec = {}
    verdict = lec.get('verdict')
    verdict = verdict if isinstance(verdict, str) else ''

    # A REFUTATION is never excused by the deadline or by an exit code. If the
    # run got far enough to write one, the gate fails: REFUTED-cex is a real
    # counterexample, every other REFUTED-<why> is lhd failing to answer. This
    # comes before the timeout check -- the ruling is "a timeout that is NOT a
    # refutation is OK" -- and the record is believed without the exit-code
    # agreement demanded below because this is the FAILING direction.
    if verdict.startswith('refuted-'):
        why = verdict[len('refuted-'):]
        return 'REFUTED-' + (why if re.fullmatch(r'[a-z]+', why) else 'unexplained')
    if returncode in TIMEOUT_RETURNCODES:
        return 'TIMEOUT-deadline'
    if result is None or result.get('exit_code') != returncode or returncode != 0:
        # A record claiming success cannot be believed when the process itself
        # failed for a reason that is NOT the deadline (or there is no record).
        return 'NOVERDICT'
    word = PASSING.get(verdict)
    if word is None:
        # Unknown or legacy ('proven', 'unknown', 'tested', ...) words fail closed.
        return 'NOVERDICT'
    bounded = lec.get('bounded')
    if verdict == 'proven-full':
        # `bounded` is always written; a full proof that says it is bounded is
        # a self-contradictory record, and the gate does not guess which half.
        return word if bounded is False else 'NOVERDICT'
    if verdict == 'proven-bounded':
        return word + _depth(lec, 'bound') if bounded is True else 'NOVERDICT'
    if verdict == 'tested-sampled':
        return word + _depth(lec, 'vectors')
    return word


if __name__ == '__main__':
    with open(sys.argv[1], errors='replace') as source:
        print(classify(source.read(), int(sys.argv[2])))
