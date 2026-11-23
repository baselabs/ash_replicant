#!/usr/bin/env python3
"""Require the current candidate run's complete, successful proof inventory."""

import json
import os
import subprocess
import sys


MAX_PAGES = 10


class QualificationInputError(ValueError):
    """An input refusal containing only a fixed, value-free reason."""


def refusals(qualification_result, jobs, expected):
    """Return structural reasons for refusing qualification, without API values."""
    refused = []
    if qualification_result != "success":
        refused.append("qualification aggregate did not succeed")
    if (
        not isinstance(expected, list)
        or not expected
        or not all(isinstance(name, str) and name.startswith("qualification / ") for name in expected)
        or len(set(expected)) != len(expected)
        or expected != sorted(expected)
    ):
        return refused + ["expected check inventory is invalid or empty"]
    if not isinstance(jobs, list):
        return refused + ["run job inventory is invalid"]

    seen = {}
    for job in jobs:
        if not isinstance(job, dict) or not isinstance(job.get("name"), str):
            refused.append("run job record is invalid")
        elif job["name"] != "qualified":
            seen.setdefault(job["name"], []).append(job)

    for name in expected:
        executions = seen.pop(name, [])
        if not executions:
            refused.append("expected check is missing")
        elif len(executions) != 1:
            refused.append("expected check has duplicate executions")
        elif executions[0].get("status") != "completed":
            refused.append("expected check has not completed")
        elif executions[0].get("conclusion") != "success":
            refused.append("expected check did not succeed")
    refused.extend("unexpected job is present" for _name in seen)
    return refused


def run_jobs(repository, run_id):
    """Read every latest job execution, refusing incomplete or oversized pagination."""
    if not os.environ.get("GH_TOKEN"):
        raise QualificationInputError("GitHub token is required")
    jobs = []
    total = None
    for page in range(1, MAX_PAGES + 1):
        response = subprocess.run(
            [
                "gh", "api", "--hostname", "github.com",
                f"repos/{repository}/actions/runs/{run_id}/jobs"
                f"?filter=latest&per_page=100&page={page}",
            ],
            check=True, capture_output=True, text=True, timeout=30,
        )
        body = json.loads(response.stdout)
        if not isinstance(body, dict):
            raise ValueError("invalid job page")
        count = body.get("total_count")
        records = body.get("jobs")
        if type(count) is not int or count < 0 or not isinstance(records, list):
            raise ValueError("invalid job page")
        if len(records) > 100 or (total is not None and count != total):
            raise ValueError("inconsistent job pages")
        total = count
        jobs.extend(records)
        if len(jobs) == total:
            return jobs
        if not records or len(jobs) > total:
            raise ValueError("incomplete job pages")
    raise ValueError("job pagination limit exceeded")


def expected_checks():
    """Read the inventory already derived by the qualification workflow."""
    reason = "expected check inventory (EXPECTED_CHECKS) is missing or invalid"
    try:
        expected = json.loads(os.environ.get("EXPECTED_CHECKS", ""))
    except (ValueError, TypeError):
        raise QualificationInputError(reason) from None
    if (
        not isinstance(expected, list)
        or not expected
        or not all(isinstance(name, str) and name.strip() for name in expected)
        or len(set(expected)) != len(expected)
    ):
        raise QualificationInputError(reason)
    return expected


def job_read_refusal(error):
    """Describe a failed Actions read without command arguments, output, or API values."""
    reason = "Actions job inventory could not be read: "
    if isinstance(error, subprocess.CalledProcessError):
        return reason + f"gh api exited {error.returncode}"
    if isinstance(error, subprocess.TimeoutExpired):
        return reason + "gh api timed out"
    if isinstance(error, OSError):
        return reason + "gh api could not be executed"
    if isinstance(error, subprocess.SubprocessError):
        return reason + "gh api failed"
    return reason + "invalid or incomplete response"


def main():
    try:
        expected = expected_checks()
        repository = os.environ.get("GITHUB_REPOSITORY")
        run_id = os.environ.get("GITHUB_RUN_ID")
        if not repository or not run_id:
            raise QualificationInputError("GITHUB_REPOSITORY/GITHUB_RUN_ID missing")
        jobs = run_jobs(repository, run_id)
        refused = refusals(os.environ.get("QUALIFICATION_RESULT"), jobs, expected)
    except QualificationInputError as error:
        refused = [str(error)]
    except (OSError, subprocess.SubprocessError, ValueError, TypeError) as error:
        refused = [job_read_refusal(error)]
    if refused:
        print("Qualification refused:\n  " + "\n  ".join(refused))
        return 1
    print(f"Qualified: all {len(expected)} expected checks completed successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
