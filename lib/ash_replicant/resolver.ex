defmodule AshReplicant.Resolver do
  @moduledoc """
  Runtime resolution for the AshReplicant sink — the tenant/classification layer
  that keeps `replicant` tenant-blind. Pure functions over compiled resource
  metadata (no DB access):

    * `build_index/1` — reflect the configured domains into a
      `{source_schema, source_table} => resource` index, failing closed on a
      duplicate source key (ambiguous route).
    * `resolve_tenant/2` — per-row tenant from `tenant_attribute` / `tenant_mfa`,
      failing closed with `:tenant_required` on a nil/`false`/blank tenant (any value Ash would
      treat as unscoped); `resolve_tenant!/3` is the raising variant every apply path shares.
    * `attrs_for_upsert/2` — map source string columns to
      their real writable targets, routing AshCloak-sensitive columns through the
      cloak argument while naming `encrypted_<col>` in `upsert_fields`. The bulk
      snapshot path computes `upsert_reflection/1` once and maps each row via
      `upsert_input/2` (the batch-invariant hoist).
    * `primary_key/1` / `pk_values/2` / `upsert_identity/1` / `upsert_action/1` /
      `destroy_action/1`.
  """

  alias AshReplicant.Error
  alias AshReplicant.Resource.Info

  @type source_key :: {schema :: String.t(), table :: String.t()}

  @spec build_index([module()]) ::
          {:ok, %{source_key() => module()}}
          | {:error, {:duplicate_source, source_key()}}
          | {:error, {:missing_source_table, module()}}
  def build_index(domains) when is_list(domains) do
    domains
    |> resources()
    |> Enum.reduce_while({:ok, %{}}, fn resource, {:ok, acc} ->
      key = {Info.source_schema(resource), Info.source_table(resource)}

      cond do
        is_nil(elem(key, 1)) ->
          {:halt, {:error, {:missing_source_table, resource}}}

        Map.has_key?(acc, key) ->
          {:halt, {:error, {:duplicate_source, key}}}

        true ->
          {:cont, {:ok, Map.put(acc, key, resource)}}
      end
    end)
  end

  @doc false
  @spec domain_resources([module()]) :: [module()]
  def domain_resources(domains) when is_list(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp resources(domains) when is_list(domains) do
    domains
    |> domain_resources()
    |> Enum.filter(&replicant_resource?/1)
  end

  @doc """
  Look up the mirror resource for a source `{schema, table}` in an index built by
  `build_index/1`, applying the SAME `nil`-schema → `"public"` default the index
  keys use (so the convention lives in one place next to the builder). Returns the
  resource, or `nil` for an unmapped table.
  """
  @spec lookup(%{source_key() => module()}, String.t() | nil, String.t()) :: module() | nil
  def lookup(index, schema, table), do: Map.get(index, {schema || "public", table})

  @spec resolve_tenant(module(), map()) :: {:ok, term()} | {:error, :tenant_required}
  def resolve_tenant(resource, record) when is_map(record) do
    attr = opt(Info.replicant_tenant_attribute(resource))
    mfa = opt(Info.replicant_tenant_mfa(resource))

    cond do
      not is_nil(attr) ->
        record |> Map.get(to_string(attr)) |> present_or_required()

      not is_nil(mfa) ->
        (fn {m, f, a} -> apply(m, f, [record | a]) end).(mfa) |> present_or_required()

      true ->
        {:ok, nil}
    end
  end

  @doc """
  The fail-closed bang variant of `resolve_tenant/2`: returns the per-row tenant, or raises a
  value-free `AshReplicant.Error` (`reason: :tenant_required`) when the row carries no usable
  tenant. `op` labels the failing sink operation (`:upsert` / `:destroy` / ...) in the
  structural error. The single tenant-resolution entry point shared by every apply path
  (`Apply`, `Apply.Scd2`), so `:tenant_required` fails identically everywhere.
  """
  @spec resolve_tenant!(module(), map(), atom()) :: term()
  def resolve_tenant!(resource, record, op) do
    case resolve_tenant(resource, record) do
      {:ok, tenant} ->
        tenant

      {:error, :tenant_required} ->
        raise Error.exception(reason: :tenant_required, resource: resource, op: op)
    end
  end

  @doc """
  The B4 tri-modal tenant transition (roadmap B4): resolve BOTH sides up
  front and classify — `{:ok, :same | :reassigned, old, new}` or an
  `{:error, ...}` for the `:indeterminate` case. The old side is REQUIRED
  on update/delete paths (RIF guarantees old_record carries the tenant
  discriminator); an absent/blank/`false` old tenant halts
  `:tenant_required` (shape "side=old") and a RAISING resolver halts
  `:tenant_resolution_failed` — BEFORE any write. A non-tenant-scoped
  resource always resolves `{:ok, :same, nil, nil}`.
  """
  @spec require_tenant_pair!(module(), map(), atom()) ::
          {:ok, :same | :reassigned, term(), term()}
  def require_tenant_pair!(resource, %{record: record, old_record: old}, op)
      when is_map(record) and is_map(old) do
    with {:ok, new_tenant} <- resolve_side(resource, record, :new, op),
         {:ok, old_tenant} <- resolve_side(resource, old, :old, op) do
      # resolve_tenant has already rejected nil/false/blank sides, so both
      # values are present by construction here.
      if old_tenant != new_tenant do
        {:ok, :reassigned, old_tenant, new_tenant}
      else
        {:ok, :same, old_tenant, new_tenant}
      end
    end
  end

  # Insert-shaped (see above).
  # Insert-shaped changes (and snapshot batches, which carry no old side).
  def require_tenant_pair!(resource, %{record: record}, op)
      when is_map(record) and op in [:insert, :snapshot, :create] do
    with {:ok, new_tenant} <- resolve_side(resource, record, :new, op) do
      {:ok, :same, nil, new_tenant}
    end
  end

  # An update/delete whose :old_record is MISSING ENTIRELY (nil — the
  # DEFAULT-replica-identity pgoutput shape: no old tuple is sent when no key
  # column changed) is the silently-ambiguous case B4 halts — but ONLY for a
  # TENANT-SCOPED resource (nothing to reassign otherwise; the non-tenant
  # fixture paths legitimately omit the old side in unit tests).
  def require_tenant_pair!(resource, %{record: record}, op) when is_map(record) do
    if tenant_scoped?(resource) do
      raise Error.exception(
              reason: :tenant_required,
              resource: resource,
              op: op,
              shape: "side=old"
            )
    else
      with {:ok, new_tenant} <- resolve_side(resource, record, :new, op) do
        {:ok, :same, nil, new_tenant}
      end
    end
  end

  defp tenant_scoped?(resource) do
    match?({:ok, _}, Info.replicant_tenant_attribute(resource)) or
      match?({:ok, _}, Info.replicant_tenant_mfa(resource))
  end

  defp resolve_side(resource, row, side, op) do
    case resolve_tenant(resource, row) do
      {:ok, tenant} ->
        {:ok, tenant}

      {:error, :tenant_required} ->
        raise Error.exception(
                reason: :tenant_required,
                resource: resource,
                op: op,
                shape: "side=#{side}"
              )
    end
  rescue
    e in AshReplicant.Error ->
      reraise e, __STACKTRACE__

    # A RAISING tenant_mfa on either side: value-free structural halt, never
    # an unscrubbed row value (the pre-B4 CAVEAT class — deleted). Raised in
    # a helper OUTSIDE the rescue body — this is a CONVERSION of an arbitrary
    # fault into a new structural error, not a lost-stacktrace re-raise.
    other ->
      tenant_resolution_failed(other, resource, side, op)
  end

  defp tenant_resolution_failed(_fault, resource, side, op) do
    raise Error.exception(
            reason: :tenant_resolution_failed,
            resource: resource,
            op: op,
            shape: "side=#{side}"
          )
  end

  @typedoc "The batch-invariant upsert reflection: `{skip, cloak_attrs, attribute_names}`."
  @type upsert_reflection :: {[atom()], [atom()], MapSet.t(atom())}

  @doc """
  Compute the batch-invariant upsert reflection for a resource ONCE — the `skip`
  list, the AshCloak cloak attributes, and the attribute-name set. Thread it into
  `upsert_input/2` per row of a column-homogeneous batch (the snapshot bulk path)
  to avoid re-deriving these for every row. Single-record callers use
  `attrs_for_upsert/2`, which computes the reflection inline.
  """
  @spec upsert_reflection(module()) :: upsert_reflection()
  def upsert_reflection(resource) do
    {Info.replicant_skip!(resource), cloak_attributes(resource), attribute_names(resource)}
  end

  @spec attrs_for_upsert(module(), map()) :: {map(), [atom()]}
  def attrs_for_upsert(resource, record) when is_atom(resource) and is_map(record) do
    upsert_input(upsert_reflection(resource), record)
  end

  @doc """
  Map one source `record` to `{inputs, upsert_fields}` under a precomputed
  `upsert_reflection/1`. AshCloak-sensitive columns pass plaintext under the cloak
  argument while `upsert_fields` names `encrypted_<col>`.
  """
  @spec upsert_input(upsert_reflection(), map()) :: {map(), [atom()]}
  def upsert_input({skip, cloak, attrs}, record) when is_map(record) do
    {inputs, fields} =
      Enum.reduce(record, {%{}, []}, fn {col, value}, {inputs, fields} ->
        atom = to_existing_atom(col)

        cond do
          is_nil(atom) or atom in skip ->
            {inputs, fields}

          atom in cloak ->
            {Map.put(inputs, atom, value), [String.to_existing_atom("encrypted_#{col}") | fields]}

          MapSet.member?(attrs, atom) ->
            {Map.put(inputs, atom, value), [atom | fields]}

          true ->
            {inputs, fields}
        end
      end)

    {inputs, fields |> Enum.reverse() |> Enum.uniq()}
  end

  @spec primary_key(module()) :: [atom()]
  def primary_key(resource), do: Ash.Resource.Info.primary_key(resource)

  @spec pk_values(module(), map()) :: map()
  def pk_values(resource, record) when is_map(record) do
    resource |> primary_key() |> Map.new(fn k -> {k, Map.get(record, to_string(k))} end)
  end

  @doc "The declared SCD2 business-key values from a string-keyed source `record`."
  @spec business_key_values(module(), map()) :: map()
  def business_key_values(resource, record) when is_map(record) do
    resource
    |> Info.replicant_history_business_key!()
    |> Map.new(fn k -> {k, Map.get(record, to_string(k))} end)
  end

  @doc """
  A query over `resource` selecting the CURRENT open version of the business key in
  `record`, whose `valid_from_lsn` is strictly less than `lsn` (open-path close) or at
  most `lsn` (delete/terminal close, `inclusive?: true`). Uses dynamic `^ref/1` because
  the window column names are DSL-configured.
  """
  @spec open_version_query(module(), map(), integer(), keyword()) :: Ash.Query.t()
  def open_version_query(resource, record, lsn, opts \\ []) do
    require Ash.Query

    from_col = Info.replicant_history_valid_from_lsn_attribute!(resource)
    to_col = Info.replicant_history_valid_to_lsn_attribute!(resource)
    bk = business_key_values(resource, record)
    inclusive? = Keyword.get(opts, :inclusive?, false)

    base = Ash.Query.do_filter(resource, bk)

    if inclusive? do
      Ash.Query.filter(base, is_nil(^Ash.Expr.ref(to_col)) and ^Ash.Expr.ref(from_col) <= ^lsn)
    else
      Ash.Query.filter(base, is_nil(^Ash.Expr.ref(to_col)) and ^Ash.Expr.ref(from_col) < ^lsn)
    end
  end

  @doc """
  The `{inputs, upsert_fields}` for OPENING a version: the source data columns (via the
  existing upsert reflection) PLUS the window columns (`valid_from_lsn`, optional
  `valid_from_ts`, `valid_to_lsn: nil`, optional `is_current: true`). `upsert_fields`
  names every window column so a same-`lsn` re-open coalesces in place.
  """
  @spec version_open_input(module(), map(), map()) :: {map(), [atom()]}
  def version_open_input(resource, record, window) do
    {inputs, fields} = attrs_for_upsert(resource, record)

    from_lsn = Info.replicant_history_valid_from_lsn_attribute!(resource)
    to_lsn = Info.replicant_history_valid_to_lsn_attribute!(resource)
    from_ts = opt(Info.replicant_history_valid_from_timestamp_attribute(resource))
    current = opt(Info.replicant_history_current_attribute(resource))

    window_cols =
      [{from_lsn, window[:lsn]}, {to_lsn, nil}]
      |> maybe_put(from_ts, window[:ts])
      |> maybe_put(current, true)

    merged_inputs = Enum.reduce(window_cols, inputs, fn {k, v}, acc -> Map.put(acc, k, v) end)
    merged_fields = Enum.uniq(fields ++ Enum.map(window_cols, &elem(&1, 0)))
    {merged_inputs, merged_fields}
  end

  @doc "The upsert identity name from the DSL (`nil` → primary-key upsert)."
  @spec upsert_identity(module()) :: atom() | nil
  def upsert_identity(resource), do: opt(Info.replicant_upsert_identity(resource))

  @doc "The upsert-capable create action name (the resource's primary create action)."
  @spec upsert_action(module()) :: atom()
  def upsert_action(resource), do: Ash.Resource.Info.primary_action!(resource, :create).name

  @doc "The primary destroy action name (mirrors `upsert_action/1` for `:create`)."
  @spec destroy_action(module()) :: atom()
  def destroy_action(resource), do: Ash.Resource.Info.primary_action!(resource, :destroy).name

  # --- private ---

  defp replicant_resource?(resource) do
    # SKIPS a module whose reflection raises: the index tolerates it. The
    # destination manifest intentionally FAILS on the same module
    # (`:reflection_failed`) — activation must never silently drop a declared
    # resource. Defensive depth both ways: Ash.Domain's compile-time Spark
    # verification rejects a non-DSL module loudly, so neither stance is
    # reachable through a well-formed domain — the enumeration-set pin in
    # destination_test.exs covers the reachable drift class.
    AshReplicant.Resource in Spark.extensions(resource)
  rescue
    _ -> false
  end

  defp cloak_attributes(resource) do
    if AshCloak in Spark.extensions(resource),
      do: AshCloak.Info.cloak_attributes!(resource),
      else: []
  end

  defp attribute_names(resource) do
    resource |> Ash.Resource.Info.attributes() |> MapSet.new(& &1.name)
  end

  defp to_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp maybe_put(list, nil, _value), do: list
  defp maybe_put(list, key, value), do: [{key, value} | list]

  defp opt({:ok, value}), do: value
  defp opt(_), do: nil

  defp present_or_required(nil), do: {:error, :tenant_required}

  # `false` is the only other Elixir falsy value. Ash treats a falsy tenant as NO scoping —
  # `handle_attribute_multitenancy` guards `if changeset.tenant` and `validate_changeset_multitenancy`
  # keys on `is_nil(changeset.tenant)` — so a `false` tenant is neither force-set nor rejected and
  # the mirror write lands UNSCOPED. Fail closed, exactly like `nil`.
  defp present_or_required(false), do: {:error, :tenant_required}

  defp present_or_required(v) when is_binary(v),
    do: if(String.trim(v) == "", do: {:error, :tenant_required}, else: {:ok, v})

  defp present_or_required(v), do: {:ok, v}
end
