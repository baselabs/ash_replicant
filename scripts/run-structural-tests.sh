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
  # The failure CLASS only (the exception banner's parenthesized token) —
  # value-free by construction: the class names the shape (MatchError,
  # ExUnit.TimeoutError, Postgrex.Error); the banner's message text, which
  # can carry values, is never emitted.
  grep -oE '\*\* \([A-Za-z0-9_.]+\)' "$raw_output" | sort | uniq -c >&2 || true
  # Emit only source locations that resolve to checked-out source files. Error
  # messages and stack-frame arguments remain in the private capture.
  python3 -B - "$raw_output" <<'PYTHON'
from pathlib import Path
import re
import sys

root = Path.cwd()
# Match library-owned templates only. Message suffixes, PIDs, durations and
# exit reasons remain private, including when no known template matches.
pid = r"#PID<[0-9.]+>"
templates = [
    ("client_exited", rf"client {pid} exited(?:$|:)"),
    ("owner_exited", rf"owner {pid} exited(?:$|:)"),
    ("checkout_timeout", rf"client {pid} timed out because it checked out the connection"),
    ("queue_checkout_timeout", rf"client {pid} timed out because it queued and checked out"),
    ("ownership_timeout", rf"owner {pid} timed out because it owned the connection"),
    ("queue_drop", r"connection not available and request was dropped from queue"),
    ("queue_disabled", r"connection not available and queuing is disabled$"),
    ("checked_in", rf"{pid} checked in the connection owned by {pid}"),
    ("tcp_closed", r"tcp (?:recv|send)(?: \([^)]*\))?: closed$"),
    ("ssl_closed", r"ssl (?:recv|send)(?: \([^)]*\))?: closed$"),
]
connection_banner = "** (DBConnection.ConnectionError) "
protocol_emitter = re.compile(
    rf"(?:^|\] )Postgrex\.Protocol \({pid}\) disconnected: "
)
frame = re.compile(
    r"^\s+(?:\(([a-z][a-z0-9_]*) [0-9][^ )]*\) )?"
    r"((?:lib|test|src)/[A-Za-z0-9_./-]+\.(?:ex|exs|erl)):(\d+):"
)
seen = set()
source_lines = {}
with open(sys.argv[1], encoding="utf-8", errors="replace") as capture:
    for line in capture:
        if connection_banner in line:
            prefix, message = line.split(connection_banner, 1)
            template = next(
                (name for name, pattern in templates if re.match(pattern, message.rstrip("\n"))),
                "unknown",
            )
            emitter = "postgrex_protocol" if protocol_emitter.search(prefix) else "other"
            print(f"CONNECTION-ERROR: template={template} emitter={emitter}", file=sys.stderr)
        match = frame.match(line)
        if not match:
            continue
        package, file, number = match.groups()
        if ".." in Path(file).parts or len(number) > 6:
            continue
        relative = Path(file) if package in (None, "ash_replicant") else Path("deps", package, file)
        if not (root / relative).is_file():
            continue
        if relative not in source_lines:
            with (root / relative).open(encoding="utf-8", errors="replace") as source:
                source_lines[relative] = sum(1 for _line in source)
        number = int(number)
        if not 1 <= number <= source_lines[relative]:
            continue
        site = f"{relative}:{number}"
        if site not in seen:
            print(f"ERROR-SITE: {site}", file=sys.stderr)
            seen.add(site)
PYTHON
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

# The decoder lanes need a separate source. Match the helper's module
# exclusion so the result checker admits the ordinary suite's excluded tests.
decoder_source_excluded=0
if [[ "${ASH_REPLICANT_DECODER_SOURCE_URL:-}" == "" ]]; then
  mix_args+=("--exclude" "decoder_source")
  decoder_source_excluded=1
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
if [[ "$performance_excluded" -eq 1 || "$decoder_source_excluded" -eq 1 ]] && [[ -z "$allow_excluded" ]]; then
  allow_excluded="--allow-excluded"
fi

test_exit=0
mix test "${mix_args[@]}" --formatter AshReplicant.StructuralFormatter >"$raw_output" 2>&1 || test_exit=$?

result_exit=0
scripts/assert-exunit-output.sh "$raw_output" ${allow_excluded:+"$allow_excluded"} || result_exit=$?

logger_error_count="$(grep -Ec '(^|[[:space:]])\[error\]' "$raw_output")" || [[ $? -eq 1 ]]
exception_banner_count="$(grep -Ec '\*\* \(' "$raw_output")" || [[ $? -eq 1 ]]

if [[ "$logger_error_count" -gt 0 || "$exception_banner_count" -gt 0 ]]; then
  echo "test process emitted uncontrolled structural errors: logger=$logger_error_count exception=$exception_banner_count" >&2
  preserve_failure
  exit 1
fi

if [[ "$test_exit" -ne 0 || "$result_exit" -ne 0 ]]; then
  echo "structural test run failed ($(grep '^Result: ' "$raw_output" || true))" >&2
  preserve_failure
  exit 1
fi
