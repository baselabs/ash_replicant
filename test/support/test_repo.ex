defmodule AshReplicant.TestRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_replicant

  @start_attempt_key {__MODULE__, :start_attempted}

  @impl true
  def init(type, config) do
    if type == :supervisor and
         Application.get_env(:ash_replicant, :forbid_test_repo_start?, false) do
      :persistent_term.put(@start_attempt_key, true)
    end

    {:ok, config}
  end

  def start_attempt_key, do: @start_attempt_key

  @impl true
  def min_pg_version do
    Version.parse!(System.fetch_env!("EXPECTED_PG_MAJOR") <> ".0.0")
  end

  @impl true
  def installed_extensions, do: ["ash-functions"]
end
