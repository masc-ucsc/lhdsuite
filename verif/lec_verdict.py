#!/usr/bin/env python3
"""Classify native LEC's final result for the verif gate.

PASS: PROVEN (unbounded), INCONCLUSIVE (the solver ran and could not decide),
TIMEOUT (the deadline killed it and no counterexample was found).
FAIL: REFUTED, BOUNDED (only some cycles checked), UNDECIDED (an encoder or
admission refusal -- nothing was handed to the solver), NOVERDICT.

Only the TIMEOUT row is new; BOUNDED and UNDECIDED were fatal before under the
single name NOVERDICT and stay fatal, so the gate is no weaker than it was."""

import json
import sys


# A hard deadline kill. The wrappers enforce the five-minute budget with a
# shell watchdog (the sandbox PATH has no `timeout`), so the process is gone
# before it can write a verdict record -- that is a TIMEOUT, not a crash.
TIMEOUT_RETURNCODES = frozenset((124, 137, 143))


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

    # A REFUTATION is never excused by the deadline. If the run got far enough to
    # write one it found a real counterexample, so this test comes before the
    # timeout check -- the ruling is "a timeout that is NOT a refutation is OK",
    # and the record is believed here without the exit-code agreement demanded
    # below because this is the FAILING direction (it fails closed).
    if lec.get('verdict') == 'refuted':
        return 'REFUTED'
    if returncode in TIMEOUT_RETURNCODES:
        return 'TIMEOUT'
    if result is None or result.get('exit_code') != returncode:
        return 'NOVERDICT'
    verdict = lec.get('verdict')
    if verdict == 'proven' and returncode == 0 and not lec.get('bounded', True):
        return 'PROVEN'
    if verdict == 'proven':
        # A BOUNDED proof only checked the cycles it was given. FATAL, exactly as
        # before this file learned about timeouts: the gate's whole job is to
        # notice when a design stops being fully checkable, and a design that
        # silently degrades from unbounded to bounded is that. Reported under its
        # own name only so the log says WHY rather than just "no verdict".
        return 'BOUNDED'
    if verdict == 'unknown' and returncode == 7:
        error = result.get('error', {})
        if error.get('message', '').startswith('lec could not decide equivalence of '):
            # The solver ran and could not decide. No counterexample, and the
            # engine was asked honestly -- a pass here predates the timeout work.
            return 'INCONCLUSIVE'
        # An encoder/admission REFUSAL: the cell or the design was never handed
        # to the solver at all. Also FATAL as before -- this is precisely how a
        # gate goes green while checking nothing.
        return 'UNDECIDED'
    return 'NOVERDICT'


if __name__ == '__main__':
    with open(sys.argv[1], errors='replace') as source:
        print(classify(source.read(), int(sys.argv[2])))
