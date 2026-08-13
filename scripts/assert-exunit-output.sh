#!/usr/bin/env bash
set -euo pipefail

output_file="${1:?usage: assert-exunit-output.sh OUTPUT_FILE}"

if [[ ! -f "$output_file" ]]; then
  echo "ExUnit output file not found: $output_file" >&2
  exit 2
fi

mapfile -t result_lines < <(grep '^Result: ' "$output_file" || true)

if [[ "${#result_lines[@]}" -ne 1 ]]; then
  echo "ExUnit evidence must contain exactly one Result line" >&2
  exit 1
fi

result_line="${result_lines[0]}"

if [[ ! "$result_line" =~ ^Result:\ ([1-9][0-9]*)\ passed$ ]]; then
  echo "ExUnit evidence is not a positive clean run" >&2
  exit 1
fi

echo "$result_line"
