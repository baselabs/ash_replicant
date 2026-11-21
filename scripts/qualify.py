#!/usr/bin/env python3
"""Require the current candidate run's complete, successful proof inventory."""

import json
import os
from pathlib import Path
import subprocess
import sys


INVENTORY = Path(__file__).with_name("qualification-jobs.json")
MAX_PAGES = 10


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
        raise ValueError("GitHub token is required")
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
    response = subprocess.run(
        [str(INVENTORY.parent / "ci/postgres-lanes.sh"), "--json"],
        check=True, capture_output=True, text=True, timeout=30,
    )
    return json.loads(response.stdout)["checks"]


def main():
    try:
        expected = expected_checks()
        jobs = run_jobs(
            os.environ["GITHUB_REPOSITORY"],
            os.environ["GITHUB_RUN_ID"],
        )
        refused = refusals(os.environ.get("QUALIFICATION_RESULT"), jobs, expected)
    except (KeyError, OSError, subprocess.SubprocessError, ValueError, TypeError):
        refused = ["qualification inputs or Actions job inventory could not be read"]
    if refused:
        print("Qualification refused:\n  " + "\n  ".join(refused))
        return 1
    print(f"Qualified: all {len(expected)} expected checks completed successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
