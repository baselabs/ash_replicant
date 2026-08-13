#!/usr/bin/env bash
set -euo pipefail

output_file="${1:?usage: assert-exunit-output.sh OUTPUT_FILE}"

if [[ ! -f "$output_file" ]]; then
  echo "ExUnit output file not found: $output_file" >&2
  exit 2
fi

result_line="$(awk '/^Result: / { result = $0 } END { print result }' "$output_file")"

if [[ ! "$result_line" =~ ^Result:\ ([1-9][0-9]*)\ passed$ ]]; then
  echo "ExUnit evidence is not a positive clean run: ${result_line:-missing Result line}" >&2
  exit 1
fi

echo "$result_line"
