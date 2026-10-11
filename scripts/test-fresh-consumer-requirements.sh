#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for mode in run check; do
  args=(--from-hex 1.6.2)
  [[ "$mode" == check ]] && args+=(--check)
  if output="$(env -u ASH_REPLICANT_TEST_URL "$root/scripts/test-fresh-consumer.sh" "${args[@]}" 2>&1)"; then
    echo "fresh consumer accepted an unset database URL ($mode)" >&2
    exit 1
  fi
  [[ "$output" == *'ASH_REPLICANT_TEST_URL is required in --from-hex mode'* ]] || { echo "$output" >&2; exit 1; }
  echo "fresh-consumer: RED — missing live database URL ($mode)"
done
echo 'fresh consumer requirement self-tests: PASS (2 checks)'
