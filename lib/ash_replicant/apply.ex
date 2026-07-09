defmodule AshReplicant.Apply do
  @moduledoc """
  Applies one `%Replicant.Change{}` to the mirror. An insert/update goes through a
  single-row Ash action; a delete issues one atomic `bulk_destroy` over a PK-filtered
  query; a `:mirror` truncate deletes the mirror table directly.

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

  `commit_timestamp` (optional, defaults to `nil`) is the change's transaction
  commit time, threaded through for SCD2 dispatch; unused on the SCD1 path.
  """
  @spec apply_change(map(), Replicant.Change.t(), DateTime.t() | nil) :: :ok
  def apply_change(config, change, commit_timestamp \\ nil)

  def apply_change(config, %Replicant.Change{} = change, commit_timestamp) do
    case resource_for(config, change) do
      nil -> :ok
      resource -> apply_to(config, resource, change, commit_timestamp)
    end
  end

  defp resource_for(config, %{schema: schema, table: table}) do
    Resolver.lookup(config.resolver_index, schema, table)
  end

  defp apply_to(config, resource, %{op: op} = change, _commit_timestamp)
       when op in [:insert, :update] do
    if op == :update and pk_changed?(resource, change) do
      destroy_by_pk(config, resource, change.old_record)
    end

    upsert(config, resource, change)
  end

  defp apply_to(config, resource, %{op: :delete} = change, _commit_timestamp) do
    destroy_by_pk(config, resource, change.old_record)
  end

  defp apply_to(
         config,
         resource,
         %{op: :truncate, table: table, schema: schema},
         _commit_timestamp
       ) do
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

    # Fail closed on a missing PK BEFORE building the filter: a nil PK value would
    # produce `id == nil`, which matches 0 rows and would silently "succeed" — losing
    # the no-silent-lost-delete contract. Keep this guard ahead of the query.
    if Enum.any?(pk_values, fn {_k, v} -> is_nil(v) end) do
      raise Error.exception(reason: :sink_failed, resource: resource, op: :destroy)
    end

    tenant = resolve_tenant!(resource, old_record, :destroy)
    query = Ash.Query.do_filter(resource, pk_values)

    # One atomic `DELETE ... WHERE pk` (single round-trip) instead of read-then-destroy.
    # `strategy: [:atomic, :stream]` takes the data-layer atomic path for the mirror's
    # plain destroy and falls back to per-record streaming when the host's destroy
    # action carries non-atomic changes (so any host-defined destroy hooks still fire).
    # Row-effect (removal, tenant scope, idempotency) is identical to the prior
    # get!-then-destroy!; the one non-equivalence is that a host `:destroy` whose
    # after_action hook reads `changeset.data` sees `%OriginalDataNotAvailable{}` on the
    # atomic path (the cost of not loading the row) — the mirror's own `defaults
    # [:destroy]` has no such hook, so this is inert for the sink's use.
    # `transaction: false` joins the sink's ambient outer transaction (spec decision 7),
    # never opening its own savepoint. Tenant scopes the DELETE (fail-closed, resolved
    # above). A 0-row match (already-absent row) is `:success` → `:ok` (idempotent).
    # `notify?` defaults to false, so no notifier fires for mirrored changes (the sink
    # contract), matching the prior `return_notifications?: true` bundle-and-discard.
    Ash.bulk_destroy!(query, Resolver.destroy_action(resource), %{},
      strategy: [:atomic, :stream],
      transaction: false,
      tenant: tenant,
      authorize?: config.authorize?,
      return_errors?: true
    )

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
