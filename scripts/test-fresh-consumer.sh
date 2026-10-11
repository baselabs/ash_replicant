#!/usr/bin/env bash
set -euo pipefail

# Prove a fresh consumer from the unpacked release candidate or Hex.
# Builds the hex package, unpacks it as the ONLY dependency source of a
# scratch mix project (nothing from this repo's checkout is on the
# consumer's path), then runs the adopter's first hour: deps resolve,
# compile with warnings-as-errors, docs, ash.codegen + ecto.migrate, and
# a default live CDC smoke (a source insert mirrored through the real
# pipeline) against $ASH_REPLICANT_TEST_URL's server. Hex consumers require
# that URL; a local tarball consumer names its skip when the URL is unset.

root="$(cd "$(dirname "$0")/.." && pwd)"
export MIX_ENV=dev
unset ASH_REPLICANT_ASH_VERSION ASH_REPLICANT_REPLICANT_VERSION ASH_REPLICANT_ONETIME_VERSION
hex_version=""
check=false
if [[ "${1:-}" == --from-hex ]]; then
  hex_version="${2:?usage: test-fresh-consumer.sh [--from-hex VERSION] [--check]}"
  [[ "$hex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
  shift 2
fi
if [[ "${1:-}" == --check ]]; then
  check=true
  shift
fi
[[ "$#" -eq 0 ]] || { echo 'fresh-consumer: invalid arguments' >&2; exit 2; }
if [[ -n "$hex_version" && -z "${ASH_REPLICANT_TEST_URL:-}" ]]; then
  echo 'fresh-consumer: ASH_REPLICANT_TEST_URL is required in --from-hex mode' >&2
  exit 1
fi
if [[ -n "$hex_version" ]]; then
  curl -fsSL --max-time 30 "https://hex.pm/api/packages/ash_replicant/releases/$hex_version" >/dev/null
  echo "fresh-consumer: dependency source is Hex ash_replicant $hex_version"
else
  echo 'fresh-consumer: dependency source is the local release tarball'
fi
if [[ "$check" == true ]]; then
  echo 'fresh-consumer: source check PASS (no consumer run requested)'
  exit 0
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-fresh-consumer.XXXXXX")"
database_created=false
lease_pid=""
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$database_created" == true ]]; then
    if ! (cd "$consumer" && mix run cleanup_db.exs); then
      echo 'fresh-consumer: FAIL — scratch database cleanup failed' >&2
      status=1
    fi
  fi
  if [[ -n "$lease_pid" ]]; then
    exec 9>&-
    for attempt in {1..100}; do
      if ! kill -0 "$lease_pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    kill "$lease_pid" 2>/dev/null || true
    wait "$lease_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

url="${ASH_REPLICANT_TEST_URL:-}"
if [ -z "$url" ]; then
  echo "fresh-consumer: SKIP — no ASH_REPLICANT_TEST_URL (the consumer smoke is live-only)"
  exit 0
fi

export ASH_REPLICANT_CONSUMER_DATABASE="ash_replicant_consumer_$$_$RANDOM"
export ASH_REPLICANT_CONSUMER_SLOT="$ASH_REPLICANT_CONSUMER_DATABASE"
consumer="$work/consumer"
vendor="$consumer/vendor/ash_replicant"

# Keep a real administrative backend alive for this run before reclaiming
# abandoned resources. Its application_name protects the database and slot
# through the gaps between consumer Mix children. This helper uses compiled
# Postgrex directly and never runs a background Mix command.
helper_build=""
for environment in test dev; do
  if [[ -d "$root/_build/$environment/lib/postgrex/ebin" ]]; then
    helper_build="$root/_build/$environment"
    break
  fi
done
[[ -n "$helper_build" ]] || {
  echo 'fresh-consumer: compiled Postgrex is required for the database lease' >&2
  exit 1
}
lease_ready="$work/lease-ready"
lease_channel="$work/lease-channel"
mkfifo -m 600 "$lease_channel"
# Bootstrap both ends so a helper startup failure cannot block opening the
# writer. The helper closes its inherited writer; after readiness, fd 9 is
# narrowed to the writer retained by this shell and its real Mix children.
exec 9<>"$lease_channel"
elixir -pa "$helper_build/lib/*/ebin" "$root/scripts/fresh_consumer_lease.exs" \
  "$lease_channel" "$lease_ready" 9>&- &
lease_pid=$!
for attempt in {1..300}; do
  [[ -f "$lease_ready" ]] && break
  if ! kill -0 "$lease_pid" 2>/dev/null; then
    wait "$lease_pid" || true
    echo 'fresh-consumer: database lease did not start' >&2
    exit 1
  fi
  sleep 0.1
done
[[ -f "$lease_ready" ]] || {
  echo 'fresh-consumer: database lease startup timed out' >&2
  exit 1
}
exec 9>"$lease_channel"

require_lease() {
  if ! kill -0 "$lease_pid" 2>/dev/null || [[ ! -f "$lease_ready" ]]; then
    echo 'fresh-consumer: database lease was lost' >&2
    exit 1
  fi
}

consumer_mix() {
  require_lease
  (cd "$consumer" && mix "$@")
  require_lease
}

require_lease

if [[ -z "$hex_version" ]]; then
echo "== building the release package =="
tarball="$work/ash_replicant-release.tar"
# Selector-free build: an exported dependency selector would pin the
# tarball's package metadata to one version instead of the published
# requirement ranges, so all three selectors are cleared here exactly as
# the release-artifact job's hex.build clears them.
(cd "$root" &&
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION \
    MIX_ENV=test mix hex.build --output "$tarball" >/dev/null)
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
fi
require_lease

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
      replicant_dependency(),
      {:ex_doc, "~> 0.37", only: :dev, runtime: false}
    ]
  end

  defp replicant_dependency do
    case System.get_env("ASH_REPLICANT_CONSUMER_VERSION") do
      nil -> {:ash_replicant, path: Path.expand("#{__DIR__}/vendor/ash_replicant")}
      version -> {:ash_replicant, "== #{version}"}
    end
  end
end
MIX

if [[ -n "$hex_version" ]]; then
  export ASH_REPLICANT_CONSUMER_VERSION="$hex_version"
else
  unset ASH_REPLICANT_CONSUMER_VERSION
fi

cat > "$consumer/config/config.exs" <<'CONF'
import Config

# The consumer's database is dedicated to this check; host/port/user come
# from the same env var CI and the local gate use.
url =
  System.fetch_env!("ASH_REPLICANT_TEST_URL")
  |> URI.parse()
  |> Map.put(:path, "/" <> System.fetch_env!("ASH_REPLICANT_CONSUMER_DATABASE"))
  |> URI.to_string()

config :fresh_consumer, ecto_repos: [FreshConsumer.Repo]
config :fresh_consumer, FreshConsumer.Repo, url: url, pool_size: 5, log: false
config :fresh_consumer, ash_domains: [FreshConsumer.Domain]
# Consumer host config (README "Manual installation"): the counting basis
# ash_replicant's contracts and generated migrations are authored against.
config :ash, default_string_length_count: :codepoints
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
    slot_name: System.fetch_env!("ASH_REPLICANT_CONSUMER_SLOT")
end
SINK

cat > "$consumer/smoke.exs" <<'SMOKE'
# The default live CDC smoke, run inside the consumer: the replicated
# source table + publication, one pipeline start, one source insert, and
# the mirrored row asserted back through the consumer's own repo —
# everything from the unpacked package. The database itself is created
# by setup_db.exs BEFORE the migrations; this file only consumes it.
uri = System.fetch_env!("ASH_REPLICANT_TEST_URL") |> URI.parse()
[username | credentials] = String.split(uri.userinfo || "postgres", ":", parts: 2)
username = URI.decode(username)
password = credentials |> List.first() |> then(&if(&1, do: URI.decode(&1), else: nil))

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
      username: username,
      password: password,
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

:ok = Enum.reduce_while(1..400, :waiting, fn _, :waiting ->
  Process.sleep(25)

  case FreshConsumer.Repo.query!("SELECT id, note FROM consumer_orders").rows do
    [] -> {:cont, :waiting}
    [["1", "hello from the tarball"]] -> {:halt, :ok}
    other -> raise "unexpected mirror contents: #{inspect(other)}"
  end
end)

:ok = AshReplicant.stop_supervised(System.fetch_env!("ASH_REPLICANT_CONSUMER_SLOT"))

IO.puts("fresh-consumer: CDC smoke ok — source row mirrored through the resolved package")
SMOKE

cat > "$consumer/setup_db.exs" <<'SETUP'
# Database lifecycle for the consumer check: the dedicated database is
# created via Postgrex against the server URL (CREATE
# DATABASE cannot run inside the repo's own connection).
uri = System.fetch_env!("ASH_REPLICANT_TEST_URL") |> URI.parse()
[username | credentials] = String.split(uri.userinfo || "postgres", ":", parts: 2)
username = URI.decode(username)
password = credentials |> List.first() |> then(&if(&1, do: URI.decode(&1), else: nil))

{:ok, pid} =
  Postgrex.start_link(
    hostname: uri.host,
    port: uri.port || 5432,
    username: username,
    password: password,
    database: "postgres"
  )

database = System.fetch_env!("ASH_REPLICANT_CONSUMER_DATABASE")
true = Regex.match?(~r/^ash_replicant_consumer_[0-9]+_[0-9]+$/, database)
Postgrex.query!(pid, ~s(CREATE DATABASE "#{database}"), [])
SETUP

cat > "$consumer/cleanup_db.exs" <<'CLEANUP'
uri = System.fetch_env!("ASH_REPLICANT_TEST_URL") |> URI.parse()
[username | credentials] = String.split(uri.userinfo || "postgres", ":", parts: 2)
username = URI.decode(username)
password = credentials |> List.first() |> then(&if(&1, do: URI.decode(&1), else: nil))
{:ok, pid} = Postgrex.start_link(hostname: uri.host, port: uri.port || 5432,
  username: username, password: password, database: "postgres")
database = System.fetch_env!("ASH_REPLICANT_CONSUMER_DATABASE")
true = Regex.match?(~r/^ash_replicant_consumer_[0-9]+_[0-9]+$/, database)
slot = System.fetch_env!("ASH_REPLICANT_CONSUMER_SLOT")
Postgrex.query!(pid, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1", [database])
Postgrex.query!(pid, "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = $1", [slot])
Postgrex.query!(pid, ~s(DROP DATABASE IF EXISTS "#{database}"), [])
IO.puts("fresh-consumer: scratch database and replication slot removed")
CLEANUP

echo "== consumer: deps resolve + compile with warnings-as-errors =="
# WAE applies to the CONSUMER's code; dependency-internal warnings are
# upstream's and compile in their own pass without the flag.
consumer_mix deps.get >/dev/null
consumer_mix deps.compile >/dev/null
consumer_mix compile --warnings-as-errors >/dev/null
echo "fresh-consumer: compile-WAE ok"

echo "== consumer: docs build =="
consumer_mix docs >/dev/null
echo "fresh-consumer: docs ok"

echo "== consumer: migrations + default live CDC smoke =="
database_created=true
consumer_mix run setup_db.exs
consumer_mix ash.codegen consume >/dev/null
consumer_mix ecto.migrate
cat > "$consumer/list_tables.exs" <<'LIST'
{:ok, _} = FreshConsumer.Repo.start_link()

tables =
  FreshConsumer.Repo.query!("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").rows
  |> List.flatten()
  |> Enum.join(",")

IO.puts("CONSUMER_TABLES=" <> tables)
LIST

(consumer_mix run list_tables.exs | grep "CONSUMER_TABLES=") | tee "$work/tables.txt"
grep -q "ash_replicant_checkpoints" "$work/tables.txt" || {
  echo "fresh-consumer: FAIL — checkpoint table missing after migrate"
  exit 1
}

consumer_mix run smoke.exs

echo "fresh-consumer: PASS"
