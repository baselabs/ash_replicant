import Config

config :upgrade_fixture, ecto_repos: [UpgradeFixture.Repo]

config :upgrade_fixture, UpgradeFixture.Repo,
  url: System.fetch_env!("ASH_REPLICANT_TEST_URL"),
  pool_size: 2,
  snapshots_path: "priv/upgrade_snapshots"

config :upgrade_fixture,
  ash_domains: [UpgradeFixture.Domain]

# The string-length counting basis the fixture's generated resources are
# snapshotted against — the same host config consumers set (README
# "Manual installation"). The library never mutates global Ash config.
config :ash, default_string_length_count: :codepoints
