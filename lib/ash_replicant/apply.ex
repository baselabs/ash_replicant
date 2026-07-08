defmodule AshReplicant.Apply do
  @moduledoc """
  Applies one `%Replicant.Change{}` to the mirror. An insert/update/delete goes
  through a single-row Ash action; a `:mirror` truncate issues a bulk destroy.

  Called once per change, in delivery (`ordinal`) order, inside the sink's
  transaction. Raises on any failure so the surrounding `Repo.transaction`
  rolls the whole transaction back — the effect-once fail-closed contract.
  Never re-orders or coalesces changes: a spilled transaction's `changes` is a
  lazy single-pass Enumerable, so the caller iterates it exactly once.
  """

  alias AshPostgres.DataLayer.Info, as: PGInfo
  alias AshReplicant.{Error, Resolver}
  alias AshReplicant.Resource.Info
  alias Ecto.Adapters.SQL

  @doc """
  Apply a change under `config` (`%{resolver_index:, repo:, authorize?:}`).
  Returns `:ok`; raises `AshReplicant.Error` (value-free) on failure.
  A change whose `{schema, table}` is not a mirror target is ignored.
  """
  @spec apply_change(map(), Replicant.Change.t()) :: :ok
  def apply_change(config, %Replicant.Change{} = change) do
    case resource_for(config, change) do
      nil -> :ok
      resource -> apply_to(config, resource, change)
    end
  end

  defp resource_for(config, %{schema: schema, table: table}) do
    Map.get(config.resolver_index, {schema || "public", table})
  end

  defp apply_to(config, resource, %{op: op} = change) when op in [:insert, :update] do
    if op == :update and pk_changed?(resource, change) do
      destroy_by_pk(config, resource, change.old_record)
    end

    upsert(config, resource, change)
  end

  defp apply_to(config, resource, %{op: :delete} = change) do
    destroy_by_pk(config, resource, change.old_record)
  end

  defp apply_to(config, resource, %{op: :truncate, table: table, schema: schema}) do
    case Info.replicant_on_truncate!(resource) do
      :mirror ->
        # Tenant-blind: a TRUNCATE wipes ALL tenants, and an Ash `bulk_destroy` on a
        # NON-GLOBAL attribute-multitenant resource raises `TenantRequired` (there is
        # no single tenant to scope by) — the exact defect `Impl.clear_mirror/2`
        # documents and avoids. Delete on the mirror's own table inside the sink
        # transaction; the schema/table come from the resource DSL (operator trust
        # boundary), never a row value, and idents are quoted.
        pg_schema = PGInfo.schema(resource) || "public"
        pg_table = PGInfo.table(resource)
        SQL.query!(config.repo, ~s(DELETE FROM "#{pg_schema}"."#{pg_table}"), [])
        :ok

      :halt ->
        raise Error.exception(
                reason: :truncate_halt,
                resource: resource,
                op: :truncate,
                shape: "#{schema}.#{table}"
              )
    end
  rescue
    e -> reraise Error.scrub(e, resource, :truncate), __STACKTRACE__
  end

  defp upsert(config, resource, change) do
    {inputs, upsert_fields} = Resolver.attrs_for_upsert(resource, change.record)
    tenant = resolve_tenant!(resource, change.record, :upsert)

    Ash.create!(resource, inputs,
      action: Resolver.upsert_action(resource),
      upsert?: true,
      upsert_identity: Resolver.upsert_identity(resource),
      upsert_fields: upsert_fields,
      tenant: tenant,
      authorize?: config.authorize?,
      # The sink owns the single outer Repo.transaction these actions join (spec
      # decision 7); `transaction?: false` skips a redundant per-row savepoint on
      # the upsert. (`Ash.destroy!` has no `transaction?` option — its per-action
      # transaction is host-action-level config — so the destroy path below cannot
      # take the same flag and simply joins the ambient sink transaction.)
      transaction?: false,
      return_notifications?: true
    )

    :ok
  rescue
    e -> reraise Error.scrub(e, resource, :upsert), __STACKTRACE__
  end

  defp destroy_by_pk(config, resource, old_record) do
    pk_values = Resolver.pk_values(resource, old_record)

    if Enum.any?(pk_values, fn {_k, v} -> is_nil(v) end) do
      raise Error.exception(reason: :sink_failed, resource: resource, op: :destroy)
    end

    tenant = resolve_tenant!(resource, old_record, :destroy)

    case Ash.get!(resource, pk_values,
           authorize?: config.authorize?,
           tenant: tenant,
           error?: false
         ) do
      nil ->
        :ok

      record ->
        Ash.destroy!(record,
          authorize?: config.authorize?,
          tenant: tenant,
          return_notifications?: true
        )
    end

    :ok
  rescue
    e -> reraise Error.scrub(e, resource, :destroy), __STACKTRACE__
  end

  defp pk_changed?(resource, %{record: record, old_record: old}) when is_map(old) do
    Resolver.pk_values(resource, record) != Resolver.pk_values(resource, old)
  end

  defp pk_changed?(_resource, _change), do: false

  defp resolve_tenant!(resource, record, op) do
    case Resolver.resolve_tenant(resource, record) do
      {:ok, tenant} ->
        tenant

      {:error, :tenant_required} ->
        raise Error.exception(reason: :tenant_required, resource: resource, op: op)
    end
  end
end
