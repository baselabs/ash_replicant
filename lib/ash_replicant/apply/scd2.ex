defmodule AshReplicant.Apply.Scd2 do
  @moduledoc """
  SCD2 (validity-windowed) apply strategy, dispatched from `Apply.apply_change/3` when
  `Info.history_scd2?(resource)`. Each change CLOSES the current open version (an Ash
  `bulk_update` through the host close action, tenant-scoped, so it never retires
  another tenant's identically-keyed version) and OPENS a new version (host `:create`
  upsert by the `(business_key, valid_from_lsn)` identity), inside the sink's outer
  transaction (`transaction: false`). Op-dependent close predicate: insert/update close
  `valid_from_lsn < lsn` (don't clobber the version being re-opened at `lsn`); delete
  closes `valid_from_lsn <= lsn` (retire a same-commit version too). Value-free: every
  raising op is scrubbed to a structural reason.
  """

  alias AshReplicant.{Error, Resolver}
  alias AshReplicant.Resource.Info

  @spec apply(map(), module(), Replicant.Change.t(), DateTime.t() | nil) :: :ok
  def apply(config, resource, %{op: op} = change, ts) when op in [:insert, :update] do
    lsn = change.commit_lsn

    if op == :update and bk_changed?(resource, change) do
      old_tenant = resolve_tenant!(resource, change.old_record, :destroy)
      close_current(config, resource, change.old_record, lsn, ts, old_tenant, inclusive?: false)
    end

    tenant = resolve_tenant!(resource, change.record, :upsert)
    close_current(config, resource, change.record, lsn, ts, tenant, inclusive?: false)
    open_version(config, resource, change.record, lsn, ts, tenant)
    :ok
  rescue
    e -> reraise Error.scrub(e, resource, :upsert), __STACKTRACE__
  end

  def apply(config, resource, %{op: :delete} = change, ts) do
    lsn = change.commit_lsn
    tenant = resolve_tenant!(resource, change.old_record, :destroy)
    close_current(config, resource, change.old_record, lsn, ts, tenant, inclusive?: true)
    :ok
  rescue
    e -> reraise Error.scrub(e, resource, :destroy), __STACKTRACE__
  end

  # :truncate clause added in Task 7.

  defp close_current(config, resource, record, lsn, ts, tenant, opts) do
    # Fail closed on a nil business key BEFORE building the close query: a nil value
    # would produce `bk IS NULL and ...`, match 0 rows, and SILENTLY close nothing —
    # losing the no-silent-lost-delete contract on the terminal (delete) path (unlike
    # the open path, which fails at `allow_nil? false`). Mirrors `Apply.destroy_by_pk`'s
    # PK-nil guard. Value-free structural reason; the per-clause `rescue` scrubs it.
    if resource
       |> Resolver.business_key_values(record)
       |> Enum.any?(fn {_k, v} -> is_nil(v) end) do
      raise Error.exception(reason: :sink_failed, resource: resource, op: :sink)
    end

    query = Resolver.open_version_query(resource, record, lsn, opts)

    Ash.bulk_update!(
      query,
      Info.replicant_history_close_action!(resource),
      close_input(resource, lsn, ts),
      strategy: [:atomic, :stream],
      transaction: false,
      tenant: tenant,
      authorize?: config.authorize?,
      return_notifications?: true,
      return_errors?: true
    )

    :ok
  end

  defp open_version(config, resource, record, lsn, ts, tenant) do
    {inputs, upsert_fields} = Resolver.version_open_input(resource, record, %{lsn: lsn, ts: ts})

    Ash.create!(resource, inputs,
      action: Resolver.upsert_action(resource),
      upsert?: true,
      upsert_identity: Resolver.upsert_identity(resource),
      upsert_fields: upsert_fields,
      tenant: tenant,
      authorize?: config.authorize?,
      transaction?: false,
      return_notifications?: true
    )

    :ok
  end

  defp close_input(resource, lsn, ts) do
    to_lsn = Info.replicant_history_valid_to_lsn_attribute!(resource)
    to_ts = opt(Info.replicant_history_valid_to_timestamp_attribute(resource))
    current = opt(Info.replicant_history_current_attribute(resource))

    %{to_lsn => lsn}
    |> maybe_put(to_ts, ts)
    |> maybe_put(current, false)
  end

  defp bk_changed?(resource, %{record: r, old_record: o}) when is_map(o),
    do: Resolver.business_key_values(resource, r) != Resolver.business_key_values(resource, o)

  defp bk_changed?(_resource, _change), do: false

  defp resolve_tenant!(resource, record, op) do
    case Resolver.resolve_tenant(resource, record) do
      {:ok, tenant} ->
        tenant

      {:error, :tenant_required} ->
        raise Error.exception(reason: :tenant_required, resource: resource, op: op)
    end
  end

  defp opt({:ok, v}), do: v
  defp opt(_), do: nil
  defp maybe_put(map, nil, _v), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
