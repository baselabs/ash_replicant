defmodule AshReplicant.Snapshot.Retirement do
  @moduledoc """
  Completion-time retirement of the rows a finished attempt never saw
  (S02, ADR-0017).

  Retirement replaces the destructive `first_for_table?` whole-resource clear.
  Instead of wiping a table before re-applying it — which repeats every host
  business effect and can erase a stream-applied row — completion retires
  exactly the managed open rows whose membership marker differs from the
  completed attempt's, through the host's own private retire action, under a
  resolved tenant.

  ## Scope enumeration

  Every destination tenant scope must be enumerated, or retirement is silently
  partial:

    * **no multitenancy, or `global? true`** — one scoped pass (`tenant: nil`);
    * **`strategy :attribute`** — `SELECT DISTINCT` over the verifier-approved
      plaintext, non-sensitive discriminator through the admitted Repo. The
      column enumerates itself, so this is complete by construction and needs
      no host cooperation. It is a READ; every retirement WRITE still goes
      through the host action with `tenant:` set;
    * **`strategy :context`** — there is no discriminator column, so the host's
      declared `snapshot_tenant_scope_action` is the authority. A missing,
      raising, or malformed enumeration fails CLOSED rather than retiring under
      a partial scope list.

  A tenant that exists ONLY in the destination — absent from the whole source
  attempt — is still enumerated and swept. That is the case a "retire the
  tenants we saw" implementation gets wrong and never notices.

  ## SCD2

  Retirement CLOSES an unseen open version through the private version-closing
  update. Closed history is immutable: the filter carries `is_nil(valid_to_lsn)`
  so an already-closed version is never matched, reopened, or destroyed.
  """

  require Ash.Query

  alias AshPostgres.DataLayer.Info, as: PGInfo
  alias AshReplicant.Apply.Context
  alias AshReplicant.Apply.Scd2
  alias AshReplicant.{Error, Sql}
  alias AshReplicant.Resource.Info
  alias Ecto.Adapters.SQL

  @attempt_attribute :replica_seen_attempt

  @doc """
  Retire every managed open row of every provenance-declaring mapped resource
  whose marker differs from `attempt`. Raises a value-free `AshReplicant.Error`
  on any failure, so the completion transaction rolls back whole.
  """
  @spec retire_unseen!(map(), binary(), integer()) :: :ok
  def retire_unseen!(config, attempt, snapshot_lsn) do
    _final_ordinal =
      config
      |> managed_resources()
      |> Enum.reduce(0, fn resource, ordinal ->
        config
        |> scopes!(resource)
        |> Enum.reduce(ordinal, fn tenant, ordinal ->
          retire_scope!(config, resource, tenant, attempt, snapshot_lsn, ordinal)
          ordinal + 1
        end)
      end)

    :ok
  end

  @doc """
  The mapped resources that opted into the provenance contract — the complete
  managed set, sorted so the retirement scan is deterministic.

  Anything outside this set is outside the declared managed scope and is never
  touched, no matter what rows it holds.
  """
  @spec managed_resources(map()) :: [module()]
  def managed_resources(config) do
    config
    |> Map.get(:resolver_index, %{})
    |> Map.values()
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&Info.replicant_snapshot_provenance!/1)
  end

  @doc """
  Whether this sink runs the provenance protocol at all — true when ANY mapped
  resource declares it. A sink with none behaves exactly as before, except that
  no callback clears a resource.
  """
  @spec provenance_sink?(map()) :: boolean()
  def provenance_sink?(config), do: managed_resources(config) != []

  # --- scope enumeration ---

  @doc false
  @spec scopes!(map(), module()) :: [term()]
  def scopes!(config, resource) do
    strategy = Ash.Resource.Info.multitenancy_strategy(resource)
    global? = Ash.Resource.Info.multitenancy_global?(resource) == true

    cond do
      is_nil(strategy) or global? -> [nil]
      strategy == :attribute -> attribute_scopes!(config, resource)
      true -> declared_scopes!(config, resource)
    end
  end

  # Tenant-blind READ of the discriminator, exactly the trust boundary the
  # `:mirror` truncate DELETE already occupies: identifiers come from the
  # resource DSL and route through the one quoting home, never from a row value,
  # and no value is interpolated.
  defp attribute_scopes!(config, resource) do
    schema = PGInfo.schema(resource) || "public"
    table = PGInfo.table(resource)
    attribute = Ash.Resource.Info.multitenancy_attribute(resource)
    column = column_name(resource, attribute)
    quoted = Sql.quote_identifier(column)

    %Postgrex.Result{rows: rows} =
      SQL.query!(
        config.repo,
        "SELECT DISTINCT " <>
          quoted <>
          " FROM " <>
          Sql.quote_identifier(schema) <>
          "." <> Sql.quote_identifier(table) <> " WHERE " <> quoted <> " IS NOT NULL",
        []
      )

    validate_scopes!(resource, Enum.map(rows, &List.first/1))
  rescue
    e in AshReplicant.Error -> reraise e, __STACKTRACE__
    # A catalog or connection fault leaves the scope list UNKNOWN, and an
    # unknown scope list is not an empty one. Raised from a helper OUTSIDE the
    # rescue body: this CONVERTS an arbitrary fault into a new value-free
    # structural error, it is not a lost-stacktrace re-raise of the original.
    _e -> raise_scope_incomplete(resource)
  end

  defp declared_scopes!(config, resource) do
    case Info.replicant_snapshot_tenant_scope_action(resource) do
      {:ok, action} when is_atom(action) and not is_nil(action) ->
        run_scope_action!(config, resource, action)

      _absent ->
        raise_scope_incomplete(resource)
    end
  end

  defp run_scope_action!(config, resource, action) do
    result =
      resource
      |> Ash.ActionInput.for_action(action, %{}, context: Context.action_context(config))
      |> Ash.run_action(authorize?: config.authorize?)

    case result do
      {:ok, scopes} when is_list(scopes) -> validate_scopes!(resource, scopes)
      _other -> raise_scope_incomplete(resource)
    end
  rescue
    e in AshReplicant.Error -> reraise e, __STACKTRACE__
    # Same conversion as above: a raising host enumerator says nothing about
    # which scopes are retained, so completion must not proceed on a guess.
    _e -> raise_scope_incomplete(resource)
  end

  # A blank or nil scope is the fail-open shape Ash treats as "no tenant": one
  # of those in the list would run a TENANT-BLIND retirement over every tenant's
  # rows. Reject the whole enumeration rather than filter it — a list carrying a
  # bad entry is evidence the enumerator is wrong, not that one scope is absent.
  defp validate_scopes!(resource, scopes) do
    if Enum.all?(scopes, &present?/1) do
      Enum.uniq(scopes)
    else
      raise_scope_incomplete(resource)
    end
  end

  defp present?(nil), do: false
  defp present?(false), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  # --- the retirement write ---

  defp retire_scope!(config, resource, tenant, attempt, snapshot_lsn, ordinal) do
    action = Info.replicant_snapshot_retire_action!(resource)
    Context.preflight_onetime!(config, tenant, resource, action, :snapshot_retire)
    Context.verify_notifier_loads!(config, resource, action, :snapshot_retire)

    # The retirement sweep has no source change of its own, so it mints the
    # operation identity from the completion point plus a scan-stable ordinal.
    change = %{commit_lsn: snapshot_lsn, ordinal: ordinal}
    context = Context.action_context(config, change, :retire_unseen)

    query =
      resource
      |> unseen_query(attempt)
      |> Ash.Query.set_context(context)

    if Info.history_scd2?(resource) do
      Ash.bulk_update!(query, action, Scd2.close_input(resource, snapshot_lsn, nil),
        strategy: [:atomic, :stream],
        transaction: false,
        tenant: tenant,
        authorize?: config.authorize?,
        context: context,
        return_notifications?: true,
        return_errors?: true
      )
    else
      Ash.bulk_destroy!(query, action, %{},
        strategy: [:atomic, :stream],
        transaction: false,
        tenant: tenant,
        authorize?: config.authorize?,
        context: context,
        return_errors?: true
      )
    end

    :ok
  rescue
    e in AshReplicant.Error -> reraise e, __STACKTRACE__
    e -> reraise Error.scrub(e, resource, :snapshot_retire), __STACKTRACE__
  end

  # `marker != attempt` alone is NULL for a never-marked row, and SQL drops a
  # NULL predicate from the match — so an unmanaged row inserted outside any
  # attempt would survive every completion forever. The explicit `is_nil/1` arm
  # is what makes the retirement total within the managed scope.
  defp unseen_query(resource, attempt) do
    base =
      Ash.Query.filter(
        resource,
        is_nil(^Ash.Expr.ref(@attempt_attribute)) or
          ^Ash.Expr.ref(@attempt_attribute) != ^attempt
      )

    if Info.history_scd2?(resource) do
      to_lsn = Info.replicant_history_valid_to_lsn_attribute!(resource)
      Ash.Query.filter(base, is_nil(^Ash.Expr.ref(to_lsn)))
    else
      base
    end
  end

  defp column_name(resource, attribute) do
    case Ash.Resource.Info.attribute(resource, attribute) do
      %{source: source} when not is_nil(source) -> to_string(source)
      %{name: name} -> to_string(name)
      _other -> to_string(attribute)
    end
  end

  defp raise_scope_incomplete(resource) do
    raise Error.exception(
            reason: :snapshot_scope_incomplete,
            resource: resource,
            op: :snapshot_complete
          )
  end
end
