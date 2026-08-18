defmodule AshReplicant.Sink.Impl do
  @moduledoc """
  The config-parameterized sink implementation the `use AshReplicant.Sink`
  macro delegates to. `handle_transaction/2` is the effect-once core: one
  `Repo.transaction` wrapping {dedup-check → single-pass apply → checkpoint
  upsert}, value-free and fail-closed.

  Mirrored creates and SCD2 updates run inside the host transaction with
  `return_notifications?: true`, so Ash bundles notifications into the return
  value and the sink discards them. Mirrored bulk destroys use Ash's default
  `notify?: false`. Ash notifiers/pubsub therefore do not fire for mirrored
  changes; the mechanisms differ by action path.

  Suppression is DISPATCH-only (U3/D2): Ash runs a notifier's `load/2`
  dependency pre-load read inside the delivery path regardless of any notify
  gate — including the snapshot `bulk_create` under `return_records?: false`
  (the sink passes `return_notifications?: true`, keeping the pre-load
  alive). A load-carrying notifier therefore executes host reads inside the
  admitted transaction; the destination manifest requires such notifiers to
  declare `DestinationParticipant` (the `:notifier` kind), admitting those
  reads into the graph — the same trust model as `tenant_mfa`.
  """

  alias AshPostgres.DataLayer.Info, as: PGInfo
  alias AshReplicant.{Apply, Destination, Error, Messages, Resolver, Sql, Telemetry}
  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Resource.Info
  alias Ecto.Adapters.SQL

  @snapshot_transaction_timeout 120_000

  @doc false
  def handle_session_identity(
        %{
          slot_name: expected_slot,
          publication: expected_publication,
          source_identity: %{
            system_identifier: expected_system,
            database: expected_database
          }
        } = config,
        %Replicant.SessionIdentity{
          system_identifier: expected_system,
          database: expected_database
        } = identity,
        %{slot_name: expected_slot, publication: expected_publication}
      ) do
    # The verdict event stays AT the verdict point, BEFORE any bind write —
    # the first-event ordering red gate depends on it.
    Telemetry.event([:ash_replicant, :sink, :session_identity_accepted], %{}, %{})

    bind_session(config, identity)
  end

  def handle_session_identity(_config, _identity, _context),
    do: {:error, :source_identity_mismatch}

  # Durable source-bound binding (roadmap B2). Runs on EVERY connect/reconnect,
  # inside the identity callback (the only place the ACTUAL session identity is
  # in hand — a separate connection is the rejected TOCTOU class) and BEFORE any
  # checkpoint read. Sequence (sibling-read-first — see the design note): lock
  # the slot's rows, halt on a foreign triple (the shipped unique slot index is
  # the cross-node race backstop), then bind-or-classify the source contract.
  defp bind_session(config, %Replicant.SessionIdentity{} = identity) do
    contract = config.source_contract

    # The reconnect coverage re-check (adversarial C2): a mapped table dropped
    # from the publication mid-run has NO streaming signal; the bind re-check
    # (rule-2/3 subset) catches it on every transport blip, BEFORE any
    # checkpoint read. Runs on the short-lived source connection from the
    # generation (outside the destination transaction — a catalog read).
    with :ok <- reconnect_coverage_check(config) do
      result =
        config.repo.transaction(
          fn -> bind_slot_rows!(config, identity, contract) end,
          timeout: @snapshot_transaction_timeout
        )

      scrub_bind_result(result, config)
    end
  rescue
    e -> {:error, Error.scrub(e, config.checkpoint_resource, :bind)}
  catch
    # D3: `rescue` misses :throw/:exit (DBConnection re-raises them after
    # rollback). The catch routes them into the SAME scrub — value-free on
    # every fault shape, not just raises.
    :throw, value -> {:error, Error.scrub_caught(value, config.checkpoint_resource, :bind)}
    :exit, value -> {:error, Error.scrub_caught(value, config.checkpoint_resource, :bind)}
  end

  # The rule-2/3 subset on the source catalog: every mapped table published,
  # every publication table mapped or ignored. Identity-verified short-lived
  # connection (the same preflight machinery); catalog faults defer to the
  # destination-transaction bind (an unreachable source cannot stream anyway).
  # The bind's destination-transaction body: admit under the row lock.
  defp bind_slot_rows!(config, identity, contract) do
    guard_generation!(config)

    case locked_slot_rows(config) do
      [] ->
        insert_bound_row!(config, identity, contract)

      [row] ->
        verify_and_adapt_row!(config, identity, contract, row)

      _many ->
        # Multiple rows under one slot cannot occur past the unique slot
        # index; a read here means the index was dropped. Fail closed.
        rollback_conflict!(config, :source_identity_rebound)
    end

    guard_generation!(config)
    :ok
  end

  defp scrub_bind_result(result, config) do
    case result do
      {:ok, :ok} ->
        :ok

      # A Repo.rollback'd %Error{} is host-buildable inside the bind
      # transaction — scrub it like every other fault shape (the rollback
      # verb of the forged-struct class; raise/throw already covered).
      {:error, %Error{} = error} ->
        {:error, Error.scrub(error, config.checkpoint_resource, :bind)}

      {:error, other} ->
        {:error, Error.scrub(other, config.checkpoint_resource, :bind)}
    end
  end

  defp reconnect_coverage_check(config) do
    connection = Map.get(config, :source_connection) || []

    AshReplicant.Coverage.reconnect_check(
      connection,
      config.source_identity,
      config.publication,
      config.resolver_index,
      config.source_contract.manifest
    )
  end

  defp locked_slot_rows(config) do
    import Ash.Query, only: [filter: 2]

    config.checkpoint_resource
    |> filter(slot_name == ^config.slot_name)
    |> Ash.read!(
      lock: :for_update,
      authorize?: false,
      context: action_context(config)
    )
    |> List.wrap()
  end

  defp insert_bound_row!(config, identity, contract) do
    write_bound_contract!(config, identity, contract, %{commit_lsn: nil})
    :ok
  end

  defp verify_and_adapt_row!(config, identity, contract, row) do
    with :ok <- verify_same_triple!(config, row),
         :ok <- verify_timeline!(config, identity, row),
         :ok <- verify_liveness!(config, identity, row) do
      classify_and_store_contract!(config, identity, contract, row)
    else
      {:error, %Error{}} = error -> config.repo.rollback(error)
    end
  end

  defp verify_same_triple!(config, row) do
    filter = checkpoint_filter(config)

    if row.source_system_id == filter.source_system_id and
         row.source_database == filter.source_database and row.slot_name == filter.slot_name do
      :ok
    else
      rollback_conflict!(config, :source_identity_rebound)
    end
  end

  defp verify_timeline!(config, %Replicant.SessionIdentity{timeline_id: timeline}, row) do
    if is_nil(row.source_timeline) or row.source_timeline == timeline do
      :ok
    else
      rollback_conflict!(config, :source_timeline_changed)
    end
  end

  defp verify_liveness!(
         config,
         %Replicant.SessionIdentity{current_lsn: current},
         row
       ) do
    if is_integer(row.commit_lsn) and is_integer(current) and row.commit_lsn > current do
      rollback_conflict!(config, :source_behind_watermark)
    else
      :ok
    end
  end

  defp classify_and_store_contract!(config, identity, contract, row) do
    stored_manifest = decode_stored_manifest(row.publication_contract)

    cond do
      stored_manifest == :error ->
        rollback_conflict!(config, :publication_contract_incompatible, "reason=decode_failed")

      is_nil(stored_manifest) ->
        # Adopted row (task 5) or a pre-contract row: initialize without
        # touching the watermark.
        write_bound_contract!(config, identity, contract, %{})
        :ok

      stored_manifest == contract.manifest and row.source_timeline == identity.timeline_id ->
        # Steady-state reconnect: verify-only, NO write.
        :ok

      true ->
        store_classified_contract!(config, identity, contract, stored_manifest)
    end
  end

  # An undecodable stored contract is the tamper/decode-fault class — never a
  # silent re-initialization (nil, below, is the only legitimate "no contract").
  defp decode_stored_manifest(nil), do: nil

  defp decode_stored_manifest(binary) do
    case Identity.decode(binary) do
      {:ok, manifest} -> manifest
      :error -> :error
    end
  end

  defp store_classified_contract!(config, identity, contract, stored_manifest) do
    case Identity.classify(stored_manifest, contract.manifest) do
      {:incompatible, reason} ->
        rollback_conflict!(
          config,
          :publication_contract_incompatible,
          "reason=" <> inspect(reason)
        )

      _compatible_or_equal ->
        write_bound_contract!(config, identity, contract, %{})
        :ok
    end
  end

  defp write_bound_contract!(config, identity, contract, extra) do
    Ash.create!(
      config.checkpoint_resource,
      Map.merge(
        Map.merge(checkpoint_filter(config), extra),
        %{
          source_timeline: identity.timeline_id,
          publication_contract: contract.encoded,
          publication_fingerprint: contract.fingerprint
        }
      ),
      action: :upsert,
      upsert?: true,
      upsert_identity: :source_slot,
      upsert_fields: [:source_timeline, :publication_contract, :publication_fingerprint],
      authorize?: false,
      context: action_context(config),
      return_notifications?: true
    )

    :ok
  end

  defp rollback_conflict!(config, reason, shape \\ nil) do
    error =
      Error.exception(
        reason: reason,
        resource: config.checkpoint_resource,
        op: :bind,
        shape: shape
      )

    Telemetry.event(
      [:ash_replicant, :checkpoint, :conflict],
      %{count: 1},
      %{reason: reason, error_class: error.class}
    )

    config.repo.rollback(error)
  end

  @doc "Last durably-persisted commit LSN for the slot (`nil` = never), the dedup watermark."
  @spec checkpoint(map()) :: {:ok, Replicant.lsn() | nil} | {:error, term()}
  def checkpoint(config) do
    {:ok, read_checkpoint(config)}
  rescue
    e -> {:error, Error.scrub(e, config.checkpoint_resource, :checkpoint)}
  catch
    :throw, value -> {:error, Error.scrub_caught(value, config.checkpoint_resource, :checkpoint)}
    :exit, value -> {:error, Error.scrub_caught(value, config.checkpoint_resource, :checkpoint)}
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
  def handle_transaction(
        config,
        %Replicant.Transaction{
          commit_lsn: lsn,
          commit_timestamp: ts,
          changes: changes,
          messages: messages
        }
      ) do
    if empty_index?(config) do
      # Fail closed: an absent/empty resolver index (start_link not run, slot
      # mismatch, degenerate config) would resolve every change to `nil` in
      # Apply — silently dropping ALL rows while still advancing the checkpoint,
      # i.e. PERMANENT, INVISIBLE loss. Halt BEFORE the txn so the checkpoint
      # never advances and the LSN is re-delivered on resume.
      halt(Error.exception(reason: :config_invalid, resource: nil, op: :sink), config)
    else
      run_transaction(config, lsn, ts, changes, messages || [])
    end
  rescue
    e -> halt(e, config)
  catch
    # D3: throw/exit reach the same halt path — scrubbed, :halted fired.
    :throw, value -> halt(value, config)
    :exit, value -> halt(value, config)
  end

  # The empty-resolver-index fail-closed guard. Shared by ALL delivery entry
  # points (transaction, batch, snapshot, snapshot-complete): the same degenerate index
  # that silently drops streaming rows would silently drop a whole backfill AND
  # advance the checkpoint past it (permanent, invisible loss) — the snapshot
  # path must fail closed identically, never "complete" a snapshot that mirrored
  # nothing. (An index with entries but no target for ONE table is a legitimate
  # partial-publication skip, handled per-table below; only the WHOLESALE-empty
  # index is a misconfiguration.)
  defp empty_index?(config), do: map_size(config.resolver_index) == 0

  @doc """
  Deliver a BATCH of committed transactions as ONE atomic unit (C2/ADR-0016,
  the eighth sink boundary body). The transactions arrive in ascending
  `commit_lsn` order; the body applies them and their transactional messages
  through the SAME single-pass core as `handle_transaction/2`, then persists
  `checkpoint := the batch's highest commit_lsn` AFTER all effects — one
  destination transaction, one watermark write, effect-once (dup = 0) across
  a mid-batch teardown. Any frontier at/below the locked watermark skips (the
  whole batch when the highest LSN is stale). A fault in ANY transaction rolls
  back EVERY transaction's effects and advances nothing — fail-closed,
  value-free (rescue AND catch, like every boundary body). A lazy spilled
  transaction's `changes` is enumerated exactly once, never materialized.
  """
  @spec handle_batch(map(), [Replicant.Transaction.t()]) ::
          {:ok, Replicant.lsn() | nil} | {:error, term()}
  def handle_batch(config, transactions) do
    cond do
      # The framework never flushes an empty batch (a nil pending_lsn
      # short-circuits to :empty); the no-op keeps the frozen-arity callback
      # from crashing on a future caller's shape.
      transactions == [] ->
        {:ok, nil}

      empty_index?(config) ->
        halt(Error.exception(reason: :config_invalid, resource: nil, op: :sink), config)

      true ->
        run_batch_transaction(config, transactions)
    end
  rescue
    e -> halt(e, config)
  catch
    :throw, value -> halt(value, config)
    :exit, value -> halt(value, config)
  end

  defp run_batch_transaction(config, transactions) do
    started = System.monotonic_time()
    %Replicant.Transaction{commit_lsn: last_lsn} = List.last(transactions)

    # Same ceiling as run_transaction: the per-change generation guards and
    # the locked admission read hold inside this transaction, and a batch
    # multiplies the work under one lock hold.
    result =
      config.repo.transaction(
        fn ->
          guard_generation!(config)

          case locked_checkpoint!(config) do
            cp when is_integer(cp) and last_lsn <= cp ->
              guard_generation!(config)
              :skipped

            cp ->
              {txn_count, change_count} = apply_batch(config, transactions, cp)
              guard_generation!(config)
              # Ascending order + last_lsn > cp here, so the write cannot
              # regress the locked watermark.
              upsert_checkpoint(config, last_lsn)
              guard_generation!(config)
              {:applied, txn_count, change_count}
          end
        end,
        timeout: @snapshot_transaction_timeout
      )

    case result do
      {:ok, {:applied, txn_count, change_count}} ->
        Telemetry.event(
          [:ash_replicant, :sink, :batch_applied],
          %{change_count: change_count, duration: System.monotonic_time() - started},
          %{commit_lsn: last_lsn, txn_count: txn_count}
        )

        {:ok, last_lsn}

      {:ok, :skipped} ->
        Telemetry.event([:ash_replicant, :sink, :skipped], %{}, %{
          commit_lsn: last_lsn,
          txn_count: length(transactions)
        })

        {:ok, last_lsn}

      {:error, reason} ->
        halt(reason, config)
    end
  end

  # One ascending pass over the batch. A transaction at/below the locked
  # watermark skips individually (the callback contract's belt-and-suspenders
  # on top of the framework's Commit-time pre-skip); each survivor applies
  # through the SAME single-pass `apply_all` core — the transactional-message
  # ordinal interleave carries through unchanged, and a spilled transaction's
  # lazy `changes` never re-enumerates. `transactions` itself is the
  # materialized in-memory list the framework hands over. The skip predicate
  # keys on `is_integer(checkpoint_lsn)` EXACTLY like run_transaction's —
  # Elixir's total term order sorts every integer BELOW the atom nil, so a
  # bare `lsn <= checkpoint_lsn` would "skip" every transaction on a
  # never-persisted (nil) checkpoint.
  defp apply_batch(config, transactions, checkpoint_lsn) do
    Enum.reduce(transactions, {0, 0}, fn
      %Replicant.Transaction{commit_lsn: lsn}, acc
      when is_integer(checkpoint_lsn) and is_integer(lsn) and lsn <= checkpoint_lsn ->
        acc

      %Replicant.Transaction{
        commit_lsn: lsn,
        commit_timestamp: ts,
        changes: txn_changes,
        messages: messages
      },
      {txn_count, change_count} ->
        guard_generation!(config)
        count = apply_all(config, txn_changes, ts, messages || [], lsn)
        guard_generation!(config)
        {txn_count + 1, change_count + count}
    end)
  end

  @doc """
  Accept or decline a schema change. An `:additive` change auto-applies; a
  `:destructive` change on a resource whose `on_schema_change` is
  `:halt_destructive` (default) halts fail-closed. The context map is not
  value-inspected. Unmapped tables use the behaviour default.
  """
  @spec handle_schema_change(map(), Replicant.SchemaChange.t(), map()) :: :ok | {:error, term()}
  def handle_schema_change(
        config,
        %Replicant.SchemaChange{kind: kind, change: change_class} = sc,
        _ctx
      ) do
    resource = Resolver.lookup(config.resolver_index, sc.schema, sc.table)

    policy =
      if resource,
        do: Info.replicant_on_schema_change!(resource),
        else: :halt_destructive

    # C1 carve-out (adversarial): these two destructive classes alter the
    # meaning of old_record / the cast contract — the exact bases the B4
    # prelude and B3 type rules stand on — so they are NEVER ignorable; other
    # destructive classes keep the declared on_schema_change policy.
    case {kind, change_class, policy} do
      {_kind, change_class, _policy}
      when change_class in [:replica_identity_changed, :type_changed] ->
        {:error,
         Error.exception(
           reason: :schema_change_destructive,
           resource: resource,
           op: :schema_change,
           shape: "#{sc.schema || "public"}.#{sc.table}(#{change_class})"
         )}

      {:additive, _change_class, _} ->
        :ok

      {:destructive, _change_class, :ignore} ->
        :ok

      {:destructive, _change_class, :halt_destructive} ->
        {:error,
         Error.exception(
           reason: :schema_change_destructive,
           resource: resource,
           op: :schema_change,
           shape: "#{sc.schema || "public"}.#{sc.table}"
         )}
    end
  rescue
    # D3 (design C2): this was the ONLY boundary body with no containment —
    # a fault escaped raw, and replicant's handle_message wrapper scrubbed it
    # one frame up but MISLABELED it :decode_failure (assembler.ex:241-249)
    # while the sink's own halt telemetry never fired. The sink now contains
    # its own faults: the structural reason classifies correctly and
    # [:ash_replicant, :sink, :halted] fires from here.
    e -> halt_schema_change_fault(e, config)
  catch
    :throw, value -> halt_schema_change_fault(value, config)
    :exit, value -> halt_schema_change_fault(value, config)
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

      assert_snapshot_coverage!(config, schema, table, changes)

      case Resolver.lookup(config.resolver_index, schema, table) do
        # Unmapped + explicitly ignored table = intentional partial coverage.
        nil ->
          :ok

        resource ->
          run_snapshot_batch(config, resource, changes, first?, table, ctx)
      end
    end
  rescue
    e -> {:error, Error.scrub(e, nil, :snapshot)}
  catch
    # D3: throw/exit scrubbed like raises (the snapshotter would otherwise
    # surface them as its generic :snapshot_failed with no structural reason).
    :throw, value -> {:error, Error.scrub_caught(value, nil, :snapshot)}
    :exit, value -> {:error, Error.scrub_caught(value, nil, :snapshot)}
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
    case snapshot_ordinal_base(config, snapshot_lsn, first?) do
      {:ok, ordinal_base} ->
        run_snapshot_transaction(config, resource, changes, first?, snapshot_lsn, ordinal_base)

      :error ->
        {:error, Error.exception(reason: :config_invalid, resource: resource, op: :snapshot)}
    end
  end

  defp run_snapshot_transaction(config, resource, changes, first?, snapshot_lsn, ordinal_base) do
    result =
      config.repo.transaction(
        fn ->
          apply_snapshot_transaction!(
            config,
            resource,
            changes,
            first?,
            snapshot_lsn,
            ordinal_base
          )
        end,
        timeout: @snapshot_transaction_timeout
      )

    case result do
      {:ok, _} ->
        put_snapshot_ordinal(config, snapshot_lsn, ordinal_base + length(changes))
        :ok

      # Scrub'd like the other arm: a host hook can Repo.rollback a forged
      # %Error{} from inside the snapshot transaction.
      {:error, %Error{} = e} ->
        {:error, Error.scrub(e, resource, :snapshot)}

      {:error, other} ->
        {:error, Error.scrub(other, resource, :snapshot)}
    end
  end

  defp apply_snapshot_transaction!(config, resource, changes, first?, snapshot_lsn, ordinal_base) do
    guard_generation!(config)
    config = preflight_snapshot_onetime!(config, resource, changes)
    maybe_clear_snapshot(resource, config, first?)
    apply_snapshot_batch(config, resource, changes, snapshot_lsn, ordinal_base)
    guard_generation!(config)
  end

  defp maybe_clear_snapshot(_resource, _config, false), do: :ok

  defp maybe_clear_snapshot(resource, config, true) do
    clear_mirror(resource, config)
    guard_generation!(config)
  end

  # ONE continuing ordinal space per snapshot RUN. A v1 snapshot shares ONE
  # consistent point (`commit_lsn`) across every table, and two mapped resources
  # can lawfully share a participant atom and claims prefix — a per-table
  # ordinal space would then mint IDENTICAL operation keys for table A row i and
  # table B row i, and AshOnetime would replay A's stored response for B
  # (silent suppression of B's declared effect; proven live by the two-table
  # snapshot marquee). Keyed by the run's consistent point: a re-created slot
  # exports a new point (counter resets), while later tables in the same run
  # continue it.
  defp snapshot_ordinal_base(config, snapshot_lsn, first?) do
    case snapshot_ordinals(config) do
      %{run_lsn: ^snapshot_lsn, ordinal: ordinal} when is_integer(ordinal) and ordinal >= 0 ->
        {:ok, ordinal}

      _other when first? and is_integer(snapshot_lsn) ->
        put_snapshot_ordinal(config, snapshot_lsn, 0)
        {:ok, 0}

      _other ->
        :error
    end
  end

  defp snapshot_ordinals(config) do
    case :persistent_term.get(snapshot_ordinals_key(config.slot_name), :none) do
      %{run_lsn: _, ordinal: _} = run -> run
      _other -> :none
    end
  end

  defp put_snapshot_ordinal(config, snapshot_lsn, ordinal) do
    :persistent_term.put(snapshot_ordinals_key(config.slot_name), %{
      run_lsn: snapshot_lsn,
      ordinal: ordinal
    })
  end

  defp snapshot_ordinals_key(slot_name),
    do: {__MODULE__, :snapshot_ordinals, slot_name}

  @doc false
  @spec clear_snapshot_ordinals(String.t()) :: true
  def clear_snapshot_ordinals(slot_name) when is_binary(slot_name) do
    :persistent_term.erase(snapshot_ordinals_key(slot_name))
  end

  def clear_snapshot_ordinals(_slot_name), do: true

  # The snapshot handoff's destination-transaction body: monotonic, guarded.
  defp complete_snapshot_transaction!(config, snapshot_lsn) do
    guard_generation!(config)

    case locked_checkpoint!(config) do
      # Monotonic handoff: a re-delivered/older consistent point never
      # regresses the durable watermark. No write; the framework acks its
      # own consistent point, never the sink's return value.
      cp when is_integer(cp) and snapshot_lsn <= cp ->
        :ok

      _ ->
        upsert_checkpoint(config, snapshot_lsn)
    end

    guard_generation!(config)
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
      config.repo.transaction(
        fn -> complete_snapshot_transaction!(config, snapshot_lsn) end,
        # Same ceiling as every other locked path: the first statement holds
        # FOR UPDATE on the checkpoint row, so a lock wait must not run into
        # the 15s DBConnection default (the deterministic-wedge class).
        timeout: @snapshot_transaction_timeout
      )
      |> case do
        {:ok, _} ->
          clear_snapshot_ordinals(config.slot_name)

          Telemetry.event([:ash_replicant, :snapshot, :complete], %{}, %{commit_lsn: snapshot_lsn})

          {:ok, snapshot_lsn}

        {:error, other} ->
          {:error, Error.scrub(other, config.checkpoint_resource, :snapshot_complete)}
      end
    end
  rescue
    e -> {:error, Error.scrub(e, config.checkpoint_resource, :snapshot_complete)}
  catch
    :throw, value ->
      {:error, Error.scrub_caught(value, config.checkpoint_resource, :snapshot_complete)}

    :exit, value ->
      {:error, Error.scrub_caught(value, config.checkpoint_resource, :snapshot_complete)}
  end

  # B3 snapshot-side accounting: unmapped tables halt unless ignored, and the
  # record keys must be mapped or skipped. The facts derive per-resource.
  defp assert_snapshot_coverage!(config, schema, table, changes) do
    ignored =
      case Map.get(config, :coverage) do
        %{ignored: ignored} -> ignored
        _other -> MapSet.new()
      end

    case Resolver.lookup(config.resolver_index, schema, table) do
      nil ->
        unless MapSet.member?(ignored, {schema, table}) do
          raise Error.exception(
                  reason: :source_table_unmapped,
                  resource: nil,
                  op: :snapshot,
                  shape: "#{schema}.#{table}"
                )
        end

      resource ->
        {skip, _cloak, _attrs} = Resolver.upsert_reflection(resource)

        facts = %{
          {schema, table} => %{
            resource: resource,
            mapped: AshReplicant.Coverage.source_mapped_set(resource),
            skips: skip |> Enum.map(&Atom.to_string/1) |> MapSet.new(),
            target_types: %{},
            tenant?: false,
            scd2?: false,
            business_key: []
          }
        }

        changes
        |> Enum.take(1)
        |> Enum.each(fn change ->
          AshReplicant.Coverage.assert_record_columns!(
            facts,
            MapSet.new(),
            schema,
            table,
            change.record || %{}
          )
        end)
    end
  end

  defp clear_mirror(resource, config) do
    # Redo-safety: wipe ALL mirror rows for this resource before re-applying the
    # snapshot dump. A tenant-scoped Ash.bulk_destroy! cannot clear a NON-GLOBAL
    # attribute-multitenant table (raises TenantRequired), so delete tenant-blind
    # on the mirror's own table, inside the snapshot transaction. Works uniformly
    # for non-tenant, global-tenant, and non-global-tenant resources. The table /
    # schema come from the resource DSL at the admitted destination boundary,
    # never from a row value.
    schema = PGInfo.schema(resource) || "public"
    table = PGInfo.table(resource)

    SQL.query!(
      config.repo,
      "DELETE FROM " <> Sql.quote_identifier(schema) <> "." <> Sql.quote_identifier(table),
      []
    )
  end

  defp apply_snapshot_batch(_config, _resource, [], _snapshot_lsn, _ordinal_base), do: :ok

  defp apply_snapshot_batch(config, resource, changes, snapshot_lsn, ordinal_base) do
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
      changes
      |> Enum.with_index(ordinal_base)
      |> Enum.each(fn {c, ordinal} ->
        guard_generation!(config)

        Apply.apply_change(config, %{
          c
          | op: :insert,
            commit_lsn: snapshot_lsn,
            ordinal: ordinal
        })

        guard_generation!(config)
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

      guard_generation!(config)

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
          context: snapshot_action_context(config, snapshot_lsn, ordinal_base),
          transaction: false
        )

      guard_generation!(config)

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

  defp preflight_snapshot_onetime!(config, resource, changes) do
    action = Resolver.upsert_action(resource)

    tenants =
      if tenant_scoped?(resource) do
        changes
        |> Enum.map(&Resolver.resolve_tenant!(resource, &1.record, :upsert))
        |> Enum.uniq()
      else
        [nil]
      end

    preflighted =
      Enum.reduce(tenants, MapSet.new(), fn tenant, preflighted ->
        case Destination.preflight_onetime_transaction(
               config.destination_manifest,
               config.dynamic_repo,
               tenant,
               resource,
               action
             ) do
          :ok ->
            MapSet.put(preflighted, {resource, action, tenant})

          {:error, reason} ->
            raise Error.exception(reason: reason, resource: resource, op: :snapshot)
        end
      end)

    Map.put(config, :onetime_preflighted, preflighted)
  end

  defp run_transaction(config, lsn, ts, changes, messages) do
    started = System.monotonic_time()

    # Explicit timeout: the per-change generation guards re-validate the
    # manifest and re-hash core bytecode inside this transaction, so at scale
    # the default 15s DBConnection ceiling can be exceeded by guard overhead
    # alone — a deterministic wedge (replicant retries the same transaction
    # forever and source WAL retention grows unbounded). Same ceiling as the
    # snapshot transaction.
    result =
      config.repo.transaction(
        fn ->
          guard_generation!(config)

          case locked_checkpoint!(config) do
            cp when is_integer(cp) and lsn <= cp ->
              guard_generation!(config)
              :skipped

            _ ->
              count = apply_all(config, changes, ts, messages, lsn)
              guard_generation!(config)
              upsert_checkpoint(config, lsn)
              guard_generation!(config)
              {:applied, count}
          end
        end,
        timeout: @snapshot_transaction_timeout
      )

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
  # Transactional MESSAGES interleave by ordinal: `txn.messages` is an in-memory
  # list sharing the changes' ONE ascending numbering space (spec §7.1), so the
  # messages with ordinal < the next change's ordinal flush ahead of it and the
  # tail flushes after — source order preserved without materializing the stream.
  defp apply_all(config, changes, ts, messages, commit_lsn) do
    {count, remaining} =
      Enum.reduce(changes, {0, messages}, fn change, {n, msgs} ->
        {n, msgs} = flush_messages_before(config, msgs, change.ordinal, n, commit_lsn)

        guard_generation!(config)
        Apply.apply_change(config, change, ts)
        guard_generation!(config)

        {n + 1, msgs}
      end)

    {count, _} = flush_messages_before(config, remaining, :infinity, count, commit_lsn)
    count
  end

  defp flush_messages_before(config, messages, bound, n, commit_lsn) do
    {ready, rest} =
      Enum.split_while(messages, fn
        %Replicant.Decoder.Messages.Message{ordinal: ordinal} ->
          is_integer(ordinal) and (bound == :infinity or ordinal < bound)

        _other ->
          false
      end)

    Enum.each(ready, fn message ->
      guard_generation!(config)
      apply_transactional_message(config, message, commit_lsn)
      guard_generation!(config)
    end)

    {n + length(ready), rest}
  end

  # A transactional message routes by prefix inside the transaction: ignored
  # prefixes are inert, an unmapped prefix RAISES (the raise rolls the whole
  # transaction back — the fail-closed posture identical to a failing change).
  defp apply_transactional_message(
         config,
         %Replicant.Decoder.Messages.Message{} = message,
         commit_lsn
       ) do
    case Messages.resolve_route(config, message.prefix) do
      :ignored ->
        :ok

      {:ok, route} ->
        Messages.apply(config, message, route, commit_lsn)

      {:error, :unmapped} ->
        raise Error.exception(
                reason: :message_prefix_unmapped,
                resource: nil,
                op: :message,
                shape: message.prefix
              )
    end
  end

  @doc """
  Deliver a NON-TRANSACTIONAL logical-decoding message standalone (the
  seventh sink boundary body, C1/ADR-0015). Routing is fail-closed: an
  explicitly ignored prefix acknowledges (watermark advanced, no effect); an
  unknown prefix halts (`:message_prefix_unmapped`); a database-local route
  applies effect+claim+watermark in ONE destination transaction; an external
  peer route applies through AshOnetime's three-state recovery and advances
  the watermark only after a finalized/replayed success. Value-free on every
  fault shape (rescue AND catch) with the sink's own `:halted` event.
  """
  @spec handle_message(map(), Replicant.Decoder.Messages.Message.t(), map()) ::
          :ok | {:error, term()}
  def handle_message(
        config,
        %Replicant.Decoder.Messages.Message{prefix: prefix, lsn: lsn} = message,
        _ctx
      ) do
    case Messages.resolve_route(config, prefix) do
      :ignored ->
        advance_message_watermark(config, lsn)
        :ok

      {:ok, route} ->
        deliver_message(config, message, route, lsn)

      {:error, :unmapped} ->
        halt_message(
          Error.exception(
            reason: :message_prefix_unmapped,
            resource: nil,
            op: :message,
            shape: prefix
          ),
          config
        )
    end
  rescue
    e -> halt_message(e, config)
  catch
    :throw, value -> halt_message(value, config)
    :exit, value -> halt_message(value, config)
  end

  defp deliver_message(config, message, route, lsn) do
    if external_route?(route) do
      # The claim commits and finalizes through AshOnetime's independent
      # store path — no wrapping destination transaction; the watermark moves
      # only after finalized/replayed success (ADR-0015).
      Messages.apply(config, message, route, nil)
      advance_message_watermark(config, lsn)
      :ok
    else
      result =
        config.repo.transaction(
          fn ->
            guard_generation!(config)
            Messages.apply(config, message, route, nil)
            advance_watermark!(config, lsn)
            guard_generation!(config)
          end,
          timeout: @snapshot_transaction_timeout
        )

      case result do
        {:ok, :ok} ->
          :ok

        {:error, reason} ->
          raise reason
      end
    end
  end

  defp external_route?(route) do
    case AshOnetime.Resource.Info.protection(route.resource, route.action) do
      %{external_effect: external_effect} -> not is_nil(external_effect)
      _other -> false
    end
  end

  # Monotonic watermark advance shared by the message paths: the locked read
  # + skip-if-at-or-below guard (a standalone message's LSN can never regress
  # the durable frontier; re-delivery re-advances an already-advanced value).
  defp advance_watermark!(config, lsn) when is_integer(lsn) do
    case locked_checkpoint!(config) do
      cp when is_integer(cp) and lsn <= cp -> :ok
      _other -> upsert_checkpoint(config, lsn)
    end

    :ok
  end

  defp advance_message_watermark(config, lsn) when is_integer(lsn) do
    result =
      config.repo.transaction(
        fn ->
          guard_generation!(config)
          advance_watermark!(config, lsn)
          guard_generation!(config)
        end,
        timeout: @snapshot_transaction_timeout
      )

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> raise reason
    end
  end

  # The message-path halt funnel: same scrub as halt/2 (the structural reason
  # only — never the content) plus the sink's own halted event.
  defp halt_message(reason, config) do
    error = Error.scrub(reason, config.checkpoint_resource, :message)

    Telemetry.event([:ash_replicant, :sink, :halted], %{}, %{
      reason: error.reason,
      error_class: error.class
    })

    {:error, error}
  end

  defp guard_generation!(config) do
    case AshReplicant.guard_generation(config) do
      :ok -> :ok
      {:error, %Error{} = error} -> config.repo.rollback(error)
    end
  end

  # The schema-change fault containment: same scrub as `halt/2` plus the
  # sink's OWN halted event — on this path (and only here) the framework's
  # wrapper would otherwise misclassify a sink fault as stream corruption.
  defp halt_schema_change_fault(reason, config) do
    error = Error.scrub(reason, config.checkpoint_resource, :schema_change)

    Telemetry.event([:ash_replicant, :sink, :halted], %{}, %{
      reason: error.reason,
      error_class: error.class
    })

    {:error, error}
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

  # Mechanical triple rekey (source-bound checkpoint, B2). The identity comes from the
  # config's source_identity — legal only AFTER handle_session_identity proved
  # configured == actual session before any read (the TOCTOU gate).
  #
  # Split reads (roadmap B2): `read_checkpoint/1` is the UNLOCKED advisory read
  # behind `checkpoint/0` (the framework uses it only to seed recovery); the
  # authoritative dedup is `locked_checkpoint!/1` INSIDE the admission
  # transaction — issuing FOR UPDATE outside a transaction would be a momentary
  # pointless lock.
  defp read_checkpoint(config) do
    case Ash.get!(config.checkpoint_resource, checkpoint_filter(config),
           authorize?: false,
           context: action_context(config),
           error?: false
         ) do
      nil -> nil
      %{commit_lsn: lsn} -> lsn
    end
  end

  # The locked admission read. An ABSENT row is a permanent halt (never a
  # silent frontier-0 reapply): the row is created at bind and destroyed only by
  # the operator reset, so absence means binding never ran or a reset raced the
  # pipeline. Replicant coerces the sink error to {:halt, :sink_failed} and the
  # :temporary supervisor never restarts — an operator/host restart re-runs the
  # identity gate and re-binds (the [:ash_replicant, :checkpoint, :conflict]
  # event is the signal meanwhile).
  defp locked_checkpoint!(config) do
    case Ash.get!(config.checkpoint_resource, checkpoint_filter(config),
           lock: :for_update,
           authorize?: false,
           context: action_context(config),
           error?: false
         ) do
      nil -> rollback_conflict!(config, :checkpoint_unbound)
      %{commit_lsn: lsn} -> lsn
    end
  end

  defp upsert_checkpoint(config, lsn) do
    Ash.create!(
      config.checkpoint_resource,
      Map.merge(checkpoint_filter(config), %{commit_lsn: lsn}),
      action: :upsert,
      upsert?: true,
      upsert_identity: :source_slot,
      upsert_fields: [:commit_lsn],
      authorize?: false,
      context: action_context(config),
      return_notifications?: true
    )
  end

  defp checkpoint_filter(config) do
    %{
      source_system_id: config.source_identity.system_identifier,
      source_database: config.source_identity.database,
      slot_name: config.slot_name
    }
  end

  defp action_context(config),
    do: %{data_layer: Map.get(config, :data_layer_context, %{repo: config.repo})}

  defp snapshot_action_context(config, snapshot_lsn, ordinal_base) do
    config
    |> action_context()
    |> Map.put(:ash_replicant_operation, %{
      source_system_identifier: config.source_identity.system_identifier,
      source_database: config.source_identity.database,
      slot_name: config.slot_name,
      commit_lsn: snapshot_lsn,
      ordinal_base: ordinal_base,
      invocation: :upsert
    })
  end
end
