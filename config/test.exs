import Config

# A dedicated database keeps the Repo and logical replication slot on the same
# schema. CI supplies a password-bearing loopback URL for its disposable lane;
# the endpoint and authentication are preserved when selecting the test database.
url =
  System.get_env("ASH_REPLICANT_TEST_URL", "postgres://postgres:postgres@127.0.0.1:5432")
  |> URI.parse()
  |> Map.put(:path, "/ash_replicant_test")
  |> URI.to_string()

config :ash_replicant, AshReplicant.TestRepo,
  url: url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  priv: "priv/repo"

config :ash_replicant, ecto_repos: [AshReplicant.TestRepo]

config :ash_replicant,
  ash_domains: [
    AshReplicant.Test.Domain,
    AshReplicant.Test.HistoryDomain,
    # S02 snapshot-provenance fixtures. `AshReplicant.Test.SnapshotContextDomain`
    # is deliberately ABSENT: its tables live in per-tenant Postgres schemas
    # created by a hand-authored migration, not by `mix ash.codegen`.
    AshReplicant.Test.SnapshotDomain
  ]

# C1 message-claim digest baseline (ADR-0015): a fixed non-secret test key.
# Rotation tests replace this via Application.put_env and restore it.
config :ash_replicant, message_digest_keys: [{1, "test-message-digest-key-v1"}]

# S01 snapshot-provenance fingerprint baseline (ADR-0017): a fixed non-secret
# test key. Rotation and key-loss tests replace this via Application.put_env
# and restore it (`AshReplicant.Test.Provenance`).
config :ash_replicant, snapshot_provenance_keys: [{1, "test-snapshot-provenance-key-v1"}]

# O03 digest-key horizon witness baseline (ADR-0022): the ORTHOGONAL family
# authenticating the checkpoint's digest_key_state envelope — never the
# rotating message digest keys themselves.
config :ash_replicant, horizon_provenance_keys: [{1, "test-horizon-provenance-key-v1"}]

config :logger, level: :warning
