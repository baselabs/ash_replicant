defmodule AshReplicant.TestRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_replicant

  @start_attempt_key {__MODULE__, :start_attempted}

  @impl true
  def init(_type, config) do
    if Application.get_env(:ash_replicant, :forbid_test_repo_start?, false) do
      :persistent_term.put(@start_attempt_key, true)
    end

    {:ok, config}
  end

  def start_attempt_key, do: @start_attempt_key

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["ash-functions"]
end
