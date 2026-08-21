defmodule AshReplicant.Checkpoint.Identity do
  @moduledoc """
  The canonical publication/resolver contract: what THIS adapter maps, as
  value-free structure (names, modules, type terms — never row data), plus the
  set-monotone transition classifier applied to it at every bind under the
  checkpoint lock (roadmap B2).

  Compatible growth = NEW entries only (a relation, a brand-new column,
  an ignore). Any mutation or removal of a RECORDED entry — a re-target, a
  type change, a tenant-source change, reversing a recorded skip — is the
  governing design's "mapping-incompatible" halt class. Both sides of the
  line are mechanically detectable because the declared skip set is recorded.
  """

  alias AshReplicant.{Error, Resolver, Resource.Info}
  alias AshReplicant.Sql

  @contract_version 1
  @checkpoint_table "ash_replicant_checkpoints"

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

  @typedoc "The admission-threaded contract bundle: the manifest, its durable encoding, and the digest."
  @type contract :: %{manifest: manifest(), encoded: binary(), fingerprint: binary()}

  @doc """
  Build the admission-threaded contract bundle (manifest + deterministic
  encoding + sha256 fingerprint) for a sink config and publication list.
  """
  @spec build_contract(map(), [String.t()]) :: {:ok, contract()} | {:error, term()}
  def build_contract(sink_config, publication) do
    with {:ok, manifest} <- canonical_contract(sink_config, publication) do
      encoded = encode(manifest)
      {:ok, %{manifest: manifest, encoded: encoded, fingerprint: fingerprint(encoded)}}
    end
  end

  @doc """
  Build the canonical contract from the admitted sink config and the normalized
  publication list. Deterministic: relations sorted by `{schema, table}`,
  columns sorted by source name, skips sorted, publication sorted. Value-free
  by construction (schema/table/column names, module atoms, type terms).
  """
  @spec canonical_contract(map(), [String.t()]) :: {:ok, manifest()} | {:error, term()}
  def canonical_contract(%{domains: domains} = sink_config, publication)
      when is_list(domains) and is_list(publication) do
    with {:ok, index} <- Resolver.build_index(domains) do
      relations =
        index
        |> Enum.map(fn {{schema, table}, resource} -> relation(schema, table, resource) end)
        |> Enum.sort_by(&{&1.schema, &1.table})

      # B3: the explicit table ignores land in the reserved field — compatible
      # growth through the unchanged set-monotone classifier.
      ignores =
        sink_config
        |> Map.get(:ignored_sources, [])
        |> Enum.map(fn qualified ->
          [schema, table] = String.split(qualified, ".", parts: 2)
          %{schema: schema, table: table}
        end)
        |> Enum.sort_by(&{&1.schema, &1.table})

      {:ok,
       %{
         contract_version: @contract_version,
         publication: Enum.sort(publication),
         relations: relations,
         ignores: ignores
       }}
    end
  end

  @doc "Deterministic encoding of a manifest for durable storage."
  @spec encode(manifest()) :: binary()
  def encode(manifest), do: :erlang.term_to_binary(manifest, [:deterministic])

  @doc "Decode a stored contract term (unknown/garbage decodes as `:error`)."
  @spec decode(binary()) :: {:ok, manifest()} | :error
  def decode(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
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

  @doc false
  @spec classify_source_binding(map(), map()) ::
          :equal | {:incompatible, :source_identity_rebound}
  def classify_source_binding(row, expected) when is_map(row) and is_map(expected) do
    if Map.get(row, :source_system_id) == Map.get(expected, :source_system_id) and
         Map.get(row, :source_database) == Map.get(expected, :source_database) and
         Map.get(row, :slot_name) == Map.get(expected, :slot_name) do
      :equal
    else
      {:incompatible, :source_identity_rebound}
    end
  end

  @doc false
  @spec classify_stored_contract(binary() | nil, binary() | nil, manifest()) ::
          :unbound | :equal | {:compatible, atom()} | {:incompatible, atom()}
  def classify_stored_contract(nil, _stored_fingerprint, _current), do: :unbound

  def classify_stored_contract(stored, stored_fingerprint, current) when is_binary(stored) do
    with true <- is_binary(stored_fingerprint),
         true <- fingerprint(stored) == stored_fingerprint,
         {:ok, stored_manifest} <- decode(stored) do
      classify(stored_manifest, current)
    else
      _other -> {:incompatible, :stored_contract_invalid}
    end
  end

  def classify_stored_contract(_stored, _stored_fingerprint, _current),
    do: {:incompatible, :stored_contract_invalid}

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
    current_relation_keys = MapSet.new(current.relations, &{&1.schema, &1.table})

    # An ignore removed WITHOUT the table becoming a mapped relation is a
    # reversal; an ignore promoted to a mapped relation is coverage growth.
    orphaned_ignores =
      stored.ignores
      |> MapSet.new(&{&1.schema, &1.table})
      |> MapSet.difference(MapSet.new(current.ignores, &{&1.schema, &1.table}))
      |> MapSet.difference(current_relation_keys)

    cond do
      stored == current ->
        :equal

      stored.contract_version != current.contract_version ->
        {:incompatible, :version}

      stored.publication != current.publication ->
        {:incompatible, :publication}

      MapSet.size(orphaned_ignores) > 0 ->
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

    if MapSet.size(removed) > 0 do
      {:incompatible, :relation_removed}
    else
      stored_keys
      |> Enum.sort()
      |> Enum.reduce_while({:compatible, :relations_added}, fn key, growth ->
        relation_growth_step(stored_by_key[key], current_by_key[key], growth)
      end)
    end
  end

  defp relation_growth_step(stored, current, growth) do
    case classify_relation(stored, current) do
      :equal -> {:cont, growth}
      :relation_growth -> {:cont, growth}
      {:incompatible, reason} -> {:halt, {:incompatible, reason}}
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
    current_mapped_names = current_cols |> Map.keys() |> MapSet.new()

    stored_sources = stored_cols |> Map.keys() |> MapSet.new()
    current_sources = current_cols |> Map.keys() |> MapSet.new()

    removed =
      MapSet.difference(stored_sources, current_sources)
      |> MapSet.difference(current_skips)

    # A skip removed WITHOUT the column becoming mapped is a reversal of a
    # recorded decision; a skip promoted to a mapped column is coverage growth.
    orphaned_skips =
      MapSet.difference(stored_skips, current_skips)
      |> MapSet.difference(current_mapped_names)

    cond do
      # A recorded column vanished outright (not moved to skips) — the mirror
      # silently stops carrying it while the watermark advances.
      MapSet.size(removed) > 0 ->
        {:incompatible, :column_removed}

      MapSet.size(orphaned_skips) > 0 ->
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
          survivor_verdict(stored, current, stored_cols, current_cols, source, growth)
        end)
    end
  end

  defp survivor_verdict(stored, current, stored_cols, current_cols, source, growth) do
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
  end

  defp check_same(_field, same, same, _reason), do: :ok
  defp check_same(_field, _stored, _current, reason), do: {:incompatible, reason}

  @doc """
  Count the rows a LEGACY (slot-only) checkpoint table still carries, or `0`
  when the table already has the source-bound shape (nothing ambiguous can
  remain). Callable from a host data migration / iex BEFORE migrating, while
  the table still lacks `source_system_id`. The only raw SQL in the library:
  a fixed-table-name, parameterless information-schema probe + count — never
  a row value.
  """
  @spec legacy_checkpoint_row_count(module(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :checkpoint_probe_failed}
  def legacy_checkpoint_row_count(repo, table \\ @checkpoint_table) when is_atom(repo) do
    case repo.query(
           "SELECT count(*) FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = 'source_system_id'",
           [table]
         ) do
      # Migrated shape: nothing ambiguous can remain.
      {:ok, %{rows: [[present]]}} when present > 0 ->
        {:ok, 0}

      # Legacy (slot-only) shape: count the rows that block the migration.
      {:ok, %{rows: [[0]]}} ->
        case repo.query("SELECT count(*) FROM " <> Sql.quote_identifier(table), []) do
          {:ok, %{rows: [[count]]}} -> {:ok, count}
          # A count failure must not read as "nothing ambiguous" — surface it.
          _ -> {:error, :checkpoint_probe_failed}
        end

      _ ->
        {:error, :checkpoint_probe_failed}
    end
  end

  @doc """
  Raise a value-free structural error when a legacy (slot-only) checkpoint
  table still carries rows — the operator must capture and delete them (or
  adopt after migrating) before `ecto.migrate` can run: the structural
  migration itself aborts on surviving NOT NULL-less legacy rows. The error
  carries ONLY the row count and the two operator options. A failed probe
  (table unreadable) raises a distinct structural config error rather than
  reading as "nothing ambiguous".
  """
  @spec refuse_ambiguous_legacy_rows!(module(), String.t()) :: :ok
  def refuse_ambiguous_legacy_rows!(repo, table \\ @checkpoint_table) when is_atom(repo) do
    case legacy_checkpoint_row_count(repo, table) do
      {:ok, 0} ->
        :ok

      {:error, reason} ->
        raise Error.exception(
                reason: :config_invalid,
                resource: nil,
                op: :migrate,
                shape: "probe=#{inspect(reason)}"
              )

      {:ok, count} ->
        raise Error.exception(
                reason: :checkpoint_legacy_rows_present,
                resource: nil,
                op: :migrate,
                shape: "rows=#{count} options=capture_and_delete_then_adopt|reset"
              )
    end
  end

  # --- construction ---

  defp relation(schema, table, resource) do
    {skip, cloak, attrs} = Resolver.upsert_reflection(resource)

    # AshCloak replaces the plaintext attribute with `encrypted_<name>`; the
    # SOURCE column keeps the plaintext name. Map back so the contract records
    # the real source column ("pan"), not the generated attribute name.
    # The encrypted_<name> attribute exists by AshCloak's compile-time
    # transformer; to_existing_atom never mints host-controlled atoms.
    cloak_targets =
      cloak
      |> Enum.map(&{encrypted_atom("encrypted_#{&1}"), &1})
      |> Enum.reject(&is_nil(elem(&1, 0)))
      |> Map.new()

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

  defp encrypted_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp index_relations(relations), do: Map.new(relations, &{{&1.schema, &1.table}, &1})

  defp index_columns(columns), do: Map.new(columns, &{&1.source, &1})
end
