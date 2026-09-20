#!/usr/bin/env python3
"""Regression checks for verdicts accepted by the native verification gate."""
import json
import unittest

from lec_verdict import classify

# The verdicts this gate treats as failures (verif/genprp.sh, verif/v2v.sh).
# Kept here so a policy change has to update the gates and this list together.
FATAL = frozenset(('REFUTED', 'BOUNDED', 'UNDECIDED', 'NOVERDICT'))


class VerdictTests(unittest.TestCase):
    def result(self, verdict, rc, **fields):
        return json.dumps(dict(tool='lhd', command='lec', exit_code=rc,
                               lec=dict(verdict=verdict, bounded=False), **fields))

    def test_final_result_overrides_child_proof(self):
        log = 'lec child PROVEN equivalent\n' + self.result('refuted', 10)
        self.assertEqual(classify(log, 10), 'REFUTED')

    def test_solver_inconclusive(self):
        log = self.result('unknown', 7, error=dict(message="lec could not decide equivalence of 'Rob.Rob'"))
        self.assertEqual(classify(log, 7), 'INCONCLUSIVE')

    def test_refusal_is_not_solver_timeout(self):
        # An encoder/admission refusal is NOT the solver failing to decide: it
        # never reached the solver. Reported under its own name, still fatal.
        for message in ["lec REFUSED 'Rob': unsupported cell", 'oversize admission refused']:
            log = self.result('unknown', 7, error=dict(message=message))
            self.assertEqual(classify(log, 7), 'UNDECIDED')
            self.assertIn('UNDECIDED', FATAL)

    def test_proof_requires_successful_exit(self):
        log = self.result('proven', 0)
        self.assertEqual(classify(log, 0), 'PROVEN')
        # A record claiming a proof cannot be believed when the process itself
        # failed for a reason that is NOT the deadline.
        self.assertEqual(classify(log, 6), 'NOVERDICT')

    def test_bounded_proof_is_not_unbounded(self):
        record = json.loads(self.result('proven', 0))
        record['lec']['bounded'] = True
        verdict = classify(json.dumps(record), 0)
        self.assertEqual(verdict, 'BOUNDED')
        self.assertNotEqual(verdict, 'PROVEN')
        self.assertIn('BOUNDED', FATAL)  # as fatal as it was under NOVERDICT

    def test_deadline_kill_is_a_timeout(self):
        # The wrappers enforce the budget with a shell watchdog, so the process
        # is killed before it can write a verdict record at all.
        for rc in (124, 137, 143):
            self.assertEqual(classify('lec running...', rc), 'TIMEOUT')
            self.assertNotIn('TIMEOUT', FATAL)

    def test_refutation_beats_the_deadline(self):
        # A run that wrote a refutation and was THEN killed found a real
        # counterexample. The rule is "a timeout that is not a refutation is
        # OK", so the refutation has to win -- otherwise the deadline silently
        # converts a failing design into a passing one.
        log = self.result('refuted', 10)
        for rc in (124, 137, 143):
            self.assertEqual(classify(log, rc), 'REFUTED')

    def test_missing_or_truncated_result(self):
        for log in ['lec child PROVEN equivalent', '{"tool":"lhd",']:
            self.assertEqual(classify(log, 0), 'NOVERDICT')


if __name__ == '__main__':
    unittest.main()
