defmodule AshReplicant do
  @moduledoc """
  An Ash-native `Replicant.Sink` adapter. Mirrors a source Postgres database's
  committed CDC changes into AshPostgres resources with effect-once semantics
  (dup = 0, loss = 0), resolving resource, tenant, and classification in the Ash
  layer while keeping `replicant` tenant-blind.

  This is the `ash_postgres`-of-`replicant`: `replicant` is the tenant-blind CDC
  transport; multitenancy and classification live here, one layer up.
  """

  @version Mix.Project.config()[:version]

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
    with {:ok, sink, domains, slot_name} <- validate_sink(opts),
         {:ok, source_identity} <- validate_source_identity(opts),
         {:ok, publication} <- normalize_publication(Keyword.get(opts, :publication)) do
      activation_lock(slot_name, fn ->
        activate(opts, sink, domains, slot_name, source_identity, publication)
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
      result
    end)
  end

  @doc false
  def erase_generation(slot_name, generation),
    do: erase_generation_key({AshReplicant, slot_name}, generation)

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

  defp activate(opts, sink, domains, slot_name, source_identity, publication) do
    key = {AshReplicant, slot_name}

    case :persistent_term.get(key, :none) do
      :none ->
        start_with_generation(
          key,
          opts,
          sink,
          domains,
          slot_name,
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
         domains,
         slot_name,
         source_identity,
         publication
       ) do
    with {:ok, manifest} <- AshReplicant.Destination.manifest(safe_sink_config(sink)),
         {:ok, index} <- AshReplicant.Resolver.build_index(domains) do
      generation = make_ref()

      runtime = %{
        generation: generation,
        resolver_index: index,
        destination_manifest: manifest,
        source_identity: source_identity,
        publication: publication
      }

      :persistent_term.put(key, runtime)

      result = safe_start(opts, slot_name, sink)

      if not match?({:ok, _pid}, result), do: erase_generation_key(key, generation)
      result
    end
  end

  defp erase_generation_key(key, generation) do
    case :persistent_term.get(key, :none) do
      %{generation: ^generation} ->
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
         %{domains: domains, slot_name: slot_name} <- safe_sink_config(sink),
         true <- is_list(domains) and is_binary(slot_name) and slot_name != "" do
      {:ok, sink, domains, slot_name}
    else
      _other -> {:error, :sink_required}
    end
  end

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
