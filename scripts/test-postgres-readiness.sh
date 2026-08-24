#!/usr/bin/env bash
set -euo pipefail

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-postgres-readiness.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

mkdir -p "$fixture_dir/bin"
sequence_file="$fixture_dir/sequence"
calls_file="$fixture_dir/calls"

# The single quotes intentionally defer every expansion to the generated fake.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'case "${1:-}" in' \
  '  exec)' \
  '    response="$(head -n 1 "$ASH_REPLICANT_READY_SEQUENCE")"' \
  '    tail -n +2 "$ASH_REPLICANT_READY_SEQUENCE" > "$ASH_REPLICANT_READY_SEQUENCE.next"' \
  '    mv "$ASH_REPLICANT_READY_SEQUENCE.next" "$ASH_REPLICANT_READY_SEQUENCE"' \
  '    printf "exec\n" >> "$ASH_REPLICANT_READY_CALLS"' \
  '    exit "$response"' \
  '    ;;' \
  '  logs)' \
  '    printf "logs\n" >> "$ASH_REPLICANT_READY_CALLS"' \
  '    exit 0' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$fixture_dir/bin/docker"

chmod +x "$fixture_dir/bin/docker"

run_probe() {
  PATH="$fixture_dir/bin:$PATH" \
  ASH_REPLICANT_READY_SEQUENCE="$sequence_file" \
  ASH_REPLICANT_READY_CALLS="$calls_file" \
    scripts/wait-for-postgres.sh pg 5 0 >/dev/null 2>&1
}

# The first success is the official image's temporary bootstrap server. The
# checker must reset after the shutdown and accept only the final server's two
# consecutive successful probes.
printf '0\n1\n0\n0\n' > "$sequence_file"
: > "$calls_file"

if ! run_probe; then
  echo "PostgreSQL readiness checker rejected the stable final server" >&2
  exit 1
fi

if [[ "$(grep -c '^exec$' "$calls_file")" -ne 4 ]] || grep -q '^logs$' "$calls_file"; then
  echo "PostgreSQL readiness checker did not wait through the bootstrap restart" >&2
  exit 1
fi

# Isolated successes never establish a stable server. Exhaustion must fail and
# surface the container logs once for diagnosis.
printf '0\n1\n0\n1\n0\n' > "$sequence_file"
: > "$calls_file"

if run_probe; then
  echo "PostgreSQL readiness checker accepted isolated transient successes" >&2
  exit 1
fi

if [[ "$(grep -c '^exec$' "$calls_file")" -ne 5 ]] ||
  [[ "$(grep -c '^logs$' "$calls_file")" -ne 1 ]]; then
  echo "PostgreSQL readiness checker failure path is incomplete" >&2
  exit 1
fi

echo "PostgreSQL readiness self-test: PASS"
