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

  alias AshReplicant.Destination.Generation
  alias AshReplicant.Error
  alias AshReplicant.Sink.Impl

  @doc "The library version string."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Start a CDC pipeline that mirrors into Ash resources. `opts`:

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

  The `slot_name` is NOT a `start_link` option — it is baked into the sink via
  `use AshReplicant.Sink, slot_name: ...` and is the single source of truth for
  both the `:persistent_term` index key and the replication slot.

  Builds the `{schema,table}=>resource` index from the sink's domains, **fails
  closed** on a duplicate or missing source table, caches the index in
  `:persistent_term`, then starts the `replicant` pipeline.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, sink, sink_config} <- validate_sink(opts),
         {:ok, source_identity} <- validate_source_identity(opts),
         {:ok, publication} <- normalize_publication(Keyword.get(opts, :publication)) do
      slot_name = sink_config.slot_name

      activation_lock(slot_name, fn ->
        activate(opts, sink, sink_config, source_identity, publication)
      end)
    end
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

  @doc """
  Adopt a legacy slot-only watermark into a source-bound checkpoint row (the
  explicit operator choice of roadmap B2's legacy policy). Offline: refuses

  > Repo binding: the operator functions write through the CALLER'S current
  > dynamic-repo binding. On a host multiplexing databases through
  > `put_dynamic_repo/1`, call them from a process bound to the destination
  > repo (the same identity the pipeline's admitted generation pins).
  > Offline: refuses
  while the slot has a live pipeline generation, stamps the operator-declared
  ACTUAL source identity and the preserved `commit_lsn`, and leaves the
  contract NULL — the first connect classifies the NULL contract as
  `:initialized` and fills it WITHOUT touching the watermark. Idempotent when
  the identical row already exists; refuses (`:checkpoint_adopt_conflict`)
  when a different identity already owns the slot name. All errors are
  value-free.
  """
  @spec adopt_checkpoint(module(), keyword(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def adopt_checkpoint(sink, source_identity, commit_lsn) do
    with {:ok, config} <- operator_sink(sink),
         {:ok, identity} <- validate_identity_fields(source_identity),
         :ok <- validate_watermark(commit_lsn) do
      activation_lock(config.slot_name, fn ->
        if :persistent_term.get({AshReplicant, config.slot_name}, :none) == :none do
          adopt_row(config, identity, commit_lsn)
        else
          {:error,
           Error.exception(reason: :config_invalid, resource: nil, op: :slot_already_active)}
        end
      end)
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
      activation_lock(config.slot_name, fn ->
        if :persistent_term.get({AshReplicant, config.slot_name}, :none) == :none do
          reset_row(config, identity)
        else
          {:error,
           Error.exception(reason: :config_invalid, resource: nil, op: :slot_already_active)}
        end
      end)
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
      activation_lock(config.slot_name, fn ->
        if :persistent_term.get({AshReplicant, config.slot_name}, :none) == :none do
          acknowledge_timeline(config, identity, timeline_id)
        else
          {:error,
           Error.exception(reason: :config_invalid, resource: nil, op: :slot_already_active)}
        end
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
          [] ->
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

          [row] ->
            same_triple =
              row.source_system_id == filter.source_system_id and
                row.source_database == filter.source_database and
                row.slot_name == filter.slot_name

            cond do
              not same_triple ->
                config.repo.rollback(
                  Error.exception(
                    reason: :checkpoint_adopt_conflict,
                    resource: config.checkpoint_resource,
                    op: :adopt
                  )
                )

              # Idempotence requires the IDENTICAL row: a different watermark is
              # a mismatched adoption — refuse rather than silently keep the
              # first (or overwrite the durable one).
              not is_nil(commit_lsn) and row.commit_lsn != commit_lsn ->
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

          _many ->
            config.repo.rollback(
              Error.exception(
                reason: :checkpoint_adopt_conflict,
                resource: config.checkpoint_resource,
                op: :adopt
              )
            )
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      {:error, other} -> {:error, Error.scrub(other, config.checkpoint_resource, :adopt)}
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

    case result do
      {:ok, :ok} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      {:error, other} -> {:error, Error.scrub(other, config.checkpoint_resource, :reset)}
    end
  end

  defp acknowledge_timeline(config, identity, timeline_id) do
    filter = checkpoint_identity_filter(config, identity)

    result =
      config.repo.transaction(fn ->
        case locked_triple_rows(config, filter) do
          [%{source_timeline: stored}] = rows when is_integer(stored) ->
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

    case result do
      {:ok, :ok} ->
        :ok

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, other} ->
        {:error, Error.scrub(other, config.checkpoint_resource, :acknowledge_timeline)}
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
    :streaming,
    :max_inflight_lag,
    :max_command_retries,
    :failover
  ]

  defp activate(opts, sink, sink_config, source_identity, publication) do
    slot_name = sink_config.slot_name
    key = {AshReplicant, slot_name}

    case :persistent_term.get(key, :none) do
      :none ->
        start_with_generation(
          key,
          opts,
          sink,
          sink_config,
          source_identity,
          publication
        )

      _active_generation ->
        {:error, :slot_already_active}
    end
  end

  defp start_with_generation(
         key,
         opts,
         sink,
         sink_config,
         source_identity,
         publication
       ) do
    with {:ok, manifest} <- AshReplicant.Destination.manifest(sink_config),
         {:ok, source_contract} <-
           AshReplicant.Checkpoint.Identity.build_contract(sink_config, publication),
         {:ok, index} <- AshReplicant.Resolver.build_index(sink_config.domains),
         {:ok, dynamic_repo} <-
           AshReplicant.Destination.effective_dynamic_repo(sink_config.repo),
         :ok <- AshReplicant.Destination.preflight_onetime(manifest, dynamic_repo),
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
        code_modules: code_modules,
        code_fingerprint: code_fingerprint,
        source_identity: source_identity,
        publication: publication,
        dynamic_repo: dynamic_repo
      }

      :persistent_term.put(key, runtime)

      result = safe_start(opts, sink_config.slot_name, sink)

      if not match?({:ok, _pid}, result), do: erase_generation_key(key, reference)
      result
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
    with %Generation{sink: ^sink} = generation <-
           :persistent_term.get({AshReplicant, slot_name}, :none),
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
    |> Replicant.start_link()
  rescue
    _error -> {:error, :pipeline_start_failed}
  catch
    _kind, _reason -> {:error, :pipeline_start_failed}
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

  defp activation_lock(slot_name, fun),
    do: :global.trans({{__MODULE__, node(), slot_name}, self()}, fun)
end
