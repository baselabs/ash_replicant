defmodule UpgradeFixture.Repo do
  use AshPostgres.Repo,
    otp_app: :upgrade_fixture,
    warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
