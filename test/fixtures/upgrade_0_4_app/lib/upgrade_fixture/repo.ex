defmodule UpgradeFixture.Repo do
  use AshPostgres.Repo,
    otp_app: :upgrade_fixture,
    warn_on_missing_ash_functions?: false

  # Metadata-only Mix tasks do not need a live service. Require the real URL
  # when the repo is configured for use, rather than while loading project config.
  @impl true
  def init(context, config) do
    super(context, Keyword.put(config, :url, System.fetch_env!("ASH_REPLICANT_TEST_URL")))
  end

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
