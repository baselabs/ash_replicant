defmodule AshReplicant do
  @moduledoc """
  An Ash-native `Replicant.Sink` adapter. Mirrors a source Postgres database's
  committed streaming transactions into AshPostgres resources with durable
  effect-once semantics, resolving resource, tenant, and classification in the
  Ash layer while keeping `replicant` tenant-blind.

  Replicant v1 snapshot batches are atomic. An incomplete multi-batch snapshot
  restart can physically repeat committed batch effects while rebuilding the
  target; zero-repeat snapshot restart remains roadmap C3 work.

  This is the `ash_postgres`-of-`replicant`: `replicant` is the tenant-blind CDC
  transport; multitenancy and classification live here, one layer up.
  """

  @version Mix.Project.config()[:version]

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Coverage
  alias AshReplicant.Destination.Generation
  alias AshReplicant.Error
  alias AshReplicant.Sink.Impl

  @doc "The library version string."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Start a CDC pipeline that mirrors into Ash resources, owned by a
  `AshReplicant.PipelineOwner` that monitors it. `opts`:

    * `:sink` — a module built with `use AshReplicant.Sink` (carries repo/domains/checkpoint/slot).
    * `:connection` — Postgrex opts (point at a standby).
    * `:publication` — replication identifier.
    * `:source_identity` — required PostgreSQL system/database identity expected
      from the actual replication session, as
      `[system_identifier: "...", database: "..."]`.
    * `:go_forward_only` — passed through to `Replicant.start_link/1`.
    * `:snapshot` — `false` or Replicant's v1 snapshot (`true`). Incremental
      snapshot options are unsupported until the adapter implements durable
      progress and target provenance.
    * `:streaming`, `:max_inflight_lag`, `:max_command_retries`, and `:failover`
      — passed through unchanged to Replicant.
    * `:messages` — passed through to Replicant; a sink with a declared
      message routing surface gets `messages: true` by default (an explicit
      caller value always wins).

  The `slot_name` is NOT a `start_link` option — it is baked into the sink via
  `use AshReplicant.Sink, slot_name: ...` and is the single source of truth for
  both the `:persistent_term` index key and the replication slot.

  Builds the `{schema,table}=>resource` index from the sink's domains, **fails
  closed** on a duplicate or missing source table, caches the index in
  `:persistent_term`, then starts the `replicant` pipeline. Returns the
  OWNER's pid (linked to the caller); a host supervisor should start the same
  thing through `AshReplicant.PipelineOwner.child_spec/1` instead. When the
  pipeline exits for any reason the owner erases the generation, so the slot
  is immediately re-activatable (ADR-0014).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    AshReplicant.PipelineOwner.start_link(opts)
  end

  @doc """
  Stop a running pipeline by slot name (idempotent). Clears the cached resolver
  index from `:persistent_term` so a subsequent `start_link/1` rebuilds it fresh.
  """
  @spec stop_supervised(String.t()) :: :ok | {:error, :pipeline_stop_failed}
  def stop_supervised(slot_name) do
    activation_lock(slot_name, fn ->
      result = safe_stop(slot_name)
      :persistent_term.erase({AshReplicant, slot_name})
      Impl.clear_snapshot_ordinals(slot_name)
      result
    end)
  end

  @doc false
  def erase_generation(slot_name, generation),
    do: erase_generation_key({AshReplicant, slot_name}, generation)

  @doc false
  # The pending-owner handshake's reap: if the caller died after activation
  # succeeded but before adoption, the written generation names `owner_pid`
  # as its owner — erase it (and stop any pipeline it started). Owned by
  # PipelineOwner, not the public API.
  def reclaim_owned_generation(slot_name, owner_pid) do
    case :persistent_term.get({AshReplicant, slot_name}, :none) do
      %Generation{reference: reference, owner: ^owner_pid} ->
        _ = safe_stop(slot_name)
        erase_generation_key({AshReplicant, slot_name}, reference)

      _other ->
        :ok
    end
  end

  @doc """
  Adopt a legacy slot-only watermark into a source-bound checkpoint row (the
  explicit operator choice of roadmap B2's legacy policy). Offline: refuses
  while the slot has a live pipeline generation, stamps the operator-declared
  ACTUAL source identity and the preserved `commit_lsn`, and leaves the
  contract NULL — the first connect classifies the NULL contract as
  `:initialized` and fills it WITHOUT touching the watermark. Idempotent when
  the identical row already exists (same identity AND watermark); refuses
  (`:checkpoint_adopt_conflict`) when a different identity already owns the
  slot name or the existing watermark differs. All errors are value-free.

  > Repo binding: the operator functions write through the CALLER'S current
  > dynamic-repo binding. On a host multiplexing databases through
  > `put_dynamic_repo/1`, call them from a process bound to the destination
  > repo (the same identity the pipeline's admitted generation pins).
  """
  @spec adopt_checkpoint(module(), keyword(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def adopt_checkpoint(sink, source_identity, commit_lsn) do
    with {:ok, config} <- operator_sink(sink),
         {:ok, identity} <- validate_identity_fields(source_identity),
         :ok <- validate_watermark(commit_lsn) do
      offline_slot_operation(config.slot_name, fn -> adopt_row(config, identity, commit_lsn) end)
    end
  end

  @doc """
  Destroy the source-bound checkpoint row for the sink's slot (the operator
  escape hatch for incompatible contract transitions and identity rebinding —
  after reset, the next connect binds fresh and the operator has accepted
  re-delivery / re-snapshot semantics; on an SCD2 mirror, pair a reset with a
  full re-snapshot, never bare re-delivery). Idempotent when absent. Routes
  through the generated resource's `:operator_reset` destroy action.
  """
  @spec reset_checkpoint(module(), keyword()) :: :ok | {:error, term()}
  def reset_checkpoint(sink, source_identity) do
    with {:ok, config} <- operator_sink(sink),
         {:ok, identity} <- validate_identity_fields(source_identity) do
      offline_slot_operation(config.slot_name, fn -> reset_row(config, identity) end)
    end
  end

  @doc """
  The operator's WAL-history continuity assertion after a
  `:source_timeline_changed` halt: re-binds the row's recorded source timeline
  to the asserted value WITHOUT touching the watermark or contract — correct
  for a same-primary crash-restart (whose new timeline replays the old WAL).
  For a promotion/fork the operator cannot prove continuous, use
  `reset_checkpoint/2` instead. Offline and idempotent.
  """
  @spec acknowledge_checkpoint_timeline(module(), keyword(), non_neg_integer()) ::
          :ok | {:error, term()}
  def acknowledge_checkpoint_timeline(sink, source_identity, timeline_id) do
    with {:ok, config} <- operator_sink(sink),
         {:ok, identity} <- validate_identity_fields(source_identity),
         :ok <- validate_timeline(timeline_id) do
      offline_slot_operation(config.slot_name, fn ->
        acknowledge_timeline(config, identity, timeline_id)
      end)
    end
  end

  defp operator_sink(sink) when is_atom(sink) do
    case safe_sink_config(sink) do
      %{repo: repo, checkpoint_resource: checkpoint, slot_name: slot}
      when is_atom(repo) and is_atom(checkpoint) and is_binary(slot) ->
        {:ok, %{repo: repo, checkpoint_resource: checkpoint, slot_name: slot}}

      _other ->
        {:error, Error.exception(reason: :checkpoint_adopt_invalid, resource: nil, op: :adopt)}
    end
  end

  # The operator surfaces run OFFLINE: they refuse while the slot has a LIVE
  # owner's generation (the lease/activation state a running sink owns). An
  # entry whose owner is gone is reaped — with any orphan pipeline — instead
  # of wedging recovery on a stale admission.
  defp offline_slot_operation(slot_name, operation) do
    activation_lock(slot_name, fn ->
      offline_slot_step(
        slot_name,
        :persistent_term.get({AshReplicant, slot_name}, :none),
        operation
      )
    end)
  end

  defp offline_slot_step(_slot_name, :none, operation), do: operation.()

  defp offline_slot_step(slot_name, %Generation{owner: owner}, operation) do
    if owner_alive?(owner) do
      {:error, Error.exception(reason: :config_invalid, resource: nil, op: :slot_already_active)}
    else
      _ = safe_stop(slot_name)
      :persistent_term.erase({AshReplicant, slot_name})
      operation.()
    end
  end

  defp validate_watermark(lsn) when is_integer(lsn) and lsn >= 0, do: :ok
  defp validate_watermark(nil), do: :ok
  defp validate_watermark(_), do: {:error, invalid_adopt(:commit_lsn)}

  defp validate_timeline(timeline) when is_integer(timeline) and timeline >= 0, do: :ok
  defp validate_timeline(_), do: {:error, invalid_adopt(:timeline_id)}

  defp invalid_adopt(field),
    do:
      Error.exception(
        reason: :checkpoint_adopt_invalid,
        resource: nil,
        op: :adopt,
        shape: to_string(field)
      )

  defp adopt_row(config, identity, commit_lsn) do
    filter = checkpoint_identity_filter(config, identity)

    result =
      config.repo.transaction(fn ->
        case locked_slot_rows(config) do
          [] -> insert_adopted_row!(config, filter, commit_lsn)
          [row] -> verify_adopted_row!(config, filter, row, commit_lsn)
          _many -> config.repo.rollback(adopt_conflict(config))
        end
      end)

    scrub_transaction_result(result, config.checkpoint_resource, :adopt)
  end

  # No row under the slot name: the adoption IS the first binding of the
  # durable watermark (the upsert is the legacy-capture continuation).
  defp insert_adopted_row!(config, filter, commit_lsn) do
    Ash.create!(
      config.checkpoint_resource,
      Map.merge(filter, %{commit_lsn: commit_lsn}),
      action: :upsert,
      upsert?: true,
      upsert_identity: :source_slot,
      upsert_fields: [:commit_lsn],
      authorize?: false,
      return_notifications?: true
    )

    :ok
  end

  defp verify_adopted_row!(config, filter, row, commit_lsn) do
    same_triple =
      row.source_system_id == filter.source_system_id and
        row.source_database == filter.source_database and
        row.slot_name == filter.slot_name

    cond do
      not same_triple ->
        config.repo.rollback(adopt_conflict(config))

      # Idempotence requires the IDENTICAL row: a different watermark
      # (including a nil argument over a durable one) is a mismatched
      # adoption — refuse rather than silently keep the first.
      row.commit_lsn != commit_lsn ->
        config.repo.rollback(
          Error.exception(
            reason: :checkpoint_adopt_conflict,
            resource: config.checkpoint_resource,
            op: :adopt,
            shape: "watermark_mismatch"
          )
        )

      true ->
        :ok
    end
  end

  defp adopt_conflict(config),
    do:
      Error.exception(
        reason: :checkpoint_adopt_conflict,
        resource: config.checkpoint_resource,
        op: :adopt
      )

  # Every operator transaction reports through the same value-free funnel.
  defp scrub_transaction_result(result, resource, op) do
    case result do
      {:ok, :ok} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      {:error, other} -> {:error, Error.scrub(other, resource, op)}
    end
  end

  defp reset_row(config, identity) do
    filter = checkpoint_identity_filter(config, identity)

    result =
      config.repo.transaction(fn ->
        for row <- locked_triple_rows(config, filter) do
          Ash.destroy!(row,
            action: :operator_reset,
            authorize?: false,
            return_notifications?: true
          )
        end

        :ok
      end)

    scrub_transaction_result(result, config.checkpoint_resource, :reset)
  end

  defp acknowledge_timeline(config, identity, timeline_id) do
    filter = checkpoint_identity_filter(config, identity)

    result =
      config.repo.transaction(fn ->
        case locked_triple_rows(config, filter) do
          [%{source_timeline: stored}] = rows when is_integer(stored) ->
            rebind_timeline_rows!(config, rows, stored, timeline_id)

          [_row] ->
            # The row exists but has NO recorded timeline yet (adopted, never
            # bound): there is nothing to acknowledge — start the pipeline and
            # the first bind records the session timeline.
            config.repo.rollback(
              Error.exception(
                reason: :checkpoint_adopt_invalid,
                resource: config.checkpoint_resource,
                op: :acknowledge_timeline,
                shape: "source_timeline_nil"
              )
            )

          _many_or_none ->
            config.repo.rollback(
              Error.exception(
                reason: :checkpoint_unbound,
                resource: config.checkpoint_resource,
                op: :acknowledge_timeline
              )
            )
        end
      end)

    scrub_transaction_result(result, config.checkpoint_resource, :acknowledge_timeline)
  end

  # Same timeline is the idempotent no-op; a different one re-binds EVERY row
  # of the triple (the operator asserted WAL-history continuity for them all).
  defp rebind_timeline_rows!(config, rows, stored, timeline_id) do
    if stored == timeline_id do
      :ok
    else
      for row <- rows do
        Ash.create!(
          config.checkpoint_resource,
          Map.merge(checkpoint_filter_from(config, row), %{source_timeline: timeline_id}),
          action: :upsert,
          upsert?: true,
          upsert_identity: :source_slot,
          upsert_fields: [:source_timeline],
          authorize?: false,
          return_notifications?: true
        )
      end

      :ok
    end
  end

  defp checkpoint_identity_filter(config, identity) do
    %{
      source_system_id: identity.system_identifier,
      source_database: identity.database,
      slot_name: config.slot_name
    }
  end

  defp checkpoint_filter_from(_config, row) do
    %{
      source_system_id: row.source_system_id,
      source_database: row.source_database,
      slot_name: row.slot_name
    }
  end

  # Slot-wide locked read (adopt's conflict surface: every row owning the name).
  defp locked_slot_rows(config) do
    import Ash.Query, only: [filter: 2]

    config.checkpoint_resource
    |> filter(slot_name == ^config.slot_name)
    |> Ash.read!(lock: :for_update, authorize?: false)
    |> List.wrap()
  end

  # Exact-triple locked read (reset/acknowledge: only the operator's own row).
  defp locked_triple_rows(config, filter) do
    import Ash.Query, only: [filter: 2]

    config.checkpoint_resource
    |> filter(
      slot_name == ^filter.slot_name and source_system_id == ^filter.source_system_id and
        source_database == ^filter.source_database
    )
    |> Ash.read!(lock: :for_update, authorize?: false)
    |> List.wrap()
  end

  @doc false
  @spec run_callback(String.t(), module(), :read | :mutate, (map() -> term())) :: term()
  def run_callback(slot_name, sink, mode, effect)
      when is_binary(slot_name) and is_atom(sink) and mode in [:read, :mutate] and
             is_function(effect, 1) do
    runner = fn -> run_admitted_callback(slot_name, sink, effect) end

    case mode do
      :read -> runner.()
      :mutate -> activation_lock(slot_name, runner)
    end
  end

  @doc false
  @spec guard_generation(map()) :: :ok | {:error, Error.t()}
  def guard_generation(
        %{
          slot_name: slot_name,
          sink: sink,
          generation: generation
        } = config
      ) do
    with %Generation{reference: ^generation, sink: ^sink} = admitted <-
           :persistent_term.get({AshReplicant, slot_name}, :none),
         :ok <- validate_runtime_config(config, admitted),
         :ok <- validate_generation(admitted) do
      :ok
    else
      _other -> generation_error(:generation_guard)
    end
  end

  def guard_generation(_config), do: generation_error(:generation_guard)

  @replicant_option_keys [
    :connection,
    :publication,
    :go_forward_only,
    :snapshot,
    :messages,
    :streaming,
    :max_inflight_lag,
    :max_command_retries,
    :failover
  ]

  # The owner's activation body (ADR-0014): the full validate + preflight +
  # lock chain, run in the STARTING CALLER (PipelineOwner.start_link/1) so
  # start errors return synchronously with the chain's own error shapes and a
  # failed start never takes the caller down with it. A generation whose owner
  # is gone admits nothing but would block re-activation — it is reaped (with
  # any orphan pipeline) and replaced by the fresh activation.
  @doc false
  @spec activate_owner(keyword(), pid()) ::
          {:ok, %{slot_name: String.t(), generation_ref: reference(), pipeline_pid: pid()}}
          | {:error, term()}
  def activate_owner(opts, owner_pid) when is_list(opts) and is_pid(owner_pid) do
    with {:ok, sink, sink_config} <- validate_sink(opts),
         {:ok, source_identity} <- validate_source_identity(opts),
         {:ok, publication} <- normalize_publication(Keyword.get(opts, :publication)) do
      activation_lock(sink_config.slot_name, fn ->
        admit_slot(opts, sink, sink_config, source_identity, publication, owner_pid)
      end)
    end
  end

  defp admit_slot(opts, sink, sink_config, source_identity, publication, owner_pid) do
    key = {AshReplicant, sink_config.slot_name}

    case :persistent_term.get(key, :none) do
      :none ->
        start_with_generation(
          key,
          opts,
          sink,
          sink_config,
          source_identity,
          publication,
          owner_pid
        )

      %Generation{owner: owner} = _entry ->
        admit_or_replace(
          key,
          opts,
          sink,
          sink_config,
          source_identity,
          publication,
          owner_pid,
          owner
        )
    end
  end

  # Live owner = live configuration (reject the duplicate start); dead owner
  # = the stale entry is reaped, together with any orphan pipeline, and
  # replaced by this activation.
  defp admit_or_replace(
         key,
         opts,
         sink,
         sink_config,
         source_identity,
         publication,
         owner_pid,
         owner
       ) do
    if owner_alive?(owner) do
      {:error, :slot_already_active}
    else
      _ = safe_stop(sink_config.slot_name)
      :persistent_term.erase(key)

      start_with_generation(key, opts, sink, sink_config, source_identity, publication, owner_pid)
    end
  end

  defp start_with_generation(
         key,
         opts,
         sink,
         sink_config,
         source_identity,
         publication,
         owner_pid
       ) do
    with {:ok, manifest} <- AshReplicant.Destination.manifest(sink_config),
         {:ok, source_contract} <-
           Identity.build_contract(sink_config, publication),
         {:ok, index} <- AshReplicant.Resolver.build_index(sink_config.domains),
         {:ok, coverage} <-
           Coverage.preflight(
             Keyword.get(opts, :connection),
             source_identity,
             publication,
             sink_config,
             index,
             source_contract.manifest
           ),
         {:ok, dynamic_repo} <-
           AshReplicant.Destination.effective_dynamic_repo(sink_config.repo),
         :ok <- AshReplicant.Destination.preflight_onetime(manifest, dynamic_repo),
         :ok <- AshReplicant.Messages.preflight_digest(sink_config),
         {:ok, code_modules} <- AshReplicant.Destination.code_modules(sink, manifest),
         {:ok, code_fingerprint} <- AshReplicant.Destination.code_fingerprint(code_modules) do
      reference = make_ref()

      runtime = %Generation{
        reference: reference,
        sink: sink,
        sink_config: sink_config,
        sink_config_digest: AshReplicant.Destination.config_digest(sink_config),
        resolver_index: index,
        manifest: manifest,
        manifest_digest: manifest.digest,
        source_contract: source_contract,
        source_connection: Keyword.get(opts, :connection),
        coverage: coverage,
        code_modules: code_modules,
        code_fingerprint: code_fingerprint,
        source_identity: source_identity,
        publication: publication,
        dynamic_repo: dynamic_repo,
        owner: owner_pid
      }

      :persistent_term.put(key, runtime)

      result = safe_start(opts, sink_config.slot_name, sink)

      case result do
        {:ok, pipeline_pid} ->
          {:ok,
           %{
             slot_name: sink_config.slot_name,
             generation_ref: reference,
             pipeline_pid: pipeline_pid
           }}

        _start_failed ->
          erase_generation_key(key, reference)
          result
      end
    end
  end

  defp erase_generation_key(key, generation) do
    case :persistent_term.get(key, :none) do
      %Generation{reference: ^generation} ->
        :persistent_term.erase(key)
        :ok

      _other ->
        :ok
    end
  end

  defp validate_sink(opts) do
    with sink when is_atom(sink) <- Keyword.get(opts, :sink),
         true <- Code.ensure_loaded?(sink),
         true <- function_exported?(sink, :__ash_replicant_config__, 0),
         %{domains: domains, slot_name: slot_name} = config <- safe_sink_config(sink),
         true <- is_list(domains) and is_binary(slot_name) and slot_name != "" do
      {:ok, sink, config}
    else
      _other -> {:error, :sink_required}
    end
  end

  defp run_admitted_callback(slot_name, sink, effect) do
    with %Generation{sink: ^sink, owner: owner} = generation <-
           :persistent_term.get({AshReplicant, slot_name}, :none),
         true <- owner_alive?(owner),
         :ok <- validate_generation(generation),
         {:ok, current_dynamic_repo} <- current_dynamic_repo(generation.sink_config.repo),
         true <-
           AshReplicant.Destination.dynamic_repo_owned_by?(
             generation.sink_config.repo,
             current_dynamic_repo
           ) do
      run_guarded_effect(generation, effect)
    else
      _other -> generation_error(:callback)
    end
  end

  defp run_guarded_effect(generation, effect) do
    with_pinned_dynamic_repo(generation, fn ->
      config = generation_config(generation)

      with :ok <- guard_generation(config) do
        run_effect_and_guard(config, effect)
      end
    end)
  end

  defp run_effect_and_guard(config, effect) do
    result = effect.(config)

    case guard_generation(config) do
      :ok -> result
      {:error, _error} = error -> error
    end
  end

  defp validate_generation(%Generation{} = generation) do
    with %{repo: repo} = current_config <- safe_sink_config(generation.sink),
         true <- current_config == generation.sink_config,
         true <-
           AshReplicant.Destination.config_digest(current_config) ==
             generation.sink_config_digest,
         {:ok, current_manifest} <- AshReplicant.Destination.manifest(current_config),
         true <- current_manifest == generation.manifest,
         true <- current_manifest.digest == generation.manifest_digest,
         {:ok, current_code_fingerprint} <-
           AshReplicant.Destination.code_fingerprint(generation.code_modules),
         true <- current_code_fingerprint == generation.code_fingerprint,
         true <-
           AshReplicant.Destination.dynamic_repo_owned_by?(repo, generation.dynamic_repo) do
      :ok
    else
      _other -> generation_error(:generation)
    end
  end

  defp validate_runtime_config(config, %Generation{} = generation) do
    with true <-
           Enum.all?(generation.sink_config, fn {key, value} -> Map.get(config, key) == value end),
         true <- config.resolver_index == generation.resolver_index,
         true <- config.destination_manifest == generation.manifest,
         true <- config.source_identity == generation.source_identity,
         true <- config.publication == generation.publication,
         true <- config.source_contract == generation.source_contract,
         true <- config.coverage == generation.coverage,
         true <- config.dynamic_repo == generation.dynamic_repo,
         true <- config.data_layer_context == %{repo: generation.dynamic_repo},
         true <- config.authorize? == false do
      :ok
    else
      _other -> generation_error(:runtime_config)
    end
  end

  defp generation_config(%Generation{} = generation) do
    generation.sink_config
    |> Map.merge(%{
      sink: generation.sink,
      resolver_index: generation.resolver_index,
      destination_manifest: generation.manifest,
      source_contract: generation.source_contract,
      source_connection: generation.source_connection,
      coverage: generation.coverage,
      source_identity: generation.source_identity,
      publication: generation.publication,
      generation: generation.reference,
      dynamic_repo: generation.dynamic_repo,
      data_layer_context: %{repo: generation.dynamic_repo},
      authorize?: false
    })
  end

  defp current_dynamic_repo(repo) do
    {:ok, repo.get_dynamic_repo()}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp with_pinned_dynamic_repo(%Generation{} = generation, effect) do
    repo = generation.sink_config.repo
    previous = repo.put_dynamic_repo(generation.dynamic_repo)

    try do
      effect.()
    after
      repo.put_dynamic_repo(previous)
    end
  end

  defp generation_error(op),
    do: {:error, Error.exception(reason: :config_invalid, resource: nil, op: op)}

  defp safe_sink_config(sink) do
    sink.__ash_replicant_config__()
  rescue
    _error -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  defp safe_start(opts, slot_name, sink) do
    opts
    |> Keyword.take(@replicant_option_keys)
    |> Keyword.merge(slot_name: slot_name, sink: sink)
    |> default_messages(sink)
    |> Replicant.start_link()
  rescue
    _error -> {:error, :pipeline_start_failed}
  catch
    _kind, _reason -> {:error, :pipeline_start_failed}
  end

  # C1: a sink that declares a message routing surface gets `messages: true`
  # on the Replicant pipeline automatically (the pgoutput option gates BOTH
  # message kinds at the wire; a routed sink that silently received none would
  # be a config trap). An explicit caller `messages:` opt always wins —
  # including `false`, and including `true` on a route-less sink, which
  # Replicant rejects at start (`:messages_unsupported`) fail-closed.
  defp default_messages(opts, sink) do
    if Keyword.has_key?(opts, :messages) do
      opts
    else
      if function_exported?(sink, :handle_message, 2), do: Keyword.put(opts, :messages, true), else: opts
    end
  end

  defp safe_stop(slot_name) do
    Replicant.stop(slot_name)
  rescue
    _error -> {:error, :pipeline_stop_failed}
  catch
    _kind, _reason -> {:error, :pipeline_stop_failed}
  end

  defp validate_source_identity(opts) do
    opts
    |> Keyword.get(:source_identity)
    |> validate_identity_fields()
  end

  defp validate_identity_fields(identity) do
    with identity when is_list(identity) <- identity,
         {:ok, system_identifier} <- nonempty_binary(Keyword.get(identity, :system_identifier)),
         {:ok, database} <- nonempty_binary(Keyword.get(identity, :database)) do
      {:ok, %{system_identifier: system_identifier, database: database}}
    else
      _other -> {:error, :source_identity_required}
    end
  end

  defp nonempty_binary(value) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty_binary(_value), do: :error

  defp normalize_publication(publication) when is_binary(publication), do: {:ok, [publication]}

  defp normalize_publication(publication) when is_list(publication) and publication != [],
    do: {:ok, publication}

  defp normalize_publication(_publication), do: {:error, :config_invalid}

  # A generation is owned only by a live local owner (ADR-0014): anything
  # else — a dead owner, a foreign pid shape — fails closed at every
  # consumer. Remote pids cannot be checked locally and cannot occur on the
  # single-node runtime Replicant 1.x guarantees; treat them as unowned.
  defp owner_alive?(owner) when is_pid(owner) do
    node(owner) == node() and Process.alive?(owner)
  end

  defp owner_alive?(_other), do: false

  defp activation_lock(slot_name, fun),
    do: :global.trans({{__MODULE__, node(), slot_name}, self()}, fun)
end
