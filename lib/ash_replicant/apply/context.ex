defmodule AshReplicant.Apply.Context do
  @moduledoc """
  The single home of the admitted-destination operation context shared by the
  SCD1 (`AshReplicant.Apply`) and SCD2 (`AshReplicant.Apply.Scd2`) apply paths.
  Previously duplicated byte-for-byte across both modules — a correction
  applied to one copy silently diverged the other's preflight semantics.
  """

  alias AshReplicant.Destination.NotifierLoads
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
    :message,
    # S02 (ADR-0017): the two snapshot-protocol effect sites. `:mark_seen` is
    # the package's own bookkeeping stamp; `:retire_unseen` is the completion
    # sweep. Both drive host actions, so both need their own identity label —
    # sharing `:upsert`/`:destroy_prior` would alias a bookkeeping mark onto a
    # business row's operation key.
    :mark_seen,
    :retire_unseen
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

  @delivery_manifest_key {__MODULE__, :admitted_manifest}

  @doc """
  Run `fun` with the admitted manifest bound to THIS process, so
  `AshReplicant.Notifier`'s generated `load/2` can compare the statement it is
  about to hand Ash against what the live generation admitted.

  Ash gives `load/2` only `(resource, action)` — no context to thread a
  manifest through — so a process-scoped binding is the only channel, and the
  sink's delivery is synchronous in this process. The binding is removed on the
  way out (restoring any outer one), so a wrapped notifier firing on the host's
  OWN write later in the same process is never verified against a stale
  generation.

  A config with no `:destination_manifest` binds nothing: bare unit configs
  carry no manifest, and the wrapper then behaves as an ordinary Ash notifier.
  """
  @spec with_admitted_manifest(map(), (-> result)) :: result when result: term()
  def with_admitted_manifest(config, fun) when is_function(fun, 0) do
    case Map.get(config, :destination_manifest) do
      %AshReplicant.Destination.Manifest{} = manifest ->
        previous = Process.put(@delivery_manifest_key, manifest)

        try do
          fun.()
        after
          if previous do
            Process.put(@delivery_manifest_key, previous)
          else
            Process.delete(@delivery_manifest_key)
          end
        end

      _other ->
        fun.()
    end
  end

  @doc "The manifest bound for the delivery running in this process, if any."
  @spec admitted_manifest() :: struct() | nil
  def admitted_manifest, do: Process.get(@delivery_manifest_key)

  @doc """
  Run `fun` with the delivery binding SUSPENDED.

  The out-of-band check probes `load/2` to see what Ash would derive. For a
  wrapped notifier that call re-enters `AshReplicant.Notifier`, which would
  verify and raise on the very drift this check exists to report — turning a
  clean `:notifier_load_drift` into an opaque `:notifier_load_probe_failed`.
  Suspending the binding makes the probe observe the raw statement, which is
  what it needs to compare.
  """
  @spec without_admitted_manifest((-> result)) :: result when result: term()
  def without_admitted_manifest(fun) when is_function(fun, 0) do
    case Process.delete(@delivery_manifest_key) do
      nil ->
        fun.()

      manifest ->
        try do
          fun.()
        after
          Process.put(@delivery_manifest_key, manifest)
        end
    end
  end

  @doc """
  Prove the notifier `load/2` statements this action will run still match the
  ones the manifest admitted — BEFORE the action runs.

  This is the OUT-OF-BAND layer. `AshReplicant.Notifier`'s generated `load/2`
  is the in-band one and has no probe-to-use window at all; this check exists
  for what the wrapper structurally cannot cover — a notifier that carries no
  wrapper because its admitted statement was EMPTY, a notifier that appeared in
  or vanished from the action's notifier list, and a `load/2` that faults.
  Sited immediately before each Ash call the sink drives.

  A config with no `:destination_manifest` is inert, matching
  `preflight_onetime!/5`: bare unit configs carry no manifest, while every
  runtime config the sink delivers under is built from the live generation and
  re-checked against it at every callback entry, so the fallback is unreachable
  in production.
  """
  @spec verify_notifier_loads!(map(), module(), atom(), atom()) :: :ok
  def verify_notifier_loads!(config, resource, action, operation) do
    case Map.get(config, :destination_manifest) do
      %AshReplicant.Destination.Manifest{} = manifest ->
        verdict =
          without_admitted_manifest(fn -> NotifierLoads.verify(manifest, resource, action) end)

        case verdict do
          :ok ->
            :ok

          {:error, reason} ->
            raise Error.exception(reason: reason, resource: resource, op: operation)
        end

      _other ->
        :ok
    end
  end
end
