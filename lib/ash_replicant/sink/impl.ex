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

  `Apply.apply_change/3` RAISES on failure, so a failing change propagates out of
  `Repo.transaction` (Ecto rolls back, then re-raises) and lands on the outer
  `rescue` — NOT the `{:error, _}` branch of the result match. Both halt paths
  route through `halt/2`, so `:halted` telemetry fires on the real raise path too.
  """
  @spec handle_transaction(map(), Replicant.Transaction.t()) ::
          {:ok, Replicant.lsn()} | {:error, term()}
  def handle_transaction(config, %Replicant.Transaction{
        commit_lsn: lsn,
        commit_timestamp: ts,
        changes: changes
      }) do
    if empty_index?(config) do
      # Fail closed: an absent/empty resolver index (start_link not run, slot
      # mismatch, degenerate config) would resolve every change to `nil` in
      # Apply — silently dropping ALL rows while still advancing the checkpoint,
      # i.e. PERMANENT, INVISIBLE loss. Halt BEFORE the txn so the checkpoint
      # never advances and the LSN is re-delivered on resume.
      halt(Error.exception(reason: :config_invalid, resource: nil, op: :sink), config)
    else
      run_transaction(config, lsn, ts, changes)
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
    resource = Resolver.lookup(config.resolver_index, sc.schema, sc.table)

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
  Plain SCD1 non-tenant, non-sensitive resources use a bulk upsert; the
  load-bearing fail-closed guard is the `case result.status` check — anything
  other than `:success` (including the default-options `:partial_success`) rolls
  the snapshot transaction back, so a failing row is never silently dropped.
  `stop_on_error?: true` is a defensible early-stop on top of that, not the loss
  guard. Sensitive, tenant-scoped, OR SCD2 resources apply per-record — SCD2
  stamps the batch's snapshot LSN onto each change so each version opens at
  `valid_from_lsn = snapshot_lsn`. Does not advance the checkpoint.

  This sink implements replicant's v1 snapshot only (no `snapshot_progress/0`
  callback). The whole-resource `first_for_table?` clear is correct under v1
  because the snapshot runs as a separate phase before the stream starts
  (EXPORT_SNAPSHOT -> COPY -> START_REPLICATION at the consistent_point), so
  there are no concurrent `handle_transaction` rows to wipe when the clear
  runs. If/when this sink adopts replicant's incremental snapshot mode
  (`snapshot: [mode: :incremental]`, which requires implementing
  `snapshot_progress/0` and interleaves snapshot chunks with the live stream),
  this clear must change to preserve stream-applied rows (clear only
  snapshot-origin rows) — otherwise a stream update that lands before the
  first chunk closes is lost (replicant incremental "Bug C", proven by the
  replicant marquee 2026-07-10).
  """
  @spec handle_snapshot(map(), [Replicant.Change.t()], map()) :: :ok | {:error, term()}
  def handle_snapshot(config, changes, %{table: qualified, first_for_table?: first?} = ctx) do
    if empty_index?(config) do
      {:error, Error.exception(reason: :config_invalid, resource: nil, op: :snapshot)}
    else
      {schema, table} =
        case String.split(qualified, ".", parts: 2) do
          [s, t] -> {s, t}
          [t] -> {"public", t}
        end

      case Resolver.lookup(config.resolver_index, schema, table) do
        # Unmapped table = legitimate partial-publication skip (no batch applied).
        nil -> :ok
        resource -> run_snapshot_batch(config, resource, changes, first?, table, ctx)
      end
    end
  rescue
    e -> {:error, Error.scrub(e, nil, :snapshot)}
  end

  defp run_snapshot_batch(config, resource, changes, first?, table, ctx) do
    snapshot_lsn = Map.get(ctx, :snapshot_lsn)

    with :ok <- run_snapshot(config, resource, changes, first?, snapshot_lsn) do
      # Snapshot changes are a materialized list (the bulk path indexes them via
      # List.first), so counting is single-pass-safe here — unlike the streaming
      # path's lazy Enumerable.
      Telemetry.event(
        [:ash_replicant, :snapshot, :batch],
        %{change_count: Enum.count(changes)},
        %{table: table, commit_lsn: snapshot_lsn}
      )

      :ok
    end
  end

  defp run_snapshot(config, resource, changes, first?, snapshot_lsn) do
    config.repo.transaction(fn ->
      if first?, do: clear_mirror(resource, config)
      apply_snapshot_batch(config, resource, changes, snapshot_lsn)
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
          Telemetry.event([:ash_replicant, :snapshot, :complete], %{}, %{commit_lsn: snapshot_lsn})

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

  defp apply_snapshot_batch(_config, _resource, [], _snapshot_lsn), do: :ok

  defp apply_snapshot_batch(config, resource, changes, snapshot_lsn) do
    # The load-bearing driver of the split is `tenant_scoped?`: a single bulk
    # upsert carries one `tenant:`, so a mixed-tenant batch cannot go through bulk
    # — it MUST apply per-record, each row under its own resolved tenant.
    # `sensitive?` also routes per-record, but that is belt-and-suspenders:
    # `Ash.bulk_create` fires AshCloak's before_action too (bulk encrypts), so the
    # per-record path is conservative here, not a plaintext-leak guard.
    # `history_scd2?` MUST route per-record too: a bulk upsert of the source columns
    # can't open a validity window (the NOT-NULL window columns are unpopulated) — the
    # SCD2 apply path opens one current version per row, stamping `valid_from_lsn` from
    # the change's `commit_lsn`. Snapshot changes carry `commit_lsn: nil`, so thread the
    # batch's `snapshot_lsn` onto each change; it is INERT for the SCD1 sensitive/tenant
    # per-record upsert (which reads only `change.record`).
    if sensitive?(resource) or tenant_scoped?(resource) or Info.history_scd2?(resource) do
      Enum.each(changes, fn c ->
        Apply.apply_change(config, %{c | op: :insert, commit_lsn: snapshot_lsn})
      end)
    else
      # Compute the batch-invariant reflection ONCE (F13): every row of a full-table
      # snapshot dump is column-homogeneous, so `skip`/cloak/attribute-name derivation
      # is invariant across the batch — hoist it above the per-row map.
      reflection = Resolver.upsert_reflection(resource)
      mapped = Enum.map(changes, fn c -> Resolver.upsert_input(reflection, c.record) end)
      inputs = Enum.map(mapped, &elem(&1, 0))

      # `upsert_fields` is taken from row 1 — valid because a full-table snapshot
      # dump is column-homogeneous (every row carries the same source columns).
      {_inputs, upsert_fields} = List.first(mapped)

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

  defp run_transaction(config, lsn, ts, changes) do
    started = System.monotonic_time()

    result =
      config.repo.transaction(fn ->
        case read_checkpoint(config) do
          cp when is_integer(cp) and lsn <= cp ->
            :skipped

          _ ->
            count = apply_all(config, changes, ts)
            upsert_checkpoint(config, lsn)
            maybe_append_ledger(config, lsn)
            {:applied, count}
        end
      end)

    case result do
      {:ok, {:applied, count}} ->
        Telemetry.event(
          [:ash_replicant, :sink, :applied],
          %{change_count: count, duration: System.monotonic_time() - started},
          %{commit_lsn: lsn}
        )

        {:ok, lsn}

      {:ok, :skipped} ->
        Telemetry.event([:ash_replicant, :sink, :skipped], %{}, %{commit_lsn: lsn})
        {:ok, lsn}

      {:error, reason} ->
        halt(reason, config)
    end
  end

  # Single pass over the (possibly lazy, one-shot) change stream — iterate it EXACTLY
  # once, counting DURING the pass so `change_count` needs no second traversal (an
  # `Enum.count`/`length` would re-enumerate and blow up a spilled-txn stream).
  defp apply_all(config, changes, ts) do
    Enum.reduce(changes, 0, fn change, n ->
      Apply.apply_change(config, change, ts)
      n + 1
    end)
  end

  # Value-free fail-closed halt: scrub to a structural reason, emit `:halted`
  # (reason atom only — never a row value), return the scrubbed error.
  defp halt(reason, config) do
    error = Error.scrub(reason, config.checkpoint_resource, :sink)

    Telemetry.event([:ash_replicant, :sink, :halted], %{}, %{
      reason: error.reason,
      error_class: error.class
    })

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
    SQL.query!(config.repo, "INSERT INTO \"#{table}\" (commit_lsn) VALUES ($1)", [lsn])
  end

  defp maybe_append_ledger(_config, _lsn), do: :ok
end
