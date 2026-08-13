#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--check" ]]; then
  shift
fi

if ! result="$(
  MIX_ENV="${MIX_ENV:-dev}" mix run --no-start --no-compile --no-deps-check -e '
    Code.require_file("scripts/test_release_contract.exs")
  ' 2>&1
)"; then
  echo "release contract self-tests failed" >&2
  exit 1
fi

normalized_result="$(
  printf '%s\n' "$result" |
    sed $'s/\033\\[[0-9;]*m//g' |
    sed '/^Waiting for lock on the build directory /d'
)"

[[ "$normalized_result" == "release contract self-tests: PASS" ]]
printf '%s\n' "$normalized_result"
