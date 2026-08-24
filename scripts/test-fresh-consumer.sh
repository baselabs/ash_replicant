#!/usr/bin/env bash
set -euo pipefail

# PKG02 / D8: prove a FRESH consumer from the unpacked release candidate.
# Builds the hex package, unpacks it as the ONLY dependency source of a
# scratch mix project (nothing from this repo's checkout is on the
# consumer's path), then runs the adopter's first hour: deps resolve,
# compile with warnings-as-errors, docs, ash.codegen + ecto.migrate, and
# a default live CDC smoke (a source insert mirrored through the real
# pipeline) against $ASH_REPLICANT_TEST_URL's server. Skipped (named)
# when no live URL is set — the consumer smoke is live-only by definition.

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-fresh-consumer.XXXXXX")"
trap 'rm -rf "$work"' EXIT

url="${ASH_REPLICANT_TEST_URL:-}"
if [ -z "$url" ]; then
  echo "fresh-consumer: SKIP — no ASH_REPLICANT_TEST_URL (the consumer smoke is live-only)"
  exit 0
fi

consumer="$work/consumer"
vendor="$consumer/vendor/ash_replicant"

echo "== building the release package =="
tarball="$work/ash_replicant-release.tar"
(cd "$root" && MIX_ENV=test mix hex.build --output "$tarball" >/dev/null)
[ -s "$tarball" ] || { echo "fresh-consumer: FAIL — no package built"; exit 1; }

echo "== unpacking the tarball as the consumer's only dependency source =="
# A hex package is a wrapper tar (VERSION, metadata, contents.tar.gz);
# the consumer consumes the INNER tree.
mkdir -p "$vendor" "$work/outer"
tar -xf "$tarball" -C "$work/outer"
tar -xzf "$work/outer/contents.tar.gz" -C "$vendor"
[ -f "$vendor/mix.exs" ] && [ -d "$vendor/lib" ] || {
  echo "fresh-consumer: FAIL — tarball shape unexpected"; exit 1
}

echo "== scaffolding the scratch consumer =="
mkdir -p "$consumer/lib" "$consumer/config"

cat > "$consumer/mix.exs" <<'MIX'
defmodule FreshConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :fresh_consumer,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: deps(),
      docs: []
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:ash_replicant, path: Path.expand("#{__DIR__}/vendor/ash_replicant")},
      {:ex_doc, "~> 0.37", only: :dev, runtime: false}
    ]
  end
end
MIX

cat > "$consumer/config/config.exs" <<'CONF'
import Config

# The consumer's database is dedicated to this check; host/port/user come
# from the same env var CI and the local gate use.
url =
  System.fetch_env!("ASH_REPLICANT_TEST_URL")
  |> URI.parse()
  |> Map.put(:path, "/ash_replicant_consumer_check")
  |> URI.to_string()

config :fresh_consumer, ecto_repos: [FreshConsumer.Repo]
config :fresh_consumer, FreshConsumer.Repo, url: url, pool_size: 5
config :fresh_consumer, ash_domains: [FreshConsumer.Domain]
config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false
CONF

cat > "$consumer/lib/repo.ex" <<'REPO'
defmodule FreshConsumer.Repo do
  use AshPostgres.Repo, otp_app: :fresh_consumer

  def installed_extensions, do: ["ash-functions"]
  def min_pg_version, do: %Version{major: 0, minor: 0, patch: 0}
end
REPO

cat > "$consumer/lib/order.ex" <<'ORDER'
defmodule FreshConsumer.Order do
  use Ash.Resource,
    domain: FreshConsumer.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "consumer_orders"
    repo FreshConsumer.Repo
  end

  replicant do
    source_table("consumer_src_orders")
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :create do
      primary? true
      accept [:id, :note]
    end
  end
end
ORDER

cat > "$consumer/lib/domain.ex" <<'DOMAIN'
defmodule FreshConsumer.Domain do
  use Ash.Domain

  resources do
    resource FreshConsumer.Order
    resource FreshConsumer.Checkpoint
  end
end
DOMAIN

cat > "$consumer/lib/checkpoint.ex" <<'CHECKPOINT'
defmodule FreshConsumer.Checkpoint do
  use AshReplicant.Checkpoint,
    repo: FreshConsumer.Repo,
    domain: FreshConsumer.Domain
end
CHECKPOINT

cat > "$consumer/lib/sink.ex" <<'SINK'
defmodule FreshConsumer.Sink do
  use AshReplicant.Sink,
    repo: FreshConsumer.Repo,
    domains: [FreshConsumer.Domain],
    checkpoint_resource: FreshConsumer.Checkpoint,
    slot_name: "fresh_consumer_slot"
end
SINK

cat > "$consumer/smoke.exs" <<'SMOKE'
# The default live CDC smoke, run inside the consumer: the replicated
# source table + publication, one pipeline start, one source insert, and
# the mirrored row asserted back through the consumer's own repo —
# everything from the unpacked package. The database itself is created
# by setup_db.exs BEFORE the migrations; this file only consumes it.
uri = System.fetch_env!("ASH_REPLICANT_TEST_URL") |> URI.parse()

{:ok, _} = FreshConsumer.Repo.start_link()

_ = FreshConsumer.Repo.query!(
    "CREATE TABLE consumer_src_orders (id text primary key, note text)"
  )

_ = FreshConsumer.Repo.query!("DROP PUBLICATION IF EXISTS fresh_consumer_pub")
_ = FreshConsumer.Repo.query!("CREATE PUBLICATION fresh_consumer_pub FOR TABLE consumer_src_orders")

[[system_identifier, current_database]] =
  FreshConsumer.Repo.query!("SELECT system_identifier::text, current_database() FROM pg_control_system()").rows

self_pid = self()

:telemetry.attach(
  :consumer_slot_active,
  [:replicant, :connection, :slot_active],
  fn _e, _m, _meta, _c -> send(self_pid, :active) end,
  nil
)

:telemetry.attach_many(
  :consumer_debug,
  [
    [:ash_replicant, :sink, :halted],
    [:ash_replicant, :checkpoint, :conflict],
    [:replicant, :connection, :session_identity_rejected]
  ],
  fn event, _m, meta, _c -> IO.puts("CONSUMER EVENT " <> inspect(event) <> " " <> inspect(meta)) end,
  nil
)

{:ok, _} =
  AshReplicant.start_link(
    sink: FreshConsumer.Sink,
    connection: [
      hostname: uri.host,
      port: uri.port || 5432,
      username: uri.userinfo || "postgres",
      database: current_database
    ],
    publication: "fresh_consumer_pub",
    source_identity: [system_identifier: system_identifier, database: current_database],
    go_forward_only: true,
    census: [enabled?: false]
  )

receive do
  :active -> :ok
after
  15_000 -> raise "pipeline never reached slot_active"
end

_ = FreshConsumer.Repo.query!(
    "INSERT INTO consumer_src_orders (id, note) VALUES ('1', 'hello from the tarball')"
  )

Enum.reduce_while(1..400, :waiting, fn _, :waiting ->
  Process.sleep(25)

  case FreshConsumer.Repo.query!("SELECT id, note FROM consumer_orders").rows do
    [] -> {:cont, :waiting}
    [["1", "hello from the tarball"]] -> {:halt, :ok}
    other -> raise "unexpected mirror contents: #{inspect(other)}"
  end
end)

IO.puts("fresh-consumer: CDC smoke ok — source row mirrored through the tarball package")
SMOKE

cat > "$consumer/setup_db.exs" <<'SETUP'
# Database lifecycle for the consumer check: the dedicated database is
# dropped and created via postgrex against the SERVER url (CREATE
# DATABASE cannot run inside the repo's own connection).
uri = System.fetch_env!("ASH_REPLICANT_TEST_URL") |> URI.parse()
server = Map.put(uri, :path, "/postgres") |> URI.to_string()

{:ok, pid} =
  Postgrex.start_link(
    hostname: uri.host,
    port: uri.port || 5432,
    username: uri.userinfo || "postgres",
    database: "postgres"
  )

Postgrex.query!(pid, "DROP DATABASE IF EXISTS ash_replicant_consumer_check", [])
Postgrex.query!(pid, "CREATE DATABASE ash_replicant_consumer_check", [])
SETUP

echo "== consumer: deps resolve + compile with warnings-as-errors =="
# WAE applies to the CONSUMER's code; dependency-internal warnings are
# upstream's and compile in their own pass without the flag.
(cd "$consumer" && mix deps.get >/dev/null && mix deps.compile >/dev/null && mix compile --warnings-as-errors >/dev/null)
echo "fresh-consumer: compile-WAE ok"

echo "== consumer: docs build =="
(cd "$consumer" && mix docs >/dev/null)
echo "fresh-consumer: docs ok"

echo "== consumer: migrations + default live CDC smoke =="
(cd "$consumer" && mix run setup_db.exs && mix ash.codegen consume >/dev/null && mix ecto.migrate)
cat > "$consumer/list_tables.exs" <<'LIST'
{:ok, _} = FreshConsumer.Repo.start_link()

tables =
  FreshConsumer.Repo.query!("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").rows
  |> List.flatten()
  |> Enum.join(",")

IO.puts("CONSUMER_TABLES=" <> tables)
LIST

(cd "$consumer" && mix run list_tables.exs | grep "CONSUMER_TABLES=") | tee "$work/tables.txt"
grep -q "ash_replicant_checkpoints" "$work/tables.txt" || {
  echo "fresh-consumer: FAIL — checkpoint table missing after migrate"
  exit 1
}

(cd "$consumer" && mix run smoke.exs)

echo "fresh-consumer: PASS"
