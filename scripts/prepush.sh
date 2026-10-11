#!/usr/bin/env bash
# prepush — compile first, then collect every independent gate's result.
#
# Always runs: format, warnings-as-errors compile, release checkers,
# release contract, Credo, deps.audit, the no-database structural suite,
# Dialyzer, docs, and a hex package build.
#
# Live lane: when ASH_REPLICANT_TEST_URL points at a logical-replication
# Postgres (see README "Supported foundation"), also runs ecto
# create/migrate, the migration drift gate, and the FULL live suite —
# exactly the compatibility job's checks — followed by a fresh consumer.
# Load ASH_REPLICANT_TEST_URL from this repo's gitignored .env. For this
# BaseLabs project, the database runs in the BaseLabs cluster.
#
# The dependency selectors (ASH_REPLICANT_ASH_VERSION,
# ASH_REPLICANT_REPLICANT_VERSION, ASH_REPLICANT_ONETIME_VERSION) pass
# through untouched; leave them unset to test the current lock.
set -euo pipefail

labels=()
results=()
exit_codes=()
failed=0
last_status=0

step() {
  local label="$1"
  shift
  printf '\n==> %s\n' "$label"
  if "$@"; then
    last_status=0
    results+=(PASS)
  else
    last_status=$?
    results+=(FAIL)
    failed=$((failed + 1))
  fi
  labels+=("$label")
  exit_codes+=("$last_status")
}

skip() {
  labels+=("$1")
  results+=(SKIP)
  exit_codes+=(-)
}

report() {
  local index
  printf '\n%-36s %-6s %s\n' 'Check' 'Result' 'Exit'
  for index in "${!labels[@]}"; do
    printf '%-36s %-6s %s\n' "${labels[index]}" "${results[index]}" "${exit_codes[index]}"
  done
  if (( failed > 0 )); then
    printf 'prepush: FAIL (%s failed checks)\n' "$failed"
    return 1
  fi
  echo 'prepush: PASS'
}

main() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  export MIX_ENV=test

  # Compilation is the prerequisite for all subsequent checks.
  step "compile (warnings as errors)" \
    env -u ASH_REPLICANT_TEST_URL scripts/with-release-runtime.sh mix compile --warnings-as-errors
  if (( last_status != 0 )); then
    report
    return 1
  fi

  # -------------------------------------------------------------- no-database
  step "format" scripts/with-release-runtime.sh mix format --check-formatted
  step "prepush collector self-tests" scripts/test-prepush.sh
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

  # -------------------------------------------------------------------- live
  if [[ -n "${ASH_REPLICANT_TEST_URL:-}" ]]; then
    step "ecto create" scripts/with-release-runtime.sh mix ecto.create
    if (( last_status == 0 )); then
      step "ecto migrate" scripts/with-release-runtime.sh mix ecto.migrate
      if (( last_status == 0 )); then
        step "migration drift gate" \
          scripts/with-release-runtime.sh scripts/test-migration-drift-gate.sh
        step "full live suite" \
          scripts/with-release-runtime.sh scripts/run-structural-tests.sh --include integration
      else
        skip "migration drift gate"
        skip "full live suite"
      fi
    else
      skip "ecto migrate"
      skip "migration drift gate"
      skip "full live suite"
    fi
    step "fresh consumer" \
      env ASH_REPLICANT_TEST_URL="${ASH_REPLICANT_CONSUMER_TEST_URL:-$ASH_REPLICANT_TEST_URL}" \
      scripts/with-release-runtime.sh scripts/test-fresh-consumer.sh
  else
    echo "prepush: ASH_REPLICANT_TEST_URL unset — skipping the live lane" >&2
  fi

  # ----------------------------------------------------- dev-env release gates
  step "docs" env MIX_ENV=dev scripts/with-release-runtime.sh mix docs --warnings-as-errors
  step "hex package build" \
    env MIX_ENV=dev scripts/with-release-runtime.sh mix hex.build

  report
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
