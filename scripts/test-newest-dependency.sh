#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$root/test/fixtures/release_checker"
checker="$root/scripts/assert-dependency-version.sh"
cd "$fixture"
# Replay the recorded Hex API response and lock, independent of new releases.
"$checker" --newest --hex-response "$fixture/ash.json" ash '>= 3.34.6 and < 4.0.0-0'
"$checker" --newest --hex-response "$fixture/replicant.json" replicant '>= 1.4.0 and < 1.5.1'
if output="$("$checker" --newest --hex-response "$fixture/replicant.json" replicant '>= 1.4.0 and < 2.0.0-0' 2>&1)"; then
  echo 'newest checker accepted the older recorded Replicant lock' >&2
  exit 1
fi
[[ "$output" == *'locked 1.4.2 differs from newest compatible Hex release 1.5.1'* ]] || { echo "$output" >&2; exit 1; }
echo "newest checker: RED — $output"
for defect in network http empty malformed; do
  body="$fixture/replicant.json"
  transport=0
  status=200
  case "$defect" in
    network) transport=7 ;;
    http) status=503 ;;
    empty) body="$fixture/empty.json" ;;
    malformed) body="$fixture/malformed.json" ;;
  esac
  if output="$(python3 "$root/scripts/hex-release-candidates.py" "$body" "$transport" "$status" 2>&1)"; then
    echo "Hex response checker accepted $defect" >&2
    exit 1
  fi
  [[ "$output" == 'Hex response rejected:'* ]] || { echo "$output" >&2; exit 1; }
  echo "newest checker: RED — $defect: $output"
done
echo 'newest checker self-tests: PASS (7 checks, recorded offline inputs)'
