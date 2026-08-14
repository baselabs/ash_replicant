defmodule AshReplicant.Apply.Context do
  @moduledoc false
  # The single home of the admitted-destination operation context shared by the
  # SCD1 (`AshReplicant.Apply`) and SCD2 (`AshReplicant.Apply.Scd2`) apply paths.
  # Previously duplicated byte-for-byte across both modules — a correction
  # applied to one copy silently diverged the other's preflight semantics.

  alias AshReplicant.Error

  @doc false
  @spec action_context(map()) :: map()
  def action_context(config),
    do: %{data_layer: Map.get(config, :data_layer_context, %{repo: config.repo})}

  @doc false
  @spec action_context(map(), map()) :: map()
  def action_context(config, change) do
    context = action_context(config)

    case operation_context(config, change) do
      {:ok, operation} -> Map.put(context, :ash_replicant_operation, operation)
      :error -> context
    end
  end

  @doc false
  @spec operation_context(map(), map()) :: {:ok, map()} | :error
  def operation_context(
        %{
          source_identity: %{system_identifier: system_identifier, database: database},
          slot_name: slot_name
        },
        %{commit_lsn: commit_lsn, ordinal: ordinal}
      )
      when is_binary(system_identifier) and is_binary(database) and is_binary(slot_name) and
             is_integer(commit_lsn) and commit_lsn >= 0 and is_integer(ordinal) and ordinal >= 0,
      do:
        {:ok,
         %{
           source_system_identifier: system_identifier,
           source_database: database,
           slot_name: slot_name,
           commit_lsn: commit_lsn,
           ordinal: ordinal
         }}

  def operation_context(_config, _change), do: :error

  @doc false
  @spec preflight_onetime!(map(), term(), module(), atom(), atom()) :: :ok
  def preflight_onetime!(config, tenant, resource, action, operation) do
    already_preflighted? =
      config
      |> Map.get(:onetime_preflighted, MapSet.new())
      |> MapSet.member?({resource, action, tenant})

    case {already_preflighted?, Map.get(config, :destination_manifest)} do
      {true, _manifest} ->
        :ok

      {false, %AshReplicant.Destination.Manifest{} = manifest} ->
        case AshReplicant.Destination.preflight_onetime_transaction(
               manifest,
               Map.get(config, :dynamic_repo, config.repo),
               tenant,
               resource,
               action
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            raise Error.exception(reason: reason, resource: resource, op: operation)
        end

      {false, _other} ->
        :ok
    end
  end
end
