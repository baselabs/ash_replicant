defmodule AshReplicant.Sink.Impl do
  @moduledoc """
  The config-parameterized sink implementation the `use AshReplicant.Sink`
  macro delegates to. `handle_transaction/2` is the effect-once core: one
  `Repo.transaction` wrapping {dedup-check → single-pass apply → checkpoint
  upsert}, value-free and fail-closed.

  Mirrored writes run inside the host transaction and pass
  `return_notifications?: true`, so Ash bundles any notification into the return
  value (never firing a notifier) and the sink discards it — Ash notifiers/pubsub
  do NOT fire for mirrored changes. (Ash cannot emit notifications from within a
  host-managed transaction anyway; `notify?: false` is not honored by
  single-record create/destroy in Ash 3.x, only `return_notifications?`.)
  """

  alias AshPostgres.DataLayer.Info, as: PGInfo
  alias AshReplicant.{Apply, Error, Resolver, Telemetry}
  alias AshReplicant.Resource.Info
  alias Ecto.Adapters.SQL

  @doc "Last durably-persisted commit LSN for the slot (`nil` = never), the dedup watermark."
  @spec checkpoint(map()) :: {:ok, Replicant.lsn() | nil} | {:error, term()}
  def checkpoint(config) do
    {:ok, read_checkpoint(config)}
  rescue
    e -> {:error, Error.scrub(e, config.checkpoint_resource, :checkpoint)}
  end

  @doc """
  Persist the transaction's changes AND the checkpoint atomically; skip if
  `commit_lsn <= checkpoint`. Returns `{:ok, commit_lsn}` or a value-free
  `{:error, %AshReplicant.Error{}}` (the pipeline halts fail-closed and
  re-delivers on resume).

  `Apply.apply_change/2` RAISES on failure, so a failing change propagates out of
  `Repo.transaction` (Ecto rolls back, then re-raises) and lands on the outer
  `rescue` — NOT the `{:error, _}` branch of the result match. Both halt paths
  route through `halt/2`, so `:halted` telemetry fires on the real raise path too.
  """
  @spec handle_transaction(map(), Replicant.Transaction.t()) ::
          {:ok, Replicant.lsn()} | {:error, term()}
  def handle_transaction(config, %Replicant.Transaction{commit_lsn: lsn, changes: changes}) do
    if empty_index?(config) do
      # Fail closed: an absent/empty resolver index (start_link not run, slot
      # mismatch, degenerate config) would resolve every change to `nil` in
      # Apply — silently dropping ALL rows while still advancing the checkpoint,
      # i.e. PERMANENT, INVISIBLE loss. Halt BEFORE the txn so the checkpoint
      # never advances and the LSN is re-delivered on resume.
      halt(Error.exception(reason: :config_invalid, resource: nil, op: :sink), config)
    else
      run_transaction(config, lsn, changes)
    end
  rescue
    e -> halt(e, config)
  end

  # The empty-resolver-index fail-closed guard. Shared by ALL delivery entry
  # points (transaction, snapshot, snapshot-complete): the same degenerate index
  # that silently drops streaming rows would silently drop a whole backfill AND
  # advance the checkpoint past it (permanent, invisible loss) — the snapshot
  # path must fail closed identically, never "complete" a snapshot that mirrored
  # nothing. (An index with entries but no target for ONE table is a legitimate
  # partial-publication skip, handled per-table below; only the WHOLESALE-empty
  # index is a misconfiguration.)
  defp empty_index?(config), do: map_size(config.resolver_index) == 0

  @doc """
  Accept or decline a schema change. An `:additive` change auto-applies; a
  `:destructive` change on a resource whose `on_schema_change` is
  `:halt_destructive` (default) halts fail-closed. The context map is not
  value-inspected. Unmapped tables use the behaviour default.
  """
  @spec handle_schema_change(map(), Replicant.SchemaChange.t(), map()) :: :ok | {:error, term()}
  def handle_schema_change(config, %Replicant.SchemaChange{kind: kind} = sc, _ctx) do
    resource = Map.get(config.resolver_index, {sc.schema || "public", sc.table})

    policy =
      if resource,
        do: Info.replicant_on_schema_change!(resource),
        else: :halt_destructive

    case {kind, policy} do
      {:additive, _} ->
        :ok

      {:destructive, :ignore} ->
        :ok

      {:destructive, :halt_destructive} ->
        {:error,
         Error.exception(
           reason: :schema_change_destructive,
           resource: resource,
           op: :schema_change,
           shape: "#{sc.schema || "public"}.#{sc.table}"
         )}
    end
  end

  @doc """
  Persist a snapshot batch for `ctx.table`, upserting by PK. On
  `first_for_table?`, clear the resource's mirror rows in-txn first (redo-safety).
  Non-tenant resources use a bulk upsert; the load-bearing fail-closed guard is
  the `case result.status` check — anything other than `:success` (including the
  default-options `:partial_success`) rolls the snapshot transaction back, so a
  failing row is never silently dropped. `stop_on_error?: true` is a defensible
  early-stop on top of that, not the loss guard. Tenant-scoped (and, defensively,
  sensitive) resources apply per-record. Does not advance the checkpoint.
  """
  @spec handle_snapshot(map(), [Replicant.Change.t()], map()) :: :ok | {:error, term()}
  def handle_snapshot(config, changes, %{table: qualified, first_for_table?: first?} = _ctx) do
    if empty_index?(config) do
      {:error, Error.exception(reason: :config_invalid, resource: nil, op: :snapshot)}
    else
      {schema, table} =
        case String.split(qualified, ".", parts: 2) do
          [s, t] -> {s, t}
          [t] -> {"public", t}
        end

      resource = Map.get(config.resolver_index, {schema, table})

      if is_nil(resource), do: :ok, else: run_snapshot(config, resource, changes, first?)
    end
  rescue
    e -> {:error, Error.scrub(e, nil, :snapshot)}
  end

  defp run_snapshot(config, resource, changes, first?) do
    config.repo.transaction(fn ->
      if first?, do: clear_mirror(resource, config)
      apply_snapshot_batch(config, resource, changes)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, %Error{} = e} -> {:error, e}
      {:error, other} -> {:error, Error.scrub(other, resource, :snapshot)}
    end
  end

  @doc "Durably set `checkpoint := snapshot_lsn` and return it (the snapshot handoff commit)."
  @spec handle_snapshot_complete(map(), Replicant.lsn()) ::
          {:ok, Replicant.lsn()} | {:error, term()}
  def handle_snapshot_complete(config, snapshot_lsn) do
    if empty_index?(config) do
      # Fail closed: never advance the checkpoint to "complete" a snapshot that
      # mirrored nothing because the index was empty — that locks in invisible loss.
      {:error, Error.exception(reason: :config_invalid, resource: nil, op: :snapshot_complete)}
    else
      config.repo.transaction(fn -> upsert_checkpoint(config, snapshot_lsn) end)
      |> case do
        {:ok, _} ->
          {:ok, snapshot_lsn}

        {:error, other} ->
          {:error, Error.scrub(other, config.checkpoint_resource, :snapshot_complete)}
      end
    end
  rescue
    e -> {:error, Error.scrub(e, config.checkpoint_resource, :snapshot_complete)}
  end

  defp clear_mirror(resource, config) do
    # Redo-safety: wipe ALL mirror rows for this resource before re-applying the
    # snapshot dump. A tenant-scoped Ash.bulk_destroy! cannot clear a NON-GLOBAL
    # attribute-multitenant table (raises TenantRequired), so delete tenant-blind
    # on the mirror's own table, inside the snapshot transaction. Works uniformly
    # for non-tenant, global-tenant, and non-global-tenant resources. The table /
    # schema come from the resource DSL (operator trust boundary, like
    # maybe_append_ledger), not from a row value.
    schema = PGInfo.schema(resource) || "public"
    table = PGInfo.table(resource)
    SQL.query!(config.repo, ~s(DELETE FROM "#{schema}"."#{table}"), [])
  end

  defp apply_snapshot_batch(_config, _resource, []), do: :ok

  defp apply_snapshot_batch(config, resource, changes) do
    # The load-bearing driver of the split is `tenant_scoped?`: a single bulk
    # upsert carries one `tenant:`, so a mixed-tenant batch cannot go through bulk
    # — it MUST apply per-record, each row under its own resolved tenant.
    # `sensitive?` also routes per-record, but that is belt-and-suspenders:
    # `Ash.bulk_create` fires AshCloak's before_action too (bulk encrypts), so the
    # per-record path is conservative here, not a plaintext-leak guard.
    if sensitive?(resource) or tenant_scoped?(resource) do
      Enum.each(changes, fn c -> Apply.apply_change(config, %{c | op: :insert}) end)
    else
      inputs =
        Enum.map(changes, fn c -> elem(Resolver.attrs_for_upsert(resource, c.record), 0) end)

      # `upsert_fields` is taken from row 1 — valid because a full-table snapshot
      # dump is column-homogeneous (every row carries the same source columns).
      {_, upsert_fields} = Resolver.attrs_for_upsert(resource, List.first(changes).record)

      result =
        Ash.bulk_create(inputs, resource, Resolver.upsert_action(resource),
          upsert?: true,
          upsert_identity: Resolver.upsert_identity(resource),
          upsert_fields: upsert_fields,
          stop_on_error?: true,
          return_errors?: true,
          return_records?: false,
          return_notifications?: true,
          authorize?: config.authorize?,
          transaction: false
        )

      case result.status do
        :success ->
          :ok

        _ ->
          config.repo.rollback(
            Error.exception(reason: :sink_failed, resource: resource, op: :snapshot)
          )
      end
    end
  end

  defp sensitive?(resource) do
    Info.replicant_sensitive!(resource) != []
  end

  defp tenant_scoped?(resource) do
    match?({:ok, _}, Info.replicant_tenant_attribute(resource)) or
      match?({:ok, _}, Info.replicant_tenant_mfa(resource))
  end

  defp run_transaction(config, lsn, changes) do
    result =
      config.repo.transaction(fn ->
        case read_checkpoint(config) do
          cp when is_integer(cp) and lsn <= cp ->
            :skipped

          _ ->
            # Single pass: `changes` may be a spilled txn's lazy, single-pass
            # Enumerable — iterate it exactly once, never sort/count/to_list.
            Enum.each(changes, &Apply.apply_change(config, &1))
            upsert_checkpoint(config, lsn)
            maybe_append_ledger(config, lsn)
            :applied
        end
      end)

    case result do
      {:ok, :applied} ->
        Telemetry.event([:ash_replicant, :sink, :applied], %{}, %{commit_lsn: lsn})
        {:ok, lsn}

      {:ok, :skipped} ->
        Telemetry.event([:ash_replicant, :sink, :skipped], %{}, %{commit_lsn: lsn})
        {:ok, lsn}

      {:error, reason} ->
        halt(reason, config)
    end
  end

  # Value-free fail-closed halt: scrub to a structural reason, emit `:halted`
  # (reason atom only — never a row value), return the scrubbed error.
  defp halt(reason, config) do
    error = Error.scrub(reason, config.checkpoint_resource, :sink)
    Telemetry.event([:ash_replicant, :sink, :halted], %{}, %{reason: error.reason})
    {:error, error}
  end

  defp read_checkpoint(config) do
    case Ash.get!(config.checkpoint_resource, config.slot_name,
           authorize?: false,
           error?: false
         ) do
      nil -> nil
      %{commit_lsn: lsn} -> lsn
    end
  end

  defp upsert_checkpoint(config, lsn) do
    Ash.create!(config.checkpoint_resource, %{slot_name: config.slot_name, commit_lsn: lsn},
      action: :upsert,
      upsert?: true,
      upsert_identity: :unique_slot,
      upsert_fields: [:commit_lsn],
      authorize?: false,
      return_notifications?: true
    )
  end

  # Test-only append-only ledger (config[:apply_ledger] = table name) for the dup=0
  # proof (Task 15). Appends inside the sink transaction, so it rolls back with a
  # failed txn and appends exactly once per applied txn. Dormant unless configured.
  defp maybe_append_ledger(%{apply_ledger: table} = config, lsn) when is_binary(table) do
    SQL.query!(config.repo, "INSERT INTO #{table} (commit_lsn) VALUES ($1)", [lsn])
  end

  defp maybe_append_ledger(_config, _lsn), do: :ok
end
