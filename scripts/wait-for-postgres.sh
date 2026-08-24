#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 3 ]]; then
  echo "usage: wait-for-postgres.sh CONTAINER [ATTEMPTS [INTERVAL_SECONDS]]" >&2
  exit 2
fi

container="$1"
attempts="${2:-30}"
interval_seconds="${3:-1}"

if [[ ! "$attempts" =~ ^[1-9][0-9]*$ ]] ||
  [[ ! "$interval_seconds" =~ ^([0-9]+)(\.[0-9]+)?$ ]]; then
  echo "PostgreSQL readiness input is invalid" >&2
  exit 2
fi

ready_streak=0

for _ in $(seq 1 "$attempts"); do
  if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then
    ready_streak=$((ready_streak + 1))

    if [[ "$ready_streak" -eq 2 ]]; then
      exit 0
    fi
  else
    ready_streak=0
  fi

  sleep "$interval_seconds"
done

docker logs "$container" >&2
exit 1
