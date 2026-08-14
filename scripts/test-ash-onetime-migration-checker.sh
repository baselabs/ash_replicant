#!/usr/bin/env bash
set -euo pipefail

source_root="$(pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-onetime-migration.XXXXXX")"
fixture_migrations="$fixture_root/priv/repo/migrations"
filename="20260814000000_install_ash_onetime.exs"
trap 'rm -rf "$fixture_root"' EXIT

check_contract() {
  local root="$1"

  ASH_REPLICANT_ONETIME_MIGRATION_ROOT="$root" \
    MIX_ENV=test mix run --no-start --no-compile --no-deps-check -e '
      Code.require_file("scripts/assert-ash-onetime-migration.exs")
      AshReplicant.AshOnetimeMigrationContract.run!(
        System.fetch_env!("ASH_REPLICANT_ONETIME_MIGRATION_ROOT")
      )
    '
}

check_contract "$source_root"

mkdir -p "$fixture_migrations"
cp "priv/repo/migrations/$filename" "$fixture_migrations/$filename"

ASH_REPLICANT_ONETIME_FIXTURE="$fixture_migrations/$filename" elixir -e '
  path = System.fetch_env!("ASH_REPLICANT_ONETIME_FIXTURE")
  source = File.read!(path)
  old = "CREATE INDEX ash_onetime_idempotency_claims_retain_until_index"
  new = "CREATE INDEX ash_onetime_idempotency_claims_retention_index"

  unless length(:binary.matches(source, old)) == 1 do
    raise "AshOnetime migration mutation anchor is not unique"
  end

  File.write!(path, String.replace(source, old, new))
'

if check_contract "$fixture_root" >/dev/null 2>&1; then
  echo "AshOnetime migration checker accepted mutated SQL" >&2
  exit 1
fi

cp "priv/repo/migrations/$filename" "$fixture_migrations/$filename"
check_contract "$fixture_root"

echo "AshOnetime migration checker self-test: PASS"
