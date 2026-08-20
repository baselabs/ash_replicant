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

  defp apply_row!(config, resource, reflection, change, snapshot_lsn, ordinal, attempt) do
    change = %{change | op: :insert, commit_lsn: snapshot_lsn, ordinal: ordinal}
    record = change.record
    tenant = Resolver.resolve_tenant!(resource, record, :snapshot)
    {inputs, _upsert_fields} = Resolver.upsert_input(reflection, record)

    fingerprint =
      case Provenance.fingerprint(resource, tenant, inputs, attempt.key_version, attempt.keys) do
        {:ok, fingerprint} -> fingerprint
        {:error, _reason} -> raise provenance_unavailable(resource)
      end

    case verdict(config, resource, record, tenant, inputs, snapshot_lsn, attempt) do
      :match ->
        # Bookkeeping only. The host business action does NOT run.
        mark!(config, resource, record, tenant, change, snapshot_lsn, attempt, fingerprint)

      :changed ->
        Apply.apply_change(config, change)
        mark!(config, resource, record, tenant, change, snapshot_lsn, attempt, fingerprint)

      {:error, _reason} ->
        raise provenance_unavailable(resource)
    end
  end

  # An absent target, or one carrying no fingerprint at all, is `:changed`: the
  # host action has to run. Only a stored fingerprint that MATCHES may skip it.
  defp verdict(config, resource, record, tenant, inputs, snapshot_lsn, attempt) do
    case current_target(config, resource, record, tenant, snapshot_lsn) do
      nil ->
        :changed

      %{replica_fingerprint: nil} ->
        :changed

      %{replica_fingerprint: stored} ->
        Provenance.compare(stored, resource, tenant, inputs, attempt.keys)
    end
  end

  defp current_target(config, resource, record, tenant, snapshot_lsn) do
    config
    |> target_query(resource, record, snapshot_lsn)
    |> Ash.read_one!(tenant: tenant, authorize?: config.authorize?)
  rescue
    e in AshReplicant.Error -> reraise e, __STACKTRACE__
    e -> reraise Error.scrub(e, resource, :snapshot), __STACKTRACE__
  end

  # SCD1 targets the mirrored row by primary key; SCD2 targets the CURRENT OPEN
  # version by business key. `inclusive?: true` is required for the post-apply
  # mark: the version this run just opened carries `valid_from_lsn == lsn`, and
  # the exclusive predicate would miss it.
  defp target_query(config, resource, record, snapshot_lsn) do
    query =
      if Info.history_scd2?(resource) do
        Resolver.open_version_query(resource, record, snapshot_lsn, inclusive?: true)
      else
        Ash.Query.do_filter(resource, present_pk!(resource, record))
      end

    Ash.Query.set_context(query, Context.action_context(config))
  end

  # A nil PK would filter `id IS NULL`, match nothing, and make the row look
  # absent — so it would run the host action and then fail the mark. Fail on the
  # real cause instead. Mirrors `Apply.destroy_by_pk`'s guard.
  defp present_pk!(resource, record) do
    pk = Resolver.pk_values(resource, record)

    if Enum.any?(pk, fn {_key, value} -> is_nil(value) end) do
      raise Error.exception(reason: :sink_failed, resource: resource, op: :snapshot)
    end

    pk
  end

  # The ONE write path to the two protected attributes. The values ride the
  # changeset context, which is the channel `AshReplicant.Snapshot.MarkSeen`
  # reads and the compile verifier proves no other action can reach.
  #
  # The fingerprint is always supplied, even on a `:match`: it is recomputed
  # under the ACTIVE key version, so a rotation sweep re-stamps rows minted
  # under a retained key and the old key can eventually be dropped.
  defp mark!(config, resource, record, tenant, change, snapshot_lsn, attempt, fingerprint) do
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
      |> target_query(resource, record, snapshot_lsn)
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
end
