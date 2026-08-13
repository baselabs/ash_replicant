#!/usr/bin/env bash
set -euo pipefail

resource_file="test/support/resources.ex"
probe_line="    attribute :migration_drift_guard_probe, :string, public?: true"

restore_resource() {
  PROBE_LINE="$probe_line" RESOURCE_FILE="$resource_file" perl -0pi -e '
    BEGIN {
      $probe = quotemeta($ENV{"PROBE_LINE"});
    }
    s/^$probe\n//m;
  ' "$resource_file"
}

trap restore_resource EXIT

check_command=(
  mix run --no-start -e
  'Code.ensure_loaded!(AshPostgres.CustomIndex); Mix.Task.run("ash_postgres.generate_migrations", ["--check", "--domains", "AshReplicant.Test.Domain,AshReplicant.Test.HistoryDomain"])'
)

env MIX_ENV=test "${check_command[@]}"

ASH_REPLICANT_DRIFT_RESOURCE="$resource_file" \
ASH_REPLICANT_DRIFT_PROBE="$probe_line" \
  elixir -e '
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
      System.fetch_env!("ASH_REPLICANT_DRIFT_PROBE") <> "\n" <>
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
