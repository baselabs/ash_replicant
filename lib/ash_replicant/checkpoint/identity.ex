defmodule AshReplicant.Checkpoint.Identity do
  @moduledoc false
  # The canonical publication/resolver contract: what THIS adapter maps, as
  # value-free structure (names, modules, type terms — never row data), plus the
  # set-monotone transition classifier applied to it at every bind under the
  # checkpoint lock (roadmap B2).
  #
  # Compatible growth = NEW entries only (a relation, a brand-new column,
  # an ignore). Any mutation or removal of a RECORDED entry — a re-target, a
  # type change, a tenant-source change, reversing a recorded skip — is the
  # governing design's "mapping-incompatible" halt class. Both sides of the
  # line are mechanically detectable because the declared skip set is recorded.

  alias AshReplicant.Resource.Info
  alias AshReplicant.Resolver

  @contract_version 1

  @type manifest :: %{
          required(:contract_version) => pos_integer(),
          required(:publication) => [String.t()],
          required(:relations) => [relation()],
          required(:ignores) => [term()]
        }

  @type relation :: %{
          required(:schema) => String.t(),
          required(:table) => String.t(),
          required(:resource) => module(),
          required(:columns) => [column()],
          required(:skips) => [String.t()],
          required(:types) => %{optional(atom()) => term()},
          required(:tenant) => tenant_source() | nil
        }

  @type column :: %{
          required(:source) => String.t(),
          required(:target) => atom(),
          required(:sensitive) => boolean()
        }

  @type tenant_source :: %{kind: :attribute, source: String.t()} | %{kind: :mfa, module: module()}

  @doc """
  Build the canonical contract from the admitted sink config and the normalized
  publication list. Deterministic: relations sorted by `{schema, table}`,
  columns sorted by source name, skips sorted, publication sorted. Value-free
  by construction (schema/table/column names, module atoms, type terms).
  """
  @spec canonical_contract(map(), [String.t()]) :: {:ok, manifest()} | {:error, term()}
  def canonical_contract(%{domains: domains} = _sink_config, publication)
      when is_list(domains) and is_list(publication) do
    with {:ok, index} <- Resolver.build_index(domains) do
      relations =
        index
        |> Enum.map(fn {{schema, table}, resource} -> relation(schema, table, resource) end)
        |> Enum.sort_by(&{&1.schema, &1.table})

      {:ok,
       %{
         contract_version: @contract_version,
         publication: Enum.sort(publication),
         relations: relations,
         ignores: []
       }}
    end
  end

  @doc "Deterministic encoding of a manifest for durable storage."
  @spec encode(manifest()) :: binary()
  def encode(manifest), do: :erlang.term_to_binary(manifest, [:deterministic])

  @doc "Decode a stored contract term (unknown/garbage decodes as `:error`)."
  @spec decode(binary()) :: {:ok, manifest()} | :error
  def decode(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary) do
      %{contract_version: v, publication: _, relations: _, ignores: _} = manifest
      when is_integer(v) ->
        {:ok, manifest}

      _other ->
        :error
    end
  rescue
    _ -> :error
  end

  def decode(_), do: :error

  @doc "sha256 over exactly the stored bytes (digest == manifest checkable without decoding)."
  @spec fingerprint(binary()) :: binary()
  def fingerprint(encoded), do: :crypto.hash(:sha256, encoded)

  @doc """
  Classify a stored manifest against the current one.

  - `nil` stored (adopted row, first bind) → `{:compatible, :initialized}`.
  - `:equal` — identical contracts.
  - `{:compatible, kind}` — set-monotone growth: new relations, brand-new
    columns, skip additions (columns → skips), ignore additions.
  - `{:incompatible, reason}` — anything else: version, publication, relation
    removal/retargeting, column removal/re-targeting/type change/sensitivity
    flip, skip reactivation, tenant-source change.
  """
  @spec classify(manifest() | nil, manifest()) ::
          :equal | {:compatible, atom()} | {:incompatible, atom()}
  def classify(nil, _current), do: {:compatible, :initialized}

  def classify(stored, current) do
    cond do
      stored == current ->
        :equal

      stored.contract_version != current.contract_version ->
        {:incompatible, :version}

      stored.publication != current.publication ->
        {:incompatible, :publication}

      not set_growth?(stored.ignores, current.ignores) ->
        {:incompatible, :ignores}

      true ->
        classify_relations(stored.relations, current.relations)
    end
  end

  defp classify_relations(stored, current) do
    stored_by_key = index_relations(stored)
    current_by_key = index_relations(current)

    stored_keys = stored_by_key |> Map.keys() |> MapSet.new()
    current_keys = current_by_key |> Map.keys() |> MapSet.new()

    removed = MapSet.difference(stored_keys, current_keys)

    cond do
      MapSet.size(removed) > 0 ->
        {:incompatible, :relation_removed}

      true ->
        stored_keys
        |> Enum.sort()
        |> Enum.reduce_while({:compatible, :relations_added}, fn key, growth ->
          case classify_relation(stored_by_key[key], current_by_key[key]) do
            :equal -> {:cont, growth}
            :relation_growth -> {:cont, growth}
            {:incompatible, reason} -> {:halt, {:incompatible, reason}}
          end
        end)
    end
  end

  defp classify_relation(stored, current) do
    with :ok <- check_same(:resource, stored.resource, current.resource, :relation_retargeted),
         :ok <- check_same(:tenant, stored.tenant, current.tenant, :tenant_source) do
      classify_columns(stored, current)
    end
  end

  defp classify_columns(stored, current) do
    stored_cols = index_columns(stored.columns)
    current_cols = index_columns(current.columns)
    stored_skips = MapSet.new(stored.skips)
    current_skips = MapSet.new(current.skips)

    stored_sources = stored_cols |> Map.keys() |> MapSet.new()
    current_sources = current_cols |> Map.keys() |> MapSet.new()

    removed =
      MapSet.difference(stored_sources, current_sources)
      |> MapSet.difference(current_skips)

    cond do
      # A recorded column vanished outright (not moved to skips) — the mirror
      # silently stops carrying it while the watermark advances.
      MapSet.size(removed) > 0 ->
        {:incompatible, :column_removed}

      # A recorded skip was reversed — data starts flowing for a column the
      # stored contract records as an explicit prior decision NOT to mirror.
      MapSet.size(MapSet.difference(stored_skips, current_skips)) > 0 ->
        {:incompatible, :skip_reactivated}

      true ->
        # Every SURVIVING column (still mapped in both) must be identical
        # (target, sensitivity, type); mutation of a RECORDED entry halts.
        # Columns that moved columns -> skips left `columns` and `types`
        # together — that is the compatible ignore addition above.
        survivors = MapSet.intersection(stored_sources, current_sources)

        survivors
        |> Enum.sort()
        |> Enum.reduce_while(:relation_growth, fn source, growth ->
          column = Map.get(stored_cols, source)
          current_column = Map.get(current_cols, source)

          cond do
            current_column != column ->
              {:halt, {:incompatible, :column_changed}}

            Map.get(stored.types, column.target) != Map.get(current.types, current_column.target) ->
              {:halt, {:incompatible, :column_type}}

            true ->
              {:cont, growth}
          end
        end)
    end
  end

  defp check_same(_field, same, same, _reason), do: :ok
  defp check_same(_field, _stored, _current, reason), do: {:incompatible, reason}

  # --- construction ---

  defp relation(schema, table, resource) do
    {skip, cloak, attrs} = Resolver.upsert_reflection(resource)

    # AshCloak replaces the plaintext attribute with `encrypted_<name>`; the
    # SOURCE column keeps the plaintext name. Map back so the contract records
    # the real source column ("pan"), not the generated attribute name.
    cloak_targets = Map.new(cloak, &{String.to_atom("encrypted_#{&1}"), &1})

    columns =
      attrs
      |> MapSet.to_list()
      |> Kernel.--(skip)
      |> Enum.map(fn attr ->
        case Map.get(cloak_targets, attr) do
          plain when not is_nil(plain) ->
            %{source: Atom.to_string(plain), target: attr, sensitive: true}

          _ ->
            %{source: Atom.to_string(attr), target: attr, sensitive: false}
        end
      end)
      |> Enum.sort_by(& &1.source)

    %{
      schema: schema,
      table: table,
      resource: resource,
      columns: columns,
      skips: skip |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      types: types(resource, columns),
      tenant: tenant_source(resource)
    }
  end

  defp types(resource, columns) do
    columns
    |> Map.new(fn %{target: target} ->
      case Ash.Resource.Info.attribute(resource, target) do
        %{type: type} -> {target, type}
        nil -> {target, :unknown}
      end
    end)
  end

  defp tenant_source(resource) do
    case Info.replicant_tenant_attribute(resource) do
      {:ok, attr} ->
        %{kind: :attribute, source: Atom.to_string(attr)}

      _ ->
        case Info.replicant_tenant_mfa(resource) do
          {:ok, {module, _fun, _args}} -> %{kind: :mfa, module: module}
          _ -> nil
        end
    end
  end

  defp index_relations(relations), do: Map.new(relations, &{{&1.schema, &1.table}, &1})

  defp index_columns(columns), do: Map.new(columns, &{&1.source, &1})

  # Pure set growth: every stored element survives; new elements may appear.
  defp set_growth?(stored, current) do
    MapSet.subset?(MapSet.new(stored), MapSet.new(current))
  end
end
