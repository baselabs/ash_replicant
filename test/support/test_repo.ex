defmodule AshReplicant.TestRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_replicant

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["ash-functions"]
end
