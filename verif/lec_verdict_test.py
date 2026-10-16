#!/usr/bin/env python3
"""Regression checks for verdicts accepted by the native verification gate."""
import json
import unittest

from lec_verdict import classify

# The gates' ALLOWLIST (verif/genprp.sh, verif/v2v.sh: `PROVEN-* | TESTED-* |
# TIMEOUT-*` passes, everything else fails). Kept here so a policy change has to
# update the gates and this list together.
PASSING_PREFIXES = ('PROVEN-', 'TESTED-', 'TIMEOUT-')


def gate_passes(cls):
    return cls.startswith(PASSING_PREFIXES)


NO_ANSWER_WHYS = ('interface', 'unsupported', 'unchecked', 'vacuous', 'unexplained')


class VerdictTests(unittest.TestCase):
    def result(self, verdict, rc, bounded=False, **fields):
        lec = dict(verdict=verdict, bounded=bounded)
        lec.update(fields.pop('lec', {}))
        return json.dumps(dict(tool='lhd', command='lec', exit_code=rc, lec=lec, **fields))

    def test_final_result_overrides_child_proof(self):
        log = "lec[hier]: 'child' PROVEN (0 child collapses)\n" + self.result('refuted-cex', 10)
        self.assertEqual(classify(log, 10), 'REFUTED-cex')
        self.assertFalse(gate_passes('REFUTED-cex'))

    def test_real_envelopes(self):
        # Trimmed from `lhd lec` (livehd fd3b5c7ab) on a toy a+b vs a-b / b+a.
        refuted = ('{"schema_version":1,"tool":"lhd","command":"lec","status":"fail","exit_code":10,'
                   '"lec":{"verdict":"refuted-cex","solver":"cvc5","bounded":false},'
                   '"error":{"class":"equiv_fail","message":"REFUTED-cex: \'t\' is not equivalent (c.v vs a.v)"}}')
        self.assertEqual(classify("lec: 't' REFUTED-cex (not equivalent)\n" + refuted, 10), 'REFUTED-cex')
        tested = ('{"schema_version":1,"tool":"lhd","command":"lec","status":"pass","exit_code":0,'
                  '"lec":{"verdict":"tested-sampled","vectors":2058,"effort":"test","solver":"cvc5","bounded":false}}')
        self.assertEqual(classify(tested, 0), 'TESTED-sampled(2058)')
        proven = ('{"schema_version":1,"tool":"lhd","command":"lec","status":"pass","exit_code":0,'
                  '"lec":{"verdict":"proven-full","solver":"cvc5","bounded":false}}')
        self.assertEqual(classify(proven, 0), 'PROVEN-full')

    def test_exit_zero_outcomes_pass(self):
        # Owner ruling 2026-10-14: only a refute fails; TIMEOUT-* and bounded
        # proofs are acceptable.
        cases = [
            (self.result('proven-full', 0), 'PROVEN-full'),
            (self.result('proven-bounded', 0, bounded=True, lec=dict(bound=6)), 'PROVEN-bounded(6)'),
            (self.result('proven-bounded', 0, bounded=True, lec=dict(bound=6, effort='test')), 'PROVEN-bounded(6)'),
            (self.result('tested-sampled', 0, lec=dict(vectors=2048, effort='test')), 'TESTED-sampled(2048)'),
            (self.result('timeout-time', 0), 'TIMEOUT-time'),
            (self.result('timeout-memory', 0), 'TIMEOUT-memory'),
        ]
        for log, want in cases:
            self.assertEqual(classify(log, 0), want)
            self.assertTrue(gate_passes(want), want)

    def test_no_answer_refutes_fail(self):
        # Every REFUTED-<why> is lhd failing to answer (exit 7): a failure, and
        # distinct from REFUTED-cex so a check that wants a real counterexample
        # can still tell them apart.
        for why in NO_ANSWER_WHYS:
            log = self.result('refuted-' + why, 7, error=dict(message='REFUTED-%s: ...' % why))
            verdict = classify(log, 7)
            self.assertEqual(verdict, 'REFUTED-' + why)
            self.assertNotEqual(verdict, 'REFUTED-cex')
            self.assertFalse(gate_passes(verdict))
        self.assertEqual(classify(self.result('refuted-Bad why!', 7), 7), 'REFUTED-unexplained')

    def test_success_requires_successful_exit(self):
        # A record claiming a pass cannot be believed when the process itself
        # failed for a reason that is NOT the deadline, or when the record's own
        # exit code disagrees with the process.
        for verdict in ('proven-full', 'tested-sampled', 'timeout-time'):
            self.assertEqual(classify(self.result(verdict, 0), 6), 'NOVERDICT')
            self.assertEqual(classify(self.result(verdict, 7), 7), 'NOVERDICT')
            self.assertEqual(classify(self.result(verdict, 7), 0), 'NOVERDICT')
        self.assertFalse(gate_passes('NOVERDICT'))

    def test_bounded_proof_is_not_unbounded(self):
        verdict = classify(self.result('proven-bounded', 0, bounded=True, lec=dict(bound=8)), 0)
        self.assertEqual(verdict, 'PROVEN-bounded(8)')
        self.assertNotEqual(verdict, 'PROVEN-full')
        # A self-contradictory record is not believed in either direction.
        self.assertEqual(classify(self.result('proven-full', 0, bounded=True), 0), 'NOVERDICT')
        self.assertEqual(classify(self.result('proven-bounded', 0, bounded=False), 0), 'NOVERDICT')

    def test_deadline_kill_is_a_timeout(self):
        # The wrappers enforce the budget with a shell watchdog, so the process
        # is killed before it can write a verdict record at all.
        for rc in (124, 137, 143):
            self.assertEqual(classify('lec running...', rc), 'TIMEOUT-deadline')
        self.assertTrue(gate_passes('TIMEOUT-deadline'))

    def test_refutation_beats_the_deadline(self):
        # A run that wrote a refutation and was THEN killed found a real
        # counterexample. The rule is "a timeout that is not a refutation is
        # OK", so the refutation has to win -- otherwise the deadline silently
        # converts a failing design into a passing one.
        for rc in (124, 137, 143):
            self.assertEqual(classify(self.result('refuted-cex', 10), rc), 'REFUTED-cex')
            self.assertEqual(classify(self.result('refuted-unsupported', 7), rc), 'REFUTED-unsupported')

    def test_missing_or_truncated_result(self):
        for log in ["lec: 'top' PROVEN-full ()", '{"tool":"lhd",']:
            self.assertEqual(classify(log, 0), 'NOVERDICT')

    def test_legacy_words_fail_closed(self):
        # The pre-2026-10-14 vocabulary is never printed any more; meeting it
        # means a stale lhd, and the gate must not guess what it meant.
        for verdict, rc in (('proven', 0), ('tested', 0), ('unknown', 7), ('refuted', 10)):
            cls = classify(self.result(verdict, rc), rc)
            self.assertEqual(cls, 'NOVERDICT')
            self.assertFalse(gate_passes(cls))


if __name__ == '__main__':
    unittest.main()
