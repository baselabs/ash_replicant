"""Pure verdict tests: no services, API calls, or Elixir runtime."""

import unittest

from qualify import expected_checks, refusals


class QualificationTest(unittest.TestCase):
    def setUp(self):
        self.expected = expected_checks()
        self.jobs = [
            {"name": name, "status": "completed", "conclusion": "success"}
            for name in self.expected
        ]

    def test_success_excludes_running_verdict(self):
        self.jobs.append({"name": "qualified", "status": "in_progress", "conclusion": None})
        self.assertEqual([], refusals("success", self.jobs, self.expected))

    def test_missing_check(self):
        self.assertEqual(
            ["expected check is missing"], refusals("success", self.jobs[1:], self.expected)
        )

    def test_unexpected_job_does_not_print_its_name(self):
        self.jobs.append({"name": "private-value-sentinel"})
        self.assertEqual(
            ["unexpected job is present"], refusals("success", self.jobs, self.expected)
        )

    def test_duplicate_execution(self):
        self.jobs.append(dict(self.jobs[0]))
        self.assertEqual(
            ["expected check has duplicate executions"],
            refusals("success", self.jobs, self.expected),
        )

    def test_non_success_conclusions(self):
        for conclusion in ("failure", "cancelled", "skipped", "neutral", "timed_out", None):
            with self.subTest(conclusion=conclusion):
                self.jobs[0]["conclusion"] = conclusion
                self.assertEqual(
                    ["expected check did not succeed"],
                    refusals("success", self.jobs, self.expected),
                )

    def test_incomplete_execution(self):
        for status in ("queued", "in_progress", None):
            with self.subTest(status=status):
                self.jobs[0]["status"] = status
                self.assertEqual(
                    ["expected check has not completed"],
                    refusals("success", self.jobs, self.expected),
                )

    def test_aggregate_must_succeed(self):
        for result in ("failure", "cancelled", "skipped", "", None):
            with self.subTest(result=result):
                self.assertEqual(
                    ["qualification aggregate did not succeed"],
                    refusals(result, self.jobs, self.expected),
                )

    def test_empty_inventory(self):
        self.assertEqual(
            ["expected check inventory is invalid or empty"], refusals("success", [], [])
        )

    def test_invalid_inventory(self):
        for expected in (None, {}, [None], [""], self.expected * 2, self.expected[::-1]):
            with self.subTest(expected=expected):
                self.assertEqual(
                    ["expected check inventory is invalid or empty"],
                    refusals("success", self.jobs, expected),
                )

    def test_invalid_job_record(self):
        self.jobs.append({"name": ["private-value-sentinel"]})
        self.assertEqual(
            ["run job record is invalid"], refusals("success", self.jobs, self.expected)
        )

    def test_invalid_job_inventory(self):
        self.assertEqual(
            ["run job inventory is invalid"], refusals("success", None, self.expected)
        )

    def test_collects_every_reason(self):
        self.jobs[1]["conclusion"] = "failure"
        self.jobs.extend([dict(self.jobs[2]), {"name": "private-value-sentinel"}])
        self.assertEqual(
            [
                "qualification aggregate did not succeed",
                "expected check is missing",
                "expected check did not succeed",
                "expected check has duplicate executions",
                "unexpected job is present",
            ],
            refusals("failure", self.jobs[1:], self.expected),
        )


if __name__ == "__main__":
    unittest.main()
