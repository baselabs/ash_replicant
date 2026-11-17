#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# This fixture is recorded checker input, never a dependency-fetch target.
mix deps.audit --path test/fixtures/release_checker
(cd test/fixtures/release_checker && mix hex.audit)

# Match upgrade_checkpoint_test.exs: the real consumer inherits the root lock.
fixture="$(mktemp -d "${RUNNER_TEMP:?}/ash-replicant-upgrade-audit.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
cp -R test/fixtures/upgrade_0_4_app/. "$fixture/"
cp mix.lock "$fixture/mix.lock"
export ASH_REPLICANT_PATH="$root"
(cd "$fixture" && mix deps.get --check-locked && mix hex.audit)
mix deps.audit --path "$fixture"
