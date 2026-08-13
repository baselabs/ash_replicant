#!/usr/bin/env bash
set -euo pipefail

resource_file="test/support/resources.ex"
backup_file="$(mktemp "${TMPDIR:-/tmp}/ash-replicant-resources.XXXXXX")"
cp "$resource_file" "$backup_file"

restore_resource() {
  cp "$backup_file" "$resource_file"
  rm -f "$backup_file"
}

trap restore_resource EXIT

check_command=(
  mix run --no-start -e
  'Code.ensure_loaded!(AshPostgres.CustomIndex); Mix.Task.run("ash_postgres.generate_migrations", ["--check", "--domains", "AshReplicant.Test.Domain,AshReplicant.Test.HistoryDomain"])'
)

env MIX_ENV=test "${check_command[@]}"

ASH_REPLICANT_DRIFT_RESOURCE="$resource_file" elixir -e '
  path = System.fetch_env!("ASH_REPLICANT_DRIFT_RESOURCE")
  source = File.read!(path)
  module_marker = "defmodule AshReplicant.Test.OrderVersion do"
  attribute_marker = "  attributes do\n"
  [prefix, module_source] = String.split(source, module_marker, parts: 2)
  [module_prefix, module_rest] = String.split(module_source, attribute_marker, parts: 2)

  mutated =
    prefix <>
      module_marker <>
      module_prefix <>
      attribute_marker <>
      "    attribute :migration_drift_guard_probe, :string, public?: true\n" <>
      module_rest

  File.write!(path, mutated)
'

set +e
drift_output="$(env MIX_ENV=test "${check_command[@]}" 2>&1)"
drift_exit=$?
set -e

restore_resource
trap - EXIT
env MIX_ENV=test mix compile --warnings-as-errors >/dev/null

if [[ "$drift_exit" -eq 0 ]] || [[ "$drift_output" != *"Pending Code Generation"* ]]; then
  echo "migration drift gate did not reject a resource-only mutation" >&2
  exit 1
fi

echo "migration drift gate self-test: PASS"
