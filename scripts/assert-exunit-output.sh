#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "usage: assert-exunit-output.sh OUTPUT_FILE [--allow-excluded]" >&2
  exit 2
fi

output_file="$1"
allow_excluded="${2:-}"

if [[ -n "$allow_excluded" && "$allow_excluded" != "--allow-excluded" ]]; then
  echo "usage: assert-exunit-output.sh OUTPUT_FILE [--allow-excluded]" >&2
  exit 2
fi

if [[ ! -f "$output_file" ]]; then
  echo "ExUnit output file not found: $output_file" >&2
  exit 2
fi

result_count="$(grep -c '^Result: ' "$output_file" || true)"

if [[ "$result_count" -ne 1 ]]; then
  echo "ExUnit evidence must contain exactly one Result line" >&2
  exit 1
fi

result_line="$(grep '^Result: ' "$output_file")"

if [[ -z "$allow_excluded" && "$result_line" =~ ^Result:\ ([1-9][0-9]*)\ passed$ ]]; then
  echo "$result_line"
  exit 0
fi

if [[ "$allow_excluded" == "--allow-excluded" && "$result_line" =~ ^Result:\ ([1-9][0-9]*)\ passed(,\ [1-9][0-9]*\ excluded)?$ ]]; then
  echo "$result_line"
  exit 0
fi

echo "ExUnit evidence is not a positive clean run" >&2
exit 1
