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

  alias AshReplicant.{
    Append,
    Apply,
    Destination,
    Error,
    Messages,
    Resolver,
    Snapshot,
    Sql,
    Telemetry
  }

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Resource.Info
  alias AshReplicant.Snapshot.{Provenance, Retirement, State}
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

  @doc """
  Admit the replication slot's consistent-point origin for a GO-FORWARD append
  sink (ADR-0018 §5). Generated only on such sinks, and invoked on every
  connect and reconnect BEFORE `START_REPLICATION` — after
  `handle_session_identity/3` has bound the checkpoint row, so the row is
  always present here.

  The first admitted activation persists the callback origin as the log's
  IMMUTABLE floor: a new slot supplies its `CREATE_REPLICATION_SLOT`
  consistent point, a reused slot its effective `START_REPLICATION` origin.
  No completeness claim covers data below that floor.

  Every LATER origin is a moving resume fact, never a replacement floor, and it
  has to tie out against what the log durably holds:

    * a slot CREATED this session (`reused?: false`) arriving at a log that
      already claims a floor means the previous slot is gone, so PostgreSQL no
      longer retains the WAL between the durable frontier and this new
      consistent point — it halts `:append_origin_gap` before readiness;
    * an APPENDED event above the durable checkpoint means a torn write, since
      the append and the checkpoint commit in one transaction — it halts
      `:append_frontier_divergent` rather than resuming over it.

  Both halts are value-free; the origin and the identity never render.
  """
  @spec handle_slot_origin(map(), Replicant.lsn(), map()) :: :ok | {:error, term()}
  def handle_slot_origin(config, origin, %{reused?: reused?} = _context)
      when is_integer(origin) and origin >= 0 and is_boolean(reused?) do
    result =
      config.repo.transaction(
        fn ->
          guard_generation!(config)
          admit_slot_origin!(config, origin, reused?)
          guard_generation!(config)
        end,
        timeout: @snapshot_transaction_timeout
      )

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Error.scrub(reason, nil, :slot_origin)}
    end
  rescue
    e -> {:error, Error.scrub(e, nil, :slot_origin)}
  catch
    :throw, value -> {:error, Error.scrub_caught(value, nil, :slot_origin)}
    :exit, value -> {:error, Error.scrub_caught(value, nil, :slot_origin)}
  end

  def handle_slot_origin(_config, _origin, _context),
    do: {:error, Error.exception(reason: :config_invalid, resource: nil, op: :slot_origin)}

  defp admit_slot_origin!(config, origin, reused?) do
    row = locked_checkpoint_row!(config)

    case row.origin_floor do
      nil ->
        # The first admitted activation. Written under the SAME row lock that
        # guards the watermark, so a racing second activation cannot mint a
        # second floor.
        upsert_checkpoint_fields(config, %{origin_floor: origin})

      floor when is_integer(floor) ->
        verify_resume_origin!(config, row, floor, origin, reused?)

      _invalid ->
        rollback_conflict!(config, :append_origin_invalid)
    end
  end

  # The floor is already set, so this origin is a RESUME FACT.
  #
  # Replicant does not idle-advance an :append_log sink over filtered WAL. The
  # reconnect origin can therefore be compared to the destination watermark
  # directly: an origin ahead of it was not acknowledged by this sink and is a
  # real gap. A slot created this session under an existing floor remains the
  # separate slot-replacement proof and also halts.
  defp verify_resume_origin!(config, row, floor, origin, reused?) do
    frontier = if is_integer(row.commit_lsn), do: row.commit_lsn, else: floor

    cond do
      appended_frontier(config) > frontier ->
        rollback_conflict!(config, :append_frontier_divergent)

      not reused? ->
        rollback_conflict!(config, :append_origin_gap)

      # Replicant never performs a filtered-WAL idle acknowledgement for an
      # append sink. A reused origin ahead of the durable frontier is therefore
      # unambiguous: PostgreSQL was advanced by another consumer or operator.
      origin > frontier ->
        rollback_conflict!(config, :append_origin_gap)

      true ->
        :ok
    end
  end

  # The highest commit LSN this source triple has actually appended, across
  # every mapped append target. Nothing appended yet reads as -1, so an empty
  # log can never exceed a frontier.
  defp appended_frontier(config) do
    message_resources =
      config
      |> Map.get(:message_routes, [])
      |> Enum.map(fn {_prefix, resource, _action} -> resource end)

    (Map.values(config.resolver_index) ++ message_resources)
    |> Enum.uniq()
    |> Enum.filter(&Info.append_log?/1)
    |> Enum.reduce(-1, fn resource, acc ->
      max(acc, max_appended_lsn(config, resource))
    end)
  end

  # Tenant-BLIND by construction, and therefore raw: an append target may be
  # tenant-scoped, and the frontier spans every tenant's events, so no single
  # `tenant:` could scope this read (the same reason `Apply`'s `:mirror`
  # truncate issues a raw DELETE). It sits at the identical trust boundary —
  # schema, table and column names come from the resource DSL, never a row
  # value, and every identifier routes through the ONE quoting home; the three
  # identity values are parameterized. Activation refuses a `strategy :context`
  # append target on a go-forward sink precisely because its table is not
  # statically addressable here.
  defp max_appended_lsn(config, resource) do
    names = Info.append_attributes(resource)
    schema = PGInfo.schema(resource) || "public"
    table = PGInfo.table(resource)

    sql =
      "SELECT max(" <>
        Sql.quote_identifier(column(resource, names.commit_lsn)) <>
        ") FROM " <>
        Sql.quote_identifier(schema) <>
        "." <>
        Sql.quote_identifier(table) <>
        " WHERE " <>
        Sql.quote_identifier(column(resource, names.source_system)) <>
        " = $1 AND " <>
        Sql.quote_identifier(column(resource, names.source_database)) <>
        " = $2 AND " <>
        Sql.quote_identifier(column(resource, names.slot_name)) <> " = $3"

    params = [
      config.source_identity.system_identifier,
      config.source_identity.database,
      config.slot_name
    ]

    case SQL.query!(config.repo, sql, params) do
      %{rows: [[nil]]} -> -1
      %{rows: [[lsn]]} when is_integer(lsn) -> lsn
      _other -> rollback_conflict!(config, :append_frontier_divergent)
    end
  end

  # The STORAGE column behind an attribute name: a host may rename the column
  # under the attribute with `source:`, and reading the attribute name would
  # then quote an identifier that does not exist.
  defp column(resource, attribute) do
    case Ash.Resource.Info.attribute(resource, attribute) do
      %{source: source} when is_binary(source) -> source
      %{source: source} when is_atom(source) and not is_nil(source) -> Atom.to_string(source)
      _other -> Atom.to_string(attribute)
    end
  end

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

  @doc "Read or prepare the durable incremental-snapshot progress authority."
  @spec snapshot_progress(map()) ::
          {:ok, binary() | nil | :backfill_pending} | {:error, term()}
  def snapshot_progress(config) do
    if empty_index?(config) do
      {:error, Error.exception(reason: :config_invalid, resource: nil, op: :snapshot_progress)}
    else
      config.repo.transaction(
        fn -> prepare_incremental_progress!(config) end,
        timeout: @snapshot_transaction_timeout
      )
      |> case do
        {:ok, progress} ->
          {:ok, progress}

        {:error, reason} ->
          {:error, Error.scrub(reason, config.checkpoint_resource, :snapshot_progress)}
      end
    end
  rescue
    e -> {:error, Error.scrub(e, config.checkpoint_resource, :snapshot_progress)}
  catch
    :throw, value ->
      {:error, Error.scrub_caught(value, config.checkpoint_resource, :snapshot_progress)}

    :exit, value ->
      {:error, Error.scrub_caught(value, config.checkpoint_resource, :snapshot_progress)}
  end

  defp prepare_incremental_progress!(config) do
    guard_generation!(config)
    keys = provenance_keys!(config)
    row = locked_checkpoint_row!(config)

    progress =
      resume_incremental_progress!(config, row, keys, decode_snapshot_state(row, keys))

    guard_generation!(config)
    progress
  end

  defp resume_incremental_progress!(
         _config,
         %{snapshot_progress: nil, commit_lsn: checkpoint},
         _keys,
         :absent
       )
       when is_integer(checkpoint),
       do: nil

  defp resume_incremental_progress!(config, %{snapshot_progress: nil}, keys, :absent) do
    digest = contract_digest!(config)
    state = State.mint_incremental(digest, State.active_key_version(keys))
    store_snapshot_state!(config, state, keys)
    :backfill_pending
  end

  defp resume_incremental_progress!(
         config,
         %{snapshot_progress: nil} = row,
         _keys,
         {:ok, %State{mode: :incremental, status: status} = state}
       )
       when status in [:armed, :active] do
    require_incremental_contract!(config, state)
    require_progress_pair!(config, row, state)
    :backfill_pending
  end

  defp resume_incremental_progress!(
         config,
         %{snapshot_progress: token} = row,
         _keys,
         {:ok, %State{mode: :incremental, status: status} = state}
       )
       when is_binary(token) and status in [:armed, :active] do
    require_incremental_contract!(config, state)
    require_progress_pair!(config, row, state)
    token
  end

  defp resume_incremental_progress!(
         config,
         %{snapshot_progress: token} = row,
         _keys,
         {:ok, %State{mode: :incremental, status: :complete} = state}
       )
       when is_binary(token) do
    if completed_progress_pair_valid?(row, state),
      do: token,
      else: rollback_conflict!(config, :snapshot_state_invalid)
  end

  defp resume_incremental_progress!(
         _config,
         %{snapshot_progress: nil, commit_lsn: checkpoint},
         _keys,
         {:ok, %State{mode: :v1}}
       )
       when is_integer(checkpoint),
       do: nil

  defp resume_incremental_progress!(config, _row, _keys, _state),
    do: rollback_conflict!(config, :snapshot_state_invalid)

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

          row = locked_checkpoint_row!(config)

          case row.commit_lsn do
            cp when is_integer(cp) and last_lsn <= cp ->
              guard_generation!(config)
              :skipped

            cp ->
              incremental = stream_incremental_attempt!(config, row)
              {txn_count, change_count} = apply_batch(config, transactions, cp, incremental)
              guard_generation!(config)
              # Ascending order + last_lsn > cp here, so the write cannot
              # regress the locked watermark.
              upsert_stream_checkpoint!(config, last_lsn, incremental)
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
  defp apply_batch(config, transactions, checkpoint_lsn, incremental) do
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
        count = apply_all(config, txn_changes, ts, messages || [], lsn, incremental)
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
  Persist a snapshot batch for `ctx.table`. Does not advance the checkpoint.

  **No callback clears a resource** (S02 / ADR-0017). The pre-S02 code wiped
  the whole mirror on `first_for_table?` for redo-safety; that repeated every
  committed host business effect on any retry and could erase a stream-applied
  row. Stale rows are now retired at fenced completion instead, per tenant
  scope, through the host's own retire action — and only for a resource that
  opted into `snapshot_provenance`. `first_for_table?` authorizes no deletion
  and carries no attempt identity.

  A `snapshot_provenance true` resource routes to
  `AshReplicant.Snapshot.Rows`: the batch's rows are compared against their
  stored fingerprints under the run's bound attempt, and an unchanged row is
  marked rather than re-run. Everything else keeps the pre-S02 apply. Plain
  SCD1 non-tenant, non-sensitive resources use a bulk upsert; the load-bearing
  fail-closed guard is the `case result.status` check — anything other than
  `:success` (including the default-options `:partial_success`) rolls the
  snapshot transaction back, so a failing row is never silently dropped.
  `stop_on_error?: true` is a defensible early-stop on top of that, not the loss
  guard. Sensitive, tenant-scoped, OR SCD2 resources apply per-record — SCD2
  stamps the batch's snapshot LSN onto each change so each version opens at
  `valid_from_lsn = snapshot_lsn`.

  Incremental chunks persist their exact opaque progress with the row effects
  and durable ordinal cursor. The dedicated empty completion callback retires
  unseen rows and stores its token-hash replay fence without regressing the
  stream watermark.
  """
  @spec handle_snapshot(map(), [Replicant.Change.t()], map()) :: :ok | {:error, term()}
  def handle_snapshot(
        config,
        [],
        %{backfill_complete?: true, progress: progress, snapshot_lsn: snapshot_lsn}
      )
      when is_binary(progress) and is_integer(snapshot_lsn) do
    run_incremental_completion(config, progress, snapshot_lsn)
  rescue
    e -> {:error, Error.scrub(e, config.checkpoint_resource, :snapshot_complete)}
  catch
    :throw, value ->
      {:error, Error.scrub_caught(value, config.checkpoint_resource, :snapshot_complete)}

    :exit, value ->
      {:error, Error.scrub_caught(value, config.checkpoint_resource, :snapshot_complete)}
  end

  def handle_snapshot(config, _changes, %{backfill_complete?: true}) do
    {:error,
     Error.exception(
       reason: :snapshot_state_invalid,
       resource: config.checkpoint_resource,
       op: :snapshot_complete
     )}
  end

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

    with :ok <- run_snapshot(config, resource, changes, first?, snapshot_lsn, ctx) do
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

  defp run_snapshot(config, resource, changes, first?, snapshot_lsn, ctx) do
    if Map.has_key?(ctx, :progress) do
      case Map.get(ctx, :progress) do
        progress when is_binary(progress) ->
          run_incremental_snapshot_transaction(
            config,
            resource,
            changes,
            snapshot_lsn,
            progress
          )

        _invalid ->
          {:error,
           Error.exception(reason: :snapshot_state_invalid, resource: resource, op: :snapshot)}
      end
    else
      run_v1_snapshot(config, resource, changes, first?, snapshot_lsn)
    end
  end

  defp run_v1_snapshot(config, resource, changes, first?, snapshot_lsn) do
    case snapshot_ordinal_base(config, snapshot_lsn, first?) do
      {:ok, ordinal_base} ->
        run_snapshot_transaction(config, resource, changes, snapshot_lsn, ordinal_base)

      :error ->
        {:error, Error.exception(reason: :config_invalid, resource: resource, op: :snapshot)}
    end
  end

  defp run_incremental_snapshot_transaction(
         config,
         resource,
         changes,
         snapshot_lsn,
         progress
       ) do
    result =
      config.repo.transaction(
        fn ->
          apply_incremental_snapshot_transaction!(
            config,
            resource,
            changes,
            snapshot_lsn,
            progress
          )
        end,
        timeout: @snapshot_transaction_timeout
      )

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Error.scrub(reason, resource, :snapshot)}
    end
  end

  defp apply_incremental_snapshot_transaction!(
         config,
         resource,
         changes,
         snapshot_lsn,
         progress
       ) do
    guard_generation!(config)
    config = preflight_snapshot_onetime!(config, resource, changes)

    unless Retirement.provenance_sink?(config) and Info.replicant_snapshot_provenance!(resource) do
      rollback_conflict!(config, :snapshot_state_invalid)
    end

    keys = provenance_keys!(config)
    digest = contract_digest!(config)
    row = locked_checkpoint_row!(config)

    {%State{next_ordinal: ordinal} = state, attempt} =
      active_incremental_attempt!(config, row, keys, digest)

    Snapshot.Rows.apply_batch!(
      config,
      resource,
      changes,
      snapshot_lsn,
      ordinal,
      attempt
    )

    next = %State{
      state
      | status: :active,
        next_ordinal: ordinal + length(changes),
        progress_token_hash: token_hash(progress)
    }

    store_snapshot_progress_state!(config, progress, next, keys)
    guard_generation!(config)
  end

  defp run_incremental_completion(config, progress, snapshot_lsn) do
    if empty_index?(config) do
      {:error,
       Error.exception(
         reason: :config_invalid,
         resource: config.checkpoint_resource,
         op: :snapshot_complete
       )}
    else
      config.repo.transaction(
        fn -> complete_incremental_transaction!(config, progress, snapshot_lsn) end,
        timeout: @snapshot_transaction_timeout
      )
      |> case do
        {:ok, _} ->
          Telemetry.event(
            [:ash_replicant, :snapshot, :complete],
            %{},
            %{commit_lsn: snapshot_lsn}
          )

          :ok

        {:error, reason} ->
          {:error, Error.scrub(reason, config.checkpoint_resource, :snapshot_complete)}
      end
    end
  end

  defp complete_incremental_transaction!(config, progress, snapshot_lsn) do
    guard_generation!(config)
    keys = provenance_keys!(config)
    row = locked_checkpoint_row!(config)
    hash = token_hash(progress)

    case decode_snapshot_state(row, keys) do
      {:ok, %State{mode: :incremental, status: :complete} = state} ->
        if row.snapshot_progress == progress and completed_progress_pair_valid?(row, state),
          do: :fenced,
          else: rollback_conflict!(config, :snapshot_state_invalid)

      {:ok, %State{mode: :incremental, status: status} = state}
      when status in [:armed, :active] ->
        require_incremental_contract!(config, state)

        if progress_pair_valid?(row, state) do
          Retirement.retire_unseen!(config, state.attempt, snapshot_lsn)

          complete = %State{
            state
            | status: :complete,
              progress_token_hash: hash,
              completed_token_hash: hash
          }

          store_snapshot_progress_state!(config, progress, complete, keys)
        else
          rollback_conflict!(config, :snapshot_state_invalid)
        end

      _invalid ->
        rollback_conflict!(config, :snapshot_state_invalid)
    end

    guard_generation!(config)
  end

  defp run_snapshot_transaction(config, resource, changes, snapshot_lsn, ordinal_base) do
    result =
      config.repo.transaction(
        fn ->
          apply_snapshot_transaction!(
            config,
            resource,
            changes,
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

  defp apply_snapshot_transaction!(config, resource, changes, snapshot_lsn, ordinal_base) do
    guard_generation!(config)
    config = preflight_snapshot_onetime!(config, resource, changes)

    # The attempt binds under the checkpoint row lock BEFORE any row effect, so
    # chunks, completion and retirement serialize against each other across
    # nodes. It binds even for an EMPTY batch: Replicant dispatches one empty
    # `first_for_table?` chunk for a table with no rows, and that is the only
    # signal an empty source's snapshot phase ever started.
    cond do
      # ADR-0018 §4: a backfill row appended to a LOG carries its structural
      # mode plus the checkpoint-owned attempt id, and reuses none of the
      # state-mirror row-provenance machinery (there is nothing to retire). The
      # attempt still binds under the checkpoint row lock, from the same
      # authenticated envelope, before any row effect.
      append_sink?(config) ->
        attempt = bind_attempt!(config)

        config
        |> Map.put(:append_snapshot_attempt, attempt.attempt)
        |> apply_snapshot_batch(resource, changes, snapshot_lsn, ordinal_base)

      Retirement.provenance_sink?(config) ->
        attempt = bind_attempt!(config)

        if Info.replicant_snapshot_provenance!(resource) do
          Snapshot.Rows.apply_batch!(
            config,
            resource,
            changes,
            snapshot_lsn,
            ordinal_base,
            attempt
          )
        else
          apply_snapshot_batch(config, resource, changes, snapshot_lsn, ordinal_base)
        end

      true ->
        apply_snapshot_batch(config, resource, changes, snapshot_lsn, ordinal_base)
    end

    guard_generation!(config)
  end

  defp append_sink?(config),
    do: Map.get(config, :sink_kind, :state_mirror) == :append_log

  # ADR-0017: the first ACTUAL `handle_snapshot/2` callback of a run binds that
  # owner's private delivery-run id to a fresh durable attempt; later callbacks
  # in the same run reuse it. `first_for_table?` has no attempt-identity role —
  # it is per-table, and it is false for the first callback observed after an
  # incremental resume.
  defp bind_attempt!(config) do
    keys = provenance_keys!(config)
    digest = contract_digest!(config)
    row = locked_checkpoint_row!(config)

    case decode_snapshot_state(row, keys) do
      :absent ->
        mint_attempt!(config, keys, digest)

      {:ok, %State{mode: :v1, status: status, delivery_run: run, contract_digest: bound} = state}
      when status in [:armed, :active] ->
        cond do
          run != config.delivery_run ->
            # A LATER owner re-exporting after a crash. The consistent point can
            # be identical, so only the per-activation run distinguishes them:
            # rotate rather than resume, or the previous attempt's markers would
            # make this attempt's rows look already-seen.
            mint_attempt!(config, keys, digest)

          bound != digest ->
            # Same run, different admitted contract: the manifest, config, or
            # bytecode moved under an in-flight attempt. Never guess it is safe.
            rollback_conflict!(config, :snapshot_state_invalid)

          true ->
            attempt(state, keys)
        end

      {:ok, %State{mode: :v1, status: :complete, delivery_run: run}}
      when run != config.delivery_run ->
        mint_attempt!(config, keys, digest)

      _invalid ->
        rollback_conflict!(config, :snapshot_state_invalid)
    end
  end

  defp mint_attempt!(config, keys, digest) do
    state = State.mint_v1(config.delivery_run, digest, State.active_key_version(keys))
    store_snapshot_state!(config, state, keys)
    attempt(state, keys)
  end

  defp active_incremental_attempt!(config, row, keys, digest) do
    case decode_snapshot_state(row, keys) do
      {:ok, %State{mode: :incremental, status: status, contract_digest: ^digest} = state}
      when status in [:armed, :active] ->
        if progress_pair_valid?(row, state),
          do: {state, attempt(state, keys)},
          else: rollback_conflict!(config, :snapshot_state_invalid)

      _invalid ->
        rollback_conflict!(config, :snapshot_state_invalid)
    end
  end

  # The per-batch attempt handle: the membership marker plus the key material
  # the row fingerprints are computed and compared under.
  defp attempt(%State{} = state, keys) do
    %{attempt: state.attempt, keys: keys, key_version: State.active_key_version(keys)}
  end

  defp decode_snapshot_state(%{snapshot_state: nil}, _keys), do: :absent

  defp decode_snapshot_state(%{snapshot_state: encoded}, keys) when is_binary(encoded),
    do: State.decode(encoded, keys)

  defp decode_snapshot_state(_row, _keys), do: {:error, :undecodable}

  defp provenance_keys!(config) do
    case Provenance.keys() do
      {:ok, keys} -> keys
      :error -> rollback_conflict!(config, :config_invalid)
    end
  end

  defp contract_digest!(config) do
    case State.contract_digest(config) do
      {:ok, digest} -> digest
      :error -> rollback_conflict!(config, :config_invalid)
    end
  end

  defp store_snapshot_state!(config, %State{} = state, keys) do
    upsert_checkpoint_fields(config, %{
      snapshot_state: encode_snapshot_state!(config, state, keys)
    })
  end

  defp store_snapshot_progress_state!(config, progress, %State{} = state, keys)
       when is_binary(progress) do
    upsert_checkpoint_fields(config, %{
      snapshot_progress: progress,
      snapshot_state: encode_snapshot_state!(config, state, keys)
    })
  end

  defp encode_snapshot_state!(config, %State{} = state, keys) do
    # Any durable rewrite rotates the envelope to the active retained key. The
    # old key is still required to READ the prior state; after a completed sweep
    # every surviving row and the fence name the active key, so the old key can
    # be removed without making resume undecodable.
    state = %State{state | key_version: State.active_key_version(keys)}

    case State.encode(state, keys) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> rollback_conflict!(config, :snapshot_state_invalid)
    end
  end

  defp token_hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  defp progress_pair_valid?(%{snapshot_progress: nil}, %State{progress_token_hash: nil}),
    do: true

  defp progress_pair_valid?(
         %{snapshot_progress: token},
         %State{progress_token_hash: expected}
       )
       when is_binary(token) and is_binary(expected) do
    actual = token_hash(token)
    byte_size(actual) == byte_size(expected) and :crypto.hash_equals(actual, expected)
  end

  defp progress_pair_valid?(_row, _state), do: false

  defp require_progress_pair!(config, row, state) do
    if progress_pair_valid?(row, state),
      do: :ok,
      else: rollback_conflict!(config, :snapshot_state_invalid)
  end

  defp completed_progress_pair_valid?(
         %{snapshot_progress: token},
         %State{progress_token_hash: progress_hash, completed_token_hash: completed_hash}
       )
       when is_binary(token) and is_binary(progress_hash) and is_binary(completed_hash) do
    actual = token_hash(token)

    byte_size(actual) == byte_size(progress_hash) and
      :crypto.hash_equals(actual, progress_hash) and
      byte_size(progress_hash) == byte_size(completed_hash) and
      :crypto.hash_equals(progress_hash, completed_hash)
  end

  defp completed_progress_pair_valid?(_row, _state), do: false

  defp require_incremental_contract!(config, %State{contract_digest: bound}) do
    if contract_digest!(config) == bound,
      do: :ok,
      else: rollback_conflict!(config, :snapshot_state_invalid)
  end

  defp stream_incremental_attempt!(_config, %{snapshot_state: nil}), do: :none

  defp stream_incremental_attempt!(config, row) do
    keys = provenance_keys!(config)

    case decode_snapshot_state(row, keys) do
      {:ok, %State{mode: :incremental, status: status} = state}
      when status in [:armed, :active] ->
        require_incremental_contract!(config, state)

        if progress_pair_valid?(row, state),
          do: {state, attempt(state, keys), keys},
          else: rollback_conflict!(config, :snapshot_state_invalid)

      {:ok, %State{mode: :incremental, status: :complete} = state} ->
        if completed_progress_pair_valid?(row, state),
          do: :none,
          else: rollback_conflict!(config, :snapshot_state_invalid)

      {:ok, %State{mode: :v1, status: :complete}} ->
        :none

      _invalid ->
        rollback_conflict!(config, :snapshot_state_invalid)
    end
  end

  defp upsert_stream_checkpoint!(config, lsn, :none), do: upsert_checkpoint(config, lsn)

  defp upsert_stream_checkpoint!(
         config,
         lsn,
         {%State{status: :armed} = state, _attempt, keys}
       ) do
    active = %State{state | status: :active}

    upsert_checkpoint_fields(config, %{
      commit_lsn: lsn,
      snapshot_state: encode_snapshot_state!(config, active, keys)
    })
  end

  defp upsert_stream_checkpoint!(config, lsn, {%State{status: :active}, _attempt, _keys}),
    do: upsert_checkpoint(config, lsn)

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
  # Under the checkpoint row lock, so retirement, the replay fence, the
  # watermark advance and the state commit are ONE atomic step.
  defp complete_snapshot_transaction!(config, snapshot_lsn) do
    guard_generation!(config)

    row = locked_checkpoint_row!(config)

    case row.commit_lsn do
      # Monotonic handoff is also a RETIREMENT fence. A stream row committed
      # beyond this snapshot point carries no marker from this attempt; scanning
      # before this comparison could delete it and the higher checkpoint would
      # then prevent replay. Return before every row scan and state write.
      # Equality is a legitimate operator-authorized re-export at the same
      # consistent point under a later owner; only a STRICTLY newer durable
      # frontier proves this completion is stale.
      cp when is_integer(cp) and snapshot_lsn < cp ->
        :ok

      _ ->
        cond do
          # ADR-0018 §4: an append sink's backfill attempt is CLOSED at handoff
          # and nothing is retired — there is no managed row set to sweep. It
          # still has to close: the streamed changes that follow read the same
          # envelope, and an attempt left `:active` forever would make every
          # post-handoff transaction halt `:snapshot_state_invalid`.
          append_sink?(config) -> close_append_attempt!(config, row, snapshot_lsn)
          Retirement.provenance_sink?(config) -> complete_attempt!(config, row, snapshot_lsn)
          true -> :ok
        end

        upsert_checkpoint(config, snapshot_lsn)
    end

    guard_generation!(config)
  end

  # The append sink's handoff close (ADR-0018 §4): transition the v1 attempt to
  # `:complete` and stop. No fingerprint comparison, no membership marker, and
  # no retirement sweep — an append log never removes a stored event, so there
  # is nothing an unseen row could mean. An attempt already complete (a
  # redelivered handoff) is a no-op.
  defp close_append_attempt!(config, row, snapshot_lsn) do
    keys = provenance_keys!(config)

    case decode_snapshot_state(row, keys) do
      {:ok, %State{mode: :v1, status: :complete}} ->
        :ok

      {:ok, %State{mode: :v1} = state} ->
        # `completed_lsn` is NOT optional decoration: a v1 envelope with status
        # `:complete` and no completion LSN fails `State`'s own impossible-pairing
        # gate, so writing one without it would halt every handoff.
        store_snapshot_state!(
          config,
          %State{state | status: :complete, completed_lsn: snapshot_lsn},
          keys
        )

      # No envelope at all: the handoff arrived without a single delivered
      # chunk (an empty source). Nothing was appended, so there is nothing to
      # close.
      :absent ->
        :ok

      _invalid ->
        rollback_conflict!(config, :snapshot_state_invalid)
    end
  end

  # ADR-0017's completion protocol. The permanent replay fence is checked FIRST,
  # BEFORE any row scan: incremental completion is an at-least-once callback, so
  # a completion whose reply was lost can be redelivered after a later stream
  # write has landed. That newer row carries no marker from the completed
  # attempt, and rescanning would misclassify it as unseen and retire it. An
  # idempotent final state is not enough — the fence is what makes redelivery a
  # genuine no-op.
  defp complete_attempt!(config, row, snapshot_lsn) do
    keys = provenance_keys!(config)
    digest = contract_digest!(config)

    case decode_snapshot_state(row, keys) do
      {:ok,
       %State{
         mode: :v1,
         status: :complete,
         delivery_run: run,
         completed_lsn: completed
       }}
      when run == config.delivery_run and completed == snapshot_lsn ->
        :fenced

      {:ok, %State{mode: :v1, status: status, delivery_run: run, contract_digest: bound} = state}
      when status in [:armed, :active] and run == config.delivery_run and bound == digest ->
        Retirement.retire_unseen!(config, state.attempt, snapshot_lsn)

        store_snapshot_state!(
          config,
          %State{state | status: :complete, completed_lsn: snapshot_lsn},
          keys
        )

      _no_matching_attempt ->
        # No armed or active attempt for this run and contract. Completion has
        # nothing to fence and nothing to complete; retiring under a fabricated
        # attempt would delete every managed row.
        rollback_conflict!(config, :snapshot_state_invalid)
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

  defp apply_snapshot_batch(_config, _resource, [], _snapshot_lsn, _ordinal_base), do: :ok

  # ADR-0018 §4: an APPEND target's backfill rows keep `op: :snapshot`, which is
  # what stamps `operation`/`origin` as a backfill event rather than a streamed
  # insert. They also route PER RECORD unconditionally: the mirror's bulk arm
  # exists to amortize a column-homogeneous upsert, while an append row's
  # structural inputs differ per row (the ordinal) and the payload can be
  # tenant- or classification-scoped.
  defp apply_snapshot_batch(config, resource, changes, snapshot_lsn, ordinal_base)
       when is_list(changes) do
    if Info.append_log?(resource) do
      changes
      |> Enum.with_index(ordinal_base)
      |> Enum.each(fn {c, ordinal} ->
        guard_generation!(config)

        Apply.apply_change(config, %{
          c
          | op: :snapshot,
            commit_lsn: snapshot_lsn,
            ordinal: ordinal
        })

        guard_generation!(config)
      end)
    else
      apply_mirror_snapshot_batch(config, resource, changes, snapshot_lsn, ordinal_base)
    end
  end

  defp apply_mirror_snapshot_batch(config, resource, changes, snapshot_lsn, ordinal_base) do
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

      # The bulk upsert runs the notifier dependency pre-load exactly as the
      # per-record path does (`return_notifications?: true` keeps it alive
      # under `return_records?: false`), so it takes the same binding check.
      Apply.Context.verify_notifier_loads!(
        config,
        resource,
        Resolver.upsert_action(resource),
        :snapshot
      )

      result =
        Apply.Context.with_admitted_manifest(config, fn ->
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
        end)

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
    # An APPEND target has no primary create — its ONE delivery action is the
    # declared immutable append (ADR-0018 §2), and asking for a primary create
    # here raises before a single backfill row is written.
    {action, op} =
      if Info.append_log?(resource) do
        {Info.replicant_append_action!(resource), :append}
      else
        {Resolver.upsert_action(resource), :upsert}
      end

    tenants =
      if tenant_scoped?(resource) do
        changes
        |> Enum.map(&Resolver.resolve_tenant!(resource, &1.record, op))
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

          row = locked_checkpoint_row!(config)

          case row.commit_lsn do
            cp when is_integer(cp) and lsn <= cp ->
              guard_generation!(config)
              :skipped

            _ ->
              incremental = stream_incremental_attempt!(config, row)
              count = apply_all(config, changes, ts, messages, lsn, incremental)
              guard_generation!(config)
              upsert_stream_checkpoint!(config, lsn, incremental)
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
  defp apply_all(config, changes, ts, messages, commit_lsn, incremental) do
    {count, remaining} =
      Enum.reduce(changes, {0, messages}, fn change, {n, msgs} ->
        {n, msgs} = flush_messages_before(config, msgs, change.ordinal, n, commit_lsn)

        guard_generation!(config)
        Apply.apply_change(config, change, ts)
        mark_stream_change!(config, change, incremental)
        guard_generation!(config)

        {n + 1, msgs}
      end)

    {count, _} = flush_messages_before(config, remaining, :infinity, count, commit_lsn)
    count
  end

  defp mark_stream_change!(_config, _change, :none), do: :ok

  defp mark_stream_change!(config, change, {_state, attempt, _keys}),
    do: Snapshot.Rows.mark_stream_change!(config, change, attempt)

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
        apply_routed_message(config, message, route, commit_lsn)

      {:error, :unmapped} ->
        raise Error.exception(
                reason: :message_prefix_unmapped,
                resource: nil,
                op: :message
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
            op: :message
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
      apply_routed_message(config, message, route, nil)
      advance_message_watermark(config, lsn)
      :ok
    else
      result =
        config.repo.transaction(
          fn ->
            guard_generation!(config)
            apply_routed_message(config, message, route, nil)
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

  defp apply_routed_message(config, message, route, txn_commit_lsn) do
    if append_sink?(config) do
      Append.apply_message(config, message, route, txn_commit_lsn)
    else
      Messages.apply(config, message, route, txn_commit_lsn)
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
  defp locked_checkpoint!(config), do: locked_checkpoint_row!(config).commit_lsn

  # The same locked admission read, returning the WHOLE row: the snapshot
  # protocol needs `snapshot_state` under the same `FOR UPDATE` that guards the
  # watermark, or the state and the frontier could be read from different
  # serialization points.
  defp locked_checkpoint_row!(config) do
    case Ash.get!(config.checkpoint_resource, checkpoint_filter(config),
           lock: :for_update,
           authorize?: false,
           context: action_context(config),
           error?: false
         ) do
      nil -> rollback_conflict!(config, :checkpoint_unbound)
      row -> row
    end
  end

  defp upsert_checkpoint(config, lsn), do: upsert_checkpoint_fields(config, %{commit_lsn: lsn})

  # `upsert_fields` names exactly the supplied columns, so writing the snapshot
  # state never disturbs the watermark and vice versa.
  defp upsert_checkpoint_fields(config, fields) when is_map(fields) do
    Ash.create!(
      config.checkpoint_resource,
      Map.merge(checkpoint_filter(config), fields),
      action: :upsert,
      upsert?: true,
      upsert_identity: :source_slot,
      upsert_fields: Map.keys(fields),
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
