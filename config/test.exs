import Config

# ash_replicant's tests share the Postgres INSTANCE (5599) with the sibling `replicant`
# suite, which manages its own `orders` table (integer id) in the default `postgres`
# database. To stop the two clobbering each other's schema, pin a DEDICATED database that
# only this repo uses — host/port/user/query still come from ASH_REPLICANT_TEST_URL (the
# `:integration` gate), only the database name is forced. `Marquee.conn/0` derives the
# replication connection from this same repo config, so the Ecto pool and the WAL slot can
# never point at different databases (the divergence that caused the flakiness).
url =
  System.get_env("ASH_REPLICANT_TEST_URL", "postgres://postgres@localhost:5599")
  |> URI.parse()
  |> Map.put(:path, "/ash_replicant_test")
  |> URI.to_string()

config :ash_replicant, AshReplicant.TestRepo,
  url: url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  priv: "priv/repo"

config :ash_replicant, ecto_repos: [AshReplicant.TestRepo]
config :ash_replicant, ash_domains: [AshReplicant.Test.Domain, AshReplicant.Test.HistoryDomain]
config :logger, level: :warning
