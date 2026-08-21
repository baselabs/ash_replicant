defmodule AshReplicant.Snapshot.Rows do
  @moduledoc """
  The per-row snapshot apply for a `snapshot_provenance true` resource
  (S02, ADR-0017).

  Each kept snapshot row is resolved and applied inside the checkpoint-locked
  destination transaction:

  1. resolve the tenant and the current open target through the admitted
     action graph;
  2. calculate the canonical fingerprint over exactly the mapped host-action
     inputs, the resolved tenant, and the resource identity;
  3. if the stored fingerprint matches, invoke ONLY the private mark action; and
  4. otherwise invoke the normal host business action and then stamp the
     fingerprint and membership through that same private mark action.

  Step 3 is the whole point of the slice. A retry that re-ran the host `:create`
  for an unchanged row would repeat any append-only local effect that action
  carries — an audit insert, an outbox row, an AshOnetime-claimed auxiliary
  write — even though the mirror row converges to identical bytes. Marking is
  reported honestly as an internal effect; it is not a host business effect.

  An UNKNOWN comparison answer (a dropped key, an unknown encoding version, a
  value that cannot be deterministically encoded) fails CLOSED. It must never
  degrade to `:changed`: that is precisely the "re-run every business action"
  outcome the fingerprint exists to avoid, and it would be silent.

  The mark is verified to have landed on exactly one row. A mark that stamps
  nothing is not a harmless no-op — completion would then retire the row this
  attempt had just seen.
  """

  alias AshReplicant.Apply
  alias AshReplicant.Apply.Context
  alias AshReplicant.Error
  alias AshReplicant.Resolver
  alias AshReplicant.Resource.Info
  alias AshReplicant.Snapshot.{MarkSeen, Provenance}

  @doc """
  Apply one snapshot batch under `attempt`. Raises a value-free
  `AshReplicant.Error` on any failure so the surrounding transaction rolls back.
  """
  @spec apply_batch!(map(), module(), [Replicant.Change.t()], integer(), non_neg_integer(), %{
          attempt: binary(),
          keys: Provenance.key_set(),
          key_version: pos_integer()
        }) :: :ok
  def apply_batch!(config, resource, changes, snapshot_lsn, ordinal_base, attempt) do
    reflection = Resolver.upsert_reflection(resource)

    changes
    |> Enum.with_index(ordinal_base)
    |> Enum.each(fn {change, ordinal} ->
      apply_row!(config, resource, reflection, change, snapshot_lsn, ordinal, attempt)
    end)

    :ok
  end

  @doc "Stamp a streamed insert/update with the active incremental membership marker."
  @spec mark_stream_change!(map(), Replicant.Change.t(), map()) :: :ok
  def mark_stream_change!(config, %Replicant.Change{op: op} = change, attempt)
      when op in [:insert, :update] do
    case Resolver.lookup(config.resolver_index, change.schema, change.table) do
      nil ->
        :ok

      resource ->
        mark_stream_resource!(config, resource, change, attempt)
    end
  end

  def mark_stream_change!(_config, _change, _attempt), do: :ok

  defp mark_stream_resource!(config, resource, change, attempt) do
    if Info.replicant_snapshot_provenance!(resource) do
      reflection = Resolver.upsert_reflection(resource)
      tenant = Resolver.resolve_tenant!(resource, change.record, :snapshot)
      {inputs, _upsert_fields} = Resolver.upsert_input(reflection, change.record)
      lookup = %{record: change.record, inputs: inputs}
      fingerprint = fingerprint!(resource, tenant, inputs, attempt)

      mark!(
        config,
        resource,
        lookup,
        tenant,
        change,
        attempt,
        fingerprint
      )
    else
      :ok
    end
  end

  defp apply_row!(config, resource, reflection, change, snapshot_lsn, ordinal, attempt) do
    change = %{change | op: :insert, commit_lsn: snapshot_lsn, ordinal: ordinal}
    record = change.record
    tenant = Resolver.resolve_tenant!(resource, record, :snapshot)
    {inputs, _upsert_fields} = Resolver.upsert_input(reflection, record)
    lookup = %{record: record, inputs: inputs}

    fingerprint = fingerprint!(resource, tenant, inputs, attempt)

    case verdict(config, resource, lookup, tenant, snapshot_lsn, attempt) do
      :match ->
        # Bookkeeping only. The host business action does NOT run.
        mark!(
          config,
          resource,
          lookup,
          tenant,
          change,
          attempt,
          fingerprint
        )

      :changed ->
        Apply.apply_change(config, change)

        mark!(
          config,
          resource,
          lookup,
          tenant,
          change,
          attempt,
          fingerprint
        )

      {:error, _reason} ->
        raise provenance_unavailable(resource)
    end
  end

  # An absent target, or one carrying no fingerprint at all, is `:changed`: the
  # host action has to run. Only a stored fingerprint that MATCHES may skip it.
  defp verdict(config, resource, lookup, tenant, snapshot_lsn, attempt) do
    case current_target(config, resource, lookup, tenant) do
      nil ->
        :changed

      %{replica_fingerprint: nil} = target ->
        ensure_snapshot_order!(resource, target, snapshot_lsn)
        :changed

      %{replica_fingerprint: stored} = target ->
        case Provenance.compare(stored, resource, tenant, lookup.inputs, attempt.keys) do
          :match ->
            :match

          :changed ->
            ensure_snapshot_order!(resource, target, snapshot_lsn)
            :changed

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp current_target(config, resource, lookup, tenant) do
    config
    |> target_query(resource, lookup)
    |> Ash.read_one!(tenant: tenant, authorize?: config.authorize?)
  rescue
    e in AshReplicant.Error -> reraise e, __STACKTRACE__
    e -> reraise Error.scrub(e, resource, :snapshot), __STACKTRACE__
  end

  # SCD1 targets the mirrored row by the SAME configured identity used by its
  # upsert (the PK only when no alternate identity is declared); SCD2 targets
  # the CURRENT OPEN version by business key regardless of its opening LSN.
  #
  # An incremental stream change may commit before this table's snapshot window
  # opens. The later snapshot read then contains that already-current source row.
  # Restricting the lookup to `valid_from_lsn <= snapshot_lsn` misses the newer
  # destination version and tries to open a second current version at the floor.
  # Comparing the actual current version lets an identical row coalesce through
  # provenance. A mismatch against a version newer than the snapshot floor is
  # rejected explicitly before any host close/open action runs.
  defp target_query(config, resource, lookup) do
    query =
      if Info.history_scd2?(resource) do
        Resolver.current_open_version_query(resource, lookup.record)
      else
        case Resolver.upsert_lookup_query(resource, lookup.inputs) do
          {:ok, query} -> query
          :error -> raise Error.exception(reason: :sink_failed, resource: resource, op: :snapshot)
        end
      end

    Ash.Query.set_context(query, Context.action_context(config))
  end

  defp ensure_snapshot_order!(resource, target, snapshot_lsn) do
    if Info.history_scd2?(resource) do
      from_lsn = Info.replicant_history_valid_from_lsn_attribute!(resource)

      case Map.get(target, from_lsn) do
        current_lsn
        when is_integer(current_lsn) and current_lsn >= 0 and current_lsn <= snapshot_lsn ->
          :ok

        _newer_or_invalid ->
          raise Error.exception(
                  reason: :snapshot_state_invalid,
                  resource: resource,
                  op: :snapshot
                )
      end
    else
      :ok
    end
  end

  # The ONE write path to the two protected attributes. The values ride the
  # changeset context, which is the channel `AshReplicant.Snapshot.MarkSeen`
  # reads and the compile verifier proves no other action can reach.
  #
  # The fingerprint is always supplied, even on a `:match`: it is recomputed
  # under the ACTIVE key version, so a rotation sweep re-stamps rows minted
  # under a retained key and the old key can eventually be dropped.
  defp mark!(
         config,
         resource,
         lookup,
         tenant,
         change,
         attempt,
         fingerprint
       ) do
    action = Info.replicant_snapshot_mark_action!(resource)
    Context.preflight_onetime!(config, tenant, resource, action, :snapshot_mark)
    Context.verify_notifier_loads!(config, resource, action, :snapshot_mark)

    context =
      Map.put(
        Context.action_context(config, change, :mark_seen),
        MarkSeen.context_key(),
        %{attempt: attempt.attempt, fingerprint: fingerprint}
      )

    result =
      config
      |> target_query(resource, lookup)
      |> Ash.Query.set_context(context)
      |> Ash.bulk_update!(action, %{},
        strategy: [:atomic, :stream],
        transaction: false,
        tenant: tenant,
        authorize?: config.authorize?,
        context: context,
        return_records?: true,
        return_errors?: true,
        return_notifications?: true
      )

    # A mark that stamped no row is the silent failure this contract exists to
    # prevent: completion would retire the row the attempt had just seen.
    #
    # Defensive depth, honestly labelled: the target query is the SAME one that
    # just resolved the row (or that the host action just wrote through), so no
    # test drives this red and none is claimed to. It is here because the cost
    # of the shape it catches is silent data loss, and the check is one length.
    if length(result.records || []) != 1 do
      raise Error.exception(reason: :sink_failed, resource: resource, op: :snapshot_mark)
    end

    :ok
  rescue
    e in AshReplicant.Error -> reraise e, __STACKTRACE__
    e -> reraise Error.scrub(e, resource, :snapshot_mark), __STACKTRACE__
  end

  defp provenance_unavailable(resource) do
    Error.exception(
      reason: :snapshot_provenance_unavailable,
      resource: resource,
      op: :snapshot
    )
  end

  defp fingerprint!(resource, tenant, inputs, attempt) do
    case Provenance.fingerprint(resource, tenant, inputs, attempt.key_version, attempt.keys) do
      {:ok, fingerprint} -> fingerprint
      {:error, _reason} -> raise provenance_unavailable(resource)
    end
  end
end
