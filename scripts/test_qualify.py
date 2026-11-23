"""Pure verdict tests: no services, API calls, or Elixir runtime."""

from contextlib import redirect_stdout
import io
import json
import subprocess
import unittest
from unittest.mock import patch

from qualify import (
    QualificationInputError,
    expected_checks,
    job_read_refusal,
    main,
    refusals,
    run_jobs,
)


class QualificationTest(unittest.TestCase):
    def setUp(self):
        self.expected = ["qualification / First", "qualification / Second", "qualification / Third"]
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


class QualificationInputsTest(unittest.TestCase):
    inventory_reason = "expected check inventory (EXPECTED_CHECKS) is missing or invalid"

    def test_expected_checks_reads_workflow_output(self):
        expected = ["qualification / First", "qualification / Second"]
        with patch("qualify.os.environ", {"EXPECTED_CHECKS": json.dumps(expected)}):
            self.assertEqual(expected, expected_checks())

    def test_expected_checks_refuses_missing_or_invalid_output(self):
        for value in (
            None, "", "private-value-sentinel", "null", "{}", "[]", '[""]', '[" "]',
            '[null]', '[1]', '[{}]', '["same", "same"]', '"private-value-sentinel"',
        ):
            with self.subTest(value=value):
                environment = {} if value is None else {"EXPECTED_CHECKS": value}
                with patch("qualify.os.environ", environment):
                    with self.assertRaises(QualificationInputError) as caught:
                        expected_checks()
                self.assertEqual(self.inventory_reason, str(caught.exception))

    def assert_main_refusal(self, environment, reason):
        output = io.StringIO()
        with patch("qualify.os.environ", environment), redirect_stdout(output):
            self.assertEqual(1, main())
        self.assertEqual("Qualification refused:\n  " + reason + "\n", output.getvalue())

    def test_main_names_the_missing_inventory(self):
        self.assert_main_refusal({}, self.inventory_reason)

    def test_main_names_the_invalid_inventory_without_its_value(self):
        self.assert_main_refusal({"EXPECTED_CHECKS": "private-value-sentinel"},
                                 self.inventory_reason)

    def test_main_names_missing_github_run_identity(self):
        environment = {
            "EXPECTED_CHECKS": '["qualification / First"]',
            "GITHUB_REPOSITORY": "fixture/repository",
            "GITHUB_RUN_ID": "123",
        }
        for key in ("GITHUB_REPOSITORY", "GITHUB_RUN_ID"):
            for value in (None, ""):
                with self.subTest(key=key, value=value):
                    missing = dict(environment)
                    if value is None:
                        missing.pop(key)
                    else:
                        missing[key] = value
                    self.assert_main_refusal(missing, "GITHUB_REPOSITORY/GITHUB_RUN_ID missing")

    def test_main_names_the_missing_token(self):
        self.assert_main_refusal({
            "EXPECTED_CHECKS": '["qualification / First"]',
            "GITHUB_REPOSITORY": "fixture/repository",
            "GITHUB_RUN_ID": "123",
        }, "GitHub token is required")

    def test_job_reader_requires_a_token_before_any_api_call(self):
        with patch("qualify.os.environ", {}):
            with self.assertRaises(QualificationInputError) as caught:
                run_jobs("fixture/repository", "123")
        self.assertEqual("GitHub token is required", str(caught.exception))

    def test_actions_read_errors_do_not_expose_arguments_or_response_values(self):
        sentinel = "private-value-sentinel"
        for error, reason in (
            (subprocess.CalledProcessError(7, [sentinel], output=sentinel, stderr=sentinel),
             "gh api exited 7"),
            (subprocess.TimeoutExpired([sentinel], 30, output=sentinel, stderr=sentinel),
             "gh api timed out"),
            (FileNotFoundError(sentinel), "gh api could not be executed"),
            (subprocess.SubprocessError(sentinel), "gh api failed"),
            (json.JSONDecodeError(sentinel, sentinel, 0), "invalid or incomplete response"),
            (ValueError(sentinel), "invalid or incomplete response"),
            (TypeError(sentinel), "invalid or incomplete response"),
        ):
            with self.subTest(error=type(error).__name__):
                self.assertEqual("Actions job inventory could not be read: " + reason,
                                 job_read_refusal(error))


if __name__ == "__main__":
    unittest.main()
