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
    with identity when is_list(identity) <- Keyword.get(opts, :source_identity),
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
