defmodule AshReplicant.Resolver do
  @moduledoc """
  Runtime resolution for the AshReplicant sink — the tenant/classification layer
  that keeps `replicant` tenant-blind. Pure functions over compiled resource
  metadata (no DB access):

    * `build_index/1` — reflect the configured domains into a
      `{source_schema, source_table} => resource` index, failing closed on a
      duplicate source key (ambiguous route).
    * `resolve_tenant/2` — per-row tenant from `tenant_attribute` / `tenant_mfa`,
      failing closed with `:tenant_required` on a nil/blank tenant.
    * `writable_target/2` / `attrs_for_upsert/2` — map source string columns to
      their real writable targets, routing AshCloak-sensitive columns through the
      cloak argument while naming `encrypted_<col>` in `upsert_fields`.
    * `primary_key/1` / `pk_values/2` / `upsert_identity/1` / `upsert_action/1`.
  """

  alias AshReplicant.Resource.Info

  @type source_key :: {schema :: String.t(), table :: String.t()}

  @spec build_index([module()]) ::
          {:ok, %{source_key() => module()}}
          | {:error, {:duplicate_source, source_key()}}
          | {:error, {:missing_source_table, module()}}
  def build_index(domains) when is_list(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&replicant_resource?/1)
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

  @spec writable_target(module(), String.t()) :: {:ok, atom()} | :skip
  def writable_target(resource, source_col) when is_binary(source_col) do
    skip = Info.replicant_skip!(resource)
    cloak = cloak_attributes(resource)
    attrs = attribute_names(resource)
    col = to_existing_atom(source_col)

    cond do
      is_nil(col) -> :skip
      col in skip -> :skip
      col in cloak -> {:ok, String.to_existing_atom("encrypted_#{source_col}")}
      MapSet.member?(attrs, col) -> {:ok, col}
      true -> :skip
    end
  end

  @spec attrs_for_upsert(module(), map()) :: {map(), [atom()]}
  def attrs_for_upsert(resource, record) when is_map(record) do
    skip = Info.replicant_skip!(resource)
    cloak = cloak_attributes(resource)
    attrs = attribute_names(resource)

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

  @doc "The upsert identity name from the DSL (`nil` → primary-key upsert)."
  @spec upsert_identity(module()) :: atom() | nil
  def upsert_identity(resource), do: opt(Info.replicant_upsert_identity(resource))

  @doc "The upsert-capable create action name (the resource's primary create action)."
  @spec upsert_action(module()) :: atom()
  def upsert_action(resource), do: Ash.Resource.Info.primary_action!(resource, :create).name

  # --- private ---

  defp replicant_resource?(resource) do
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

  defp opt({:ok, value}), do: value
  defp opt(_), do: nil

  defp present_or_required(nil), do: {:error, :tenant_required}

  defp present_or_required(v) when is_binary(v),
    do: if(String.trim(v) == "", do: {:error, :tenant_required}, else: {:ok, v})

  defp present_or_required(v), do: {:ok, v}
end
