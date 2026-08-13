#!/usr/bin/env bash
set -euo pipefail

contract_root="${1:-.}"
workflow="$contract_root/.github/workflows/ci.yml"

required_files=(
  "$workflow"
  "$contract_root/README.md"
  "$contract_root/CONTRIBUTING.md"
  "$contract_root/AGENTS.md"
  "$contract_root/mix.exs"
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "release contract file is missing" >&2
    exit 1
  fi
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required for release contract validation" >&2
  exit 2
fi

WORKFLOW="$workflow" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

workflow = Path(os.environ["WORKFLOW"]).read_text(encoding="utf-8")

uses = re.findall(
    r"(?:^|[,{\s-])[\"']?uses[\"']?\s*:\s*([^,\s}#]+)",
    workflow,
    re.MULTILINE,
)
if not uses or any(not re.fullmatch(r"[^@]+@[0-9a-f]{40}", value) for value in uses):
    sys.stderr.write("CI contains a non-immutable Action reference\n")
    raise SystemExit(1)

job_matches = list(re.finditer(r"^  ([a-z][a-z0-9-]+):\n", workflow, re.MULTILINE))
jobs = {}
for index, match in enumerate(job_matches):
    end = job_matches[index + 1].start() if index + 1 < len(job_matches) else len(workflow)
    jobs[match.group(1)] = workflow[match.start():end]

required_jobs = {"no-database", "compatibility", "release-artifact"}
if not required_jobs.issubset(jobs):
    sys.stderr.write("CI release jobs are incomplete\n")
    raise SystemExit(1)

def command_position(job, command):
    match = re.search(
        rf"^\s*(?:-\s*run:\s*)?{re.escape(command)}\s*$",
        job,
        re.MULTILINE,
    )
    return -1 if match is None else match.start()

def ordered_commands(job, *commands):
    position = -1
    for command in commands:
        next_position = command_position(job[position + 1:], command)
        if next_position < 0:
            return False
        position += next_position + 1
    return True

checks = [
    ordered_commands(
        jobs["no-database"],
        "mix compile --warnings-as-errors",
        "scripts/test-release-checkers.sh",
        "scripts/test-release-contract.sh",
    ),
    ordered_commands(
        jobs["compatibility"],
        "mix compile --warnings-as-errors",
        "scripts/test-release-checkers.sh",
        "scripts/assert-release-contract.sh",
    ),
    ordered_commands(
        jobs["release-artifact"],
        "mix compile --warnings-as-errors",
        "scripts/assert-runtime-version.sh",
        "scripts/assert-release-contract.sh",
    ),
    re.search(r"^\s*run:\s*mix deps\.audit\s*$", jobs["no-database"], re.MULTILINE),
    re.search(r"^\s*run:\s*mix deps\.audit\s*$", jobs["compatibility"], re.MULTILINE),
    re.search(
        r"^\s*ASH_REPLICANT_ASH_VERSION:\s*\$\{\{ matrix\.selector \}\}\s*$",
        jobs["compatibility"],
        re.MULTILINE,
    ),
    command_position(jobs["compatibility"], "if [[ '${{ matrix.unlock }}' == 'true' ]]; then") >= 0,
    command_position(jobs["compatibility"], "mix deps.unlock ash") >= 0,
    command_position(jobs["compatibility"], "scripts/assert-dependency-version.sh ash '${{ matrix.requirement }}'") >= 0,
]

matrix_tuples = [
    ("floor-3.31.3", '"3.31.3"', "true", '"== 3.31.3"'),
    ("current-lock", '""', "false", '">= 3.31.3 and < 4.0.0-0"'),
    ("latest-3.x", "latest", "true", '">= 3.31.3 and < 4.0.0-0"'),
]
for label, selector, unlock, requirement in matrix_tuples:
    pattern = (
        rf"- label: {re.escape(label)}\n"
        rf"\s+selector: {re.escape(selector)}\n"
        rf"\s+unlock: {unlock}\n"
        rf"\s+requirement: {re.escape(requirement)}"
    )
    checks.append(re.search(pattern, jobs["compatibility"]))

if not all(checks):
    sys.stderr.write("CI release contract structure is incomplete\n")
    raise SystemExit(1)
PY

# The GitHub expression is intentionally literal input to grep.
# shellcheck disable=SC2016
for required_pattern in \
  'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' \
  'actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830' \
  'erlef/setup-beam@0f75c29430f34bb5af4cce5e3b7f6a8860fca236' \
  'postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b' \
  'key: ${{ runner.os }}-ash-${{ matrix.label }}' \
  'scripts/run-structural-tests.sh --allow-excluded --exclude integration' \
  'scripts/run-structural-tests.sh --include integration' \
  'scripts/run-structural-tests.sh test/integration --include integration' \
  'scripts/test-migration-drift-gate.sh' \
  'scripts/assert-runtime-version.sh'; do
  if ! grep -Fq "$required_pattern" "$workflow"; then
    echo "CI release contract is incomplete" >&2
    exit 1
  fi
done

if grep -Eq 'Elixir 1\.1[0-9]|OTP 2[0-8]|PostgreSQL 14\+|replicant.*~> 0\.1|>= 3\.31\.[12]|unsupported release foundation' \
  "$contract_root/README.md" "$contract_root/CONTRIBUTING.md" "$contract_root/AGENTS.md"; then
  echo "published runtime or dependency contract is stale" >&2
  exit 1
fi

README="$contract_root/README.md" \
CONTRIBUTING="$contract_root/CONTRIBUTING.md" \
AGENTS="$contract_root/AGENTS.md" \
  python3 - <<'PY'
import os
import sys
from pathlib import Path

contracts = {
    "README": (
        "- Elixir 1.20.3 on Erlang/OTP 29;",
        "- Ash `>= 3.31.3 and < 4.0.0-0` and AshPostgres 2.11.x;",
    ),
    "CONTRIBUTING": (
        "- **Elixir 1.20.3** and **Erlang/OTP 29**",
        "- Ash `>= 3.31.3 and < 4.0.0-0`; selector-free development uses this public range",
        "- **Python 3** for release-contract validation",
    ),
    "AGENTS": (
        "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n"
        "`>= 3.31.3 and < 4.0.0-0`.",
        "Python 3 is required by the release-contract checker.",
    ),
}

for name, required_texts in contracts.items():
    content = Path(os.environ[name]).read_text(encoding="utf-8")
    if any(required not in content for required in required_texts):
        sys.stderr.write("published runtime or dependency contract is incomplete\n")
        raise SystemExit(1)
PY

echo "release contract: PASS"
