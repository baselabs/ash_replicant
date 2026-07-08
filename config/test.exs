import Config

url = System.get_env("ASH_REPLICANT_TEST_URL", "postgres://postgres@localhost:5599/postgres")

config :ash_replicant, AshReplicant.TestRepo,
  url: url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ash_replicant, ecto_repos: [AshReplicant.TestRepo]
config :ash_replicant, ash_domains: []
config :logger, level: :warning
