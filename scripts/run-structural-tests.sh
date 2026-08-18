#!/usr/bin/env bash
set -euo pipefail

raw_output="$(mktemp "${TMPDIR:-/tmp}/ash-replicant-test-output.XXXXXX")"
trap 'rm -f "$raw_output"' EXIT

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
  echo "test process emitted an uncontrolled structural error" >&2
  # Surface the offending lines (the raw output is trap-deleted; without
  # this the trip is undiagnosable when the flake does not re-reproduce).
  grep -E '(^|[[:space:]])\[error\]|\*\* \(' "$raw_output" | head -5 >&2
  exit 1
fi

if [[ "$test_exit" -ne 0 || "$result_exit" -ne 0 ]]; then
  echo "structural test run failed" >&2
  # Surface the result line + tail (the raw capture is trap-deleted; without
  # this an intermittent failure is undiagnosable when it does not re-reproduce).
  tail -20 "$raw_output" >&2
  exit 1
fi
