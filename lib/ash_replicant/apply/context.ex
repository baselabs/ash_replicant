defmodule AshReplicant.Apply.Context do
  @moduledoc """
  The single home of the admitted-destination operation context shared by the
  SCD1 (`AshReplicant.Apply`) and SCD2 (`AshReplicant.Apply.Scd2`) apply paths.
  Previously duplicated byte-for-byte across both modules — a correction
  applied to one copy silently diverged the other's preflight semantics.
  """

  alias AshReplicant.Error

  # The CLOSED mint set — one label per sink call site, the complete inventory
  # of effect sites (enumeration-pinned by destination_participant_test). A new
  # effect site must add a label here or the set fails to match the code.
  @invocation_labels [
    :close_prior,
    :close_current,
    :open,
    :destroy_prior,
    :upsert,
    :message
  ]

  @doc "The closed per-invocation label set (the single home is shared with DestinationParticipant)."
  @spec invocation_labels() :: [atom()]
  def invocation_labels, do: @invocation_labels

  @doc false
  @spec action_context(map()) :: map()
  def action_context(config),
    do: %{data_layer: Map.get(config, :data_layer_context, %{repo: config.repo})}

  @doc false
  @spec action_context(map(), map(), atom()) :: map()
  def action_context(config, change, invocation) when is_atom(invocation) do
    context = action_context(config)

    case operation_context(config, change, invocation) do
      {:ok, operation} -> Map.put(context, :ash_replicant_operation, operation)
      :error -> context
    end
  end

  @doc false
  @spec operation_context(map(), map(), atom()) :: {:ok, map()} | :error
  def operation_context(
        %{
          source_identity: %{system_identifier: system_identifier, database: database},
          slot_name: slot_name
        },
        %{commit_lsn: commit_lsn, ordinal: ordinal},
        invocation
      )
      when is_binary(system_identifier) and is_binary(database) and is_binary(slot_name) and
             is_integer(commit_lsn) and commit_lsn >= 0 and is_integer(ordinal) and ordinal >= 0 and
             invocation in @invocation_labels,
      do:
        {:ok,
         %{
           source_system_identifier: system_identifier,
           source_database: database,
           slot_name: slot_name,
           commit_lsn: commit_lsn,
           ordinal: ordinal,
           invocation: invocation
         }}

  def operation_context(_config, _change, _invocation), do: :error

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
