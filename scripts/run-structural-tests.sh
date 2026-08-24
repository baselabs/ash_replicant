#!/usr/bin/env bash
set -euo pipefail

raw_output="$(mktemp "${TMPDIR:-/tmp}/ash-replicant-test-output.XXXXXX")"
trap 'rm -f "$raw_output"' EXIT

# Failure diagnosis stays VALUE-FREE: raw captured output may carry unscrubbed
# values (that is what the gate exists to catch), so a trip PRESERVES the
# capture to a local file and reports structural facts only — counts, the
# Result line, authored test names (the formatter's FAILED: lines), the
# preserved path. Never dump raw lines into CI logs.
preserve_failure() {
  preserved="${TMPDIR:-/tmp}/ash-replicant-structural-failure.$$.log"
  grep '^FAILED: ' "$raw_output" >&2 || true
  grep '^CONSUMER-COMMAND: ' "$raw_output" >&2 || true
  mv "$raw_output" "$preserved"
  echo "raw output preserved at: $preserved" >&2
}

allow_excluded=""
mix_args=()

# The performance-bound legs are excluded by default (heavy load that
# destabilizes timing-sensitive suites when run inside the full battery);
# local full batteries opt in automatically, CI opts in per-job via
# ASH_REPLICANT_PERFORMANCE=1 (the dedicated performance job). The CLI
# --exclude is required even though test_helper excludes the tag: an
# --include on the command line lifts configure-excludes for tests
# carrying BOTH tags (the module is :integration AND :performance).
performance_default="$([ -z "${GITHUB_ACTIONS:-}" ] && [ -n "${ASH_REPLICANT_TEST_URL:-}" ] && echo 1 || echo 0)"

performance_excluded=0

if [[ "${ASH_REPLICANT_PERFORMANCE:-$performance_default}" == "1" ]]; then
  mix_args+=("--include" "performance")
else
  mix_args+=("--exclude" "performance")
  performance_excluded=1
fi

for argument in "$@"; do
  if [[ "$argument" == "--allow-excluded" ]]; then
    if [[ -n "$allow_excluded" ]]; then
      echo "--allow-excluded may be specified only once" >&2
      exit 2
    fi

    allow_excluded="--allow-excluded"
  else
    mix_args+=("$argument")
  fi
done

# The default performance exclusion puts ', N excluded' on the Result line;
# the evidence gate accepts that ONLY with --allow-excluded, so the runner
# owns the flag whenever it owns the exclusion (an explicit pass wins first).
if [[ "$performance_excluded" -eq 1 && -z "$allow_excluded" ]]; then
  allow_excluded="--allow-excluded"
fi

test_exit=0
mix test "${mix_args[@]}" --formatter AshReplicant.StructuralFormatter >"$raw_output" 2>&1 || test_exit=$?

result_exit=0
scripts/assert-exunit-output.sh "$raw_output" ${allow_excluded:+"$allow_excluded"} || result_exit=$?

if grep -Eq '(^|[[:space:]])\[error\]|\*\* \(' "$raw_output"; then
  count="$(grep -Ec '(^|[[:space:]])\[error\]|\*\* \(' "$raw_output")"
  echo "test process emitted an uncontrolled structural error ($count line(s))" >&2
  preserve_failure
  exit 1
fi

if [[ "$test_exit" -ne 0 || "$result_exit" -ne 0 ]]; then
  echo "structural test run failed ($(grep '^Result: ' "$raw_output" || true))" >&2
  preserve_failure
  exit 1
fi
