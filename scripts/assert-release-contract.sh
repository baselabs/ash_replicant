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

if grep -Eq 'uses: [^[:space:]]+@(v[0-9]+|main|master)([[:space:]]|$)' "$workflow"; then
  echo "CI contains a mutable Action reference" >&2
  exit 1
fi

# The GitHub expression is intentionally literal input to grep.
# shellcheck disable=SC2016
for required_pattern in \
  'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' \
  'actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830' \
  'erlef/setup-beam@0f75c29430f34bb5af4cce5e3b7f6a8860fca236' \
  'postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b' \
  'label: floor-3.31.3' \
  'label: current-lock' \
  'label: latest-3.x' \
  'key: ${{ runner.os }}-ash-${{ matrix.label }}' \
  'scripts/run-structural-tests.sh --allow-excluded --exclude integration' \
  'scripts/run-structural-tests.sh --include integration' \
  'scripts/run-structural-tests.sh test/integration --include integration' \
  'scripts/test-migration-drift-gate.sh' \
  'scripts/assert-runtime-version.sh' \
  'scripts/test-release-checkers.sh'; do
  if ! grep -Fq "$required_pattern" "$workflow"; then
    echo "CI release contract is incomplete" >&2
    exit 1
  fi
done

if [[ "$(grep -Fc 'mix deps.audit' "$workflow")" -lt 2 ]]; then
  echo "CI dependency audits are incomplete" >&2
  exit 1
fi

if grep -Eq 'Elixir 1\.1[0-9]|OTP 2[0-8]|PostgreSQL 14\+|replicant.*~> 0\.1|>= 3\.31\.[12]' \
  "$contract_root/README.md" "$contract_root/CONTRIBUTING.md" "$contract_root/AGENTS.md"; then
  echo "published runtime or dependency contract is stale" >&2
  exit 1
fi

for required_pattern in \
  'Elixir 1.20.3' \
  'Erlang/OTP 29' \
  '>= 3.31.3 and < 4.0.0-0'; do
  if ! grep -Fq "$required_pattern" "$contract_root/README.md" "$contract_root/CONTRIBUTING.md"; then
    echo "published runtime or dependency contract is incomplete" >&2
    exit 1
  fi
done

echo "release contract: PASS"
