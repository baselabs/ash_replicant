#!/usr/bin/env bash
set -euo pipefail

raw_output="$(mktemp "${TMPDIR:-/tmp}/ash-replicant-test-output.XXXXXX")"
trap 'rm -f "$raw_output"' EXIT

# Failure diagnosis stays VALUE-FREE: raw captured output may carry unscrubbed
# values (that is what the gate exists to catch), so a trip PRESERVES the
# capture to a local file and reports structural facts only — counts, the
# Result line, the preserved path. Never dump raw lines into CI logs.
preserve_failure() {
  preserved="${TMPDIR:-/tmp}/ash-replicant-structural-failure.$$.log"
  mv "$raw_output" "$preserved"
  echo "raw output preserved at: $preserved" >&2
}

allow_excluded=""
mix_args=()

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
