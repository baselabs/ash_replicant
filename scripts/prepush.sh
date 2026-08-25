#!/usr/bin/env bash
# prepush — one fail-fast command for every gate CI runs, in cheapest-first
# order, so a red push costs seconds locally instead of a CI round-trip.
#
# Always runs: format, warnings-as-errors compile, release checkers,
# release contract, Credo, deps.audit, the no-database structural suite,
# Dialyzer, docs, and a hex package build.
#
# Live lane: when ASH_REPLICANT_TEST_URL points at a logical-replication
# Postgres (see README "Supported foundation"), also runs ecto
# create/migrate, the migration drift gate, and the FULL live suite —
# exactly the compatibility job's steps. Set
# ASH_REPLICANT_TEST_URL=postgres://postgres@localhost:5599/postgres for
# the conventional local instance.
#
# The dependency selectors (ASH_REPLICANT_ASH_VERSION,
# ASH_REPLICANT_REPLICANT_VERSION, ASH_REPLICANT_ONETIME_VERSION) pass
# through untouched; leave them unset to test the current lock.
set -euo pipefail

cd "$(dirname "$0")/.."

step() {
  local label="$1"
  shift
  printf '\n==> %s\n' "$label"
  "$@"
}

export MIX_ENV=test

# ---------------------------------------------------------------- no-database
step "format" scripts/with-release-runtime.sh mix format --check-formatted
step "compile (warnings as errors)" \
  env -u ASH_REPLICANT_TEST_URL scripts/with-release-runtime.sh mix compile --warnings-as-errors
step "release checkers" \
  env -u ASH_REPLICANT_TEST_URL scripts/with-release-runtime.sh scripts/test-release-checkers.sh
step "release contract" \
  env -u ASH_REPLICANT_TEST_URL scripts/with-release-runtime.sh scripts/test-release-contract.sh
step "credo --strict" \
  env -u ASH_REPLICANT_TEST_URL scripts/with-release-runtime.sh mix credo --strict
step "deps.audit" \
  env -u ASH_REPLICANT_TEST_URL scripts/with-release-runtime.sh mix deps.audit
step "structural suite (no database)" \
  env -u ASH_REPLICANT_TEST_URL \
    scripts/with-release-runtime.sh scripts/run-structural-tests.sh \
    --allow-excluded --exclude integration
step "dialyzer" \
  env -u ASH_REPLICANT_TEST_URL scripts/with-release-runtime.sh mix dialyzer

# ---------------------------------------------------------------------- live
if [[ -n "${ASH_REPLICANT_TEST_URL:-}" ]]; then
  step "ecto create" scripts/with-release-runtime.sh mix ecto.create
  step "ecto migrate" scripts/with-release-runtime.sh mix ecto.migrate
  step "migration drift gate" \
    scripts/with-release-runtime.sh scripts/test-migration-drift-gate.sh
  step "full live suite" \
    scripts/with-release-runtime.sh scripts/run-structural-tests.sh --include integration
else
  echo "prepush: ASH_REPLICANT_TEST_URL unset — skipping the live lane" >&2
fi

# ------------------------------------------------------- dev-env release gates
step "docs" env MIX_ENV=dev scripts/with-release-runtime.sh mix docs --warnings-as-errors
step "hex package build" \
  env MIX_ENV=dev scripts/with-release-runtime.sh mix hex.build

echo "prepush: PASS"
