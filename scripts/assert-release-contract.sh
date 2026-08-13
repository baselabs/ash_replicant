#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--check" ]]; then
  exec scripts/test-release-contract.sh
fi

contract_root="${1:-.}"

release_script="scripts/assert_release_contract.exs"

if ! validator_output="$(
  ASH_REPLICANT_RELEASE_CONTRACT_SCRIPT="$release_script" \
    mix run --no-start --no-compile --no-deps-check -e '
      Code.require_file(System.fetch_env!("ASH_REPLICANT_RELEASE_CONTRACT_SCRIPT"))
      [root] = System.argv()
      result = AshReplicant.ReleaseContract.run_cli(root)
      System.halt(if result == :ok, do: 0, else: 1)
    ' -- "$contract_root" 2>&1
)"; then
  echo "release contract validation failed" >&2
  exit 1
fi

if [[ -n "$validator_output" ]]; then
  echo "release contract validator emitted diagnostics" >&2
  exit 1
fi

echo "release contract: PASS"
