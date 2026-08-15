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
  alias AshReplicant.Apply.Context
  alias AshReplicant.Apply.Scd2
  alias AshReplicant.{Error, Resolver, Sql}
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
    assert_source_coverage!(config, change)

    case resource_for(config, change) do
      nil ->
        :ok

      resource ->
        if Info.history_scd2?(resource) do
          Scd2.apply(config, resource, change, commit_timestamp)
        else
          apply_to(config, resource, change, commit_timestamp)
        end
    end
  end

  defp resource_for(config, %{schema: schema, table: table}) do
    Resolver.lookup(config.resolver_index, schema, table)
  end

  # B3 delivery-side accounting: the change's table must be mapped (or
  # explicitly ignored) and every delivered column mapped or skipped — BEFORE
  # any write. The facts derive from the resource via upsert_reflection (no
  # Generation dependency); the ignored-table set rides the runtime config
  # (default empty for bare unit configs).
  defp assert_source_coverage!(config, change) do
    facts =
      case resource_for(config, change) do
        nil -> %{}
        resource -> coverage_facts(resource)
      end

    AshReplicant.Coverage.assert_change!(facts, coverage_ignored(config), change)
  end

  defp coverage_facts(resource) do
    {skip, _cloak, _attrs} = Resolver.upsert_reflection(resource)

    %{
      {AshReplicant.Resource.Info.source_schema(resource),
       AshReplicant.Resource.Info.source_table(resource)} => %{
        resource: resource,
        mapped: AshReplicant.Coverage.source_mapped_set(resource),
        skips: skip |> Enum.map(&Atom.to_string/1) |> MapSet.new(),
        target_types: %{},
        tenant?: false,
        scd2?: false,
        business_key: []
      }
    }
  end

  defp coverage_ignored(config) do
    case Map.get(config, :coverage) do
      %{ignored: ignored} -> ignored
      _other -> MapSet.new()
    end
  end

  defp apply_to(config, resource, %{op: op} = change, _commit_timestamp)
       when op in [:insert, :update] do
    # The B4 tri-modal prelude: resolve BOTH tenants up front — :indeterminate
    # (absent/blank/false old side, or a raising resolver) halts BEFORE any
    # write (activation preflight enforces RIF, so old_record carries the
    # discriminator; an old-side failure is a genuine fault). A PK change OR
    # a :reassigned transition must RELOCATE the row (destroy-old +
    # upsert-new): on a tenant change, a tenant-scoped upsert identity
    # `(tenant, pk)` misses its conflict target under the new tenant and
    # INSERTs, colliding with the row's GLOBAL primary key.
    {:ok, transition, _old_tenant, _new_tenant} =
      Resolver.require_tenant_pair!(resource, change, op)

    if op == :update and (pk_changed?(resource, change) or transition == :reassigned) do
      destroy_by_pk(config, resource, change.old_record, change, :destroy_prior)
    end

    upsert(config, resource, change)
  end

  defp apply_to(config, resource, %{op: :delete} = change, _commit_timestamp) do
    destroy_by_pk(config, resource, change.old_record, change, :destroy_prior)
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

        SQL.query!(
          config.repo,
          "DELETE FROM " <>
            Sql.quote_identifier(pg_schema) <> "." <> Sql.quote_identifier(pg_table),
          []
        )

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
  catch
    # D3: throw/exit scrub with the SAME op label so triage keeps the
    # operation name (reraise keeps the origin stacktrace).
    :throw, value -> reraise Error.scrub(value, resource, :truncate), __STACKTRACE__
    :exit, value -> reraise Error.scrub(value, resource, :truncate), __STACKTRACE__
  end

  defp upsert(config, resource, change) do
    {inputs, upsert_fields} = Resolver.attrs_for_upsert(resource, change.record)
    tenant = Resolver.resolve_tenant!(resource, change.record, :upsert)
    action = Resolver.upsert_action(resource)
    Context.preflight_onetime!(config, tenant, resource, action, :upsert)

    Ash.create!(resource, inputs,
      action: action,
      upsert?: true,
      upsert_identity: Resolver.upsert_identity(resource),
      upsert_fields: upsert_fields,
      tenant: tenant,
      authorize?: config.authorize?,
      context: Context.action_context(config, change, :upsert),
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
  catch
    :throw, value -> reraise Error.scrub(value, resource, :upsert), __STACKTRACE__
    :exit, value -> reraise Error.scrub(value, resource, :upsert), __STACKTRACE__
  end

  defp destroy_by_pk(config, resource, old_record, change, invocation) do
    pk_values = Resolver.pk_values(resource, old_record)

    # Fail closed on a missing PK BEFORE building the filter: a nil PK value would
    # produce `id == nil`, which matches 0 rows and would silently "succeed" — losing
    # the no-silent-lost-delete contract. Keep this guard ahead of the query.
    if Enum.any?(pk_values, fn {_k, v} -> is_nil(v) end) do
      raise Error.exception(reason: :sink_failed, resource: resource, op: :destroy)
    end

    tenant = Resolver.resolve_tenant!(resource, old_record, :destroy)
    action = Resolver.destroy_action(resource)
    Context.preflight_onetime!(config, tenant, resource, action, :destroy)

    query =
      resource
      |> Ash.Query.do_filter(pk_values)
      |> Ash.Query.set_context(Context.action_context(config, change, invocation))

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
    Ash.bulk_destroy!(query, action, %{},
      strategy: [:atomic, :stream],
      transaction: false,
      tenant: tenant,
      authorize?: config.authorize?,
      context: Context.action_context(config, change, invocation),
      return_errors?: true
    )

    :ok
  rescue
    e -> reraise Error.scrub(e, resource, :destroy), __STACKTRACE__
  catch
    :throw, value -> reraise Error.scrub(value, resource, :destroy), __STACKTRACE__
    :exit, value -> reraise Error.scrub(value, resource, :destroy), __STACKTRACE__
  end

  defp pk_changed?(resource, %{record: record, old_record: old}) when is_map(old) do
    Resolver.pk_values(resource, record) != Resolver.pk_values(resource, old)
  end

  defp pk_changed?(_resource, _change), do: false
end
