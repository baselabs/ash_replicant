defmodule AshReplicant.Coverage do
  @moduledoc false
  # Strict source coverage (roadmap B3) + the RIF half of B4: one rule
  # evaluation over a source-catalog census, the activation preflight that
  # gathers it on an identity-verified short-lived connection, and the
  # per-change/per-record column accounting guards. Everything here reads
  # CATALOGS only — no row data crosses, publication names bind `$1`, and
  # every error is a value-free structural reason (Critical Rule 4).

  alias AshReplicant.{Checkpoint.Identity, Error, Resource.Info}
  alias Replicant.Decoder.OidDatabase

  @typedoc "Per-table catalog census: the live column shape + identity flags."
  @type census :: %{
          optional({String.t(), String.t()}) => %{
            required(:columns) => [
              %{required(:name) => String.t(), required(:type) => String.t()}
            ],
            required(:relreplident) => String.t(),
            required(:pk) => [String.t()]
          }
        }

  @typedoc "Per-relation declared facts derived from the sink config + manifest."
  @type relation_facts :: %{
          optional({String.t(), String.t()}) => %{
            required(:resource) => module(),
            required(:mapped) => MapSet.t(String.t()),
            required(:skips) => MapSet.t(String.t()),
            required(:target_types) => %{optional(String.t()) => term()},
            required(:tenant?) => boolean(),
            required(:append?) => boolean(),
            required(:scd2?) => boolean(),
            required(:business_key) => [String.t()]
          }
        }

  # The type matrix (design D6): allowed source pg typnames per TARGET Ash
  # type. Arrays via `_`-prefixed unwrapping; unknown/custom target types are
  # NOT judged (the runtime Ash cast stays per-row fail-closed).
  @type_matrix %{
    integer: ~w(int2 int4 int8),
    string: ~w(text varchar bpchar name char),
    atom: ~w(text varchar bpchar name),
    binary: ~w(bytea),
    boolean: ~w(bool),
    float: ~w(float4 float8),
    decimal: ~w(numeric),
    date: ~w(date),
    time: ~w(time timetz),
    time_usec: ~w(time timetz),
    utc_datetime: ~w(timestamptz timestamp),
    utc_datetime_usec: ~w(timestamptz timestamp),
    datetime: ~w(timestamptz timestamp),
    naive_datetime: ~w(timestamp),
    naive_datetime_usec: ~w(timestamp),
    uuid: ~w(uuid),
    map: ~w(json jsonb),
    json_string: ~w(json jsonb),
    struct: ~w(json jsonb),
    tuple: ~w(json jsonb)
  }

  @default_array_prefix "_"

  # --- pure rule evaluation ---

  @doc """
  Evaluate the coverage rules over a catalog census against the declared
  relation facts and the ignored table set. Pure; halt reasons are structural
  (table/column NAMES only — never a row value).

  Rules: missing expected tables (rule 2); unignored publication tables
  (rule 3); ignore∩mapped collision (rule 4b); unmapped columns (rule 5);
  missing declared columns / stale skips (rule 6); invalid source types
  (rule 7); RIF (rule 10).
  """
  @spec evaluate(census(), relation_facts(), [%{schema: String.t(), table: String.t()}]) ::
          :ok | {:error, Error.t()}
  def evaluate(census, facts, ignores) do
    # MapSet.new(map) would enumerate {k, v} PAIRS — build the key set directly.
    ignored_keys = MapSet.new(ignores, &{&1.schema, &1.table})

    with :ok <- check_ignore_collisions(ignored_keys, facts),
         :ok <- check_missing_expected(census, facts),
         :ok <- check_unignored_publication(census, facts, ignored_keys),
         :ok <- check_columns(census, facts),
         :ok <- check_types(census, facts) do
      check_replica_identity(census, facts)
    end
  end

  defp check_ignore_collisions(ignored_keys, facts) do
    case Enum.find(ignored_keys, &Map.has_key?(facts, &1)) do
      nil ->
        :ok

      {schema, table} ->
        {:error,
         Error.exception(
           reason: :config_invalid,
           resource: nil,
           op: :preflight,
           shape: "ignore_collides_with_mapping=#{schema}.#{table}"
         )}
    end
  end

  defp check_missing_expected(census, facts) do
    case Enum.find(facts, fn {key, _} -> not Map.has_key?(census, key) end) do
      nil ->
        :ok

      {{schema, table}, _} ->
        {:error,
         Error.exception(
           reason: :source_table_missing,
           resource: nil,
           op: :preflight,
           shape: "#{schema}.#{table}"
         )}
    end
  end

  defp check_unignored_publication(census, facts, ignored_keys) do
    census
    |> Enum.find(fn {key, _} ->
      not Map.has_key?(facts, key) and not MapSet.member?(ignored_keys, key)
    end)
    |> case do
      nil ->
        :ok

      {{schema, table}, _} ->
        {:error,
         Error.exception(
           reason: :source_table_unmapped,
           resource: nil,
           op: :preflight,
           shape: "#{schema}.#{table}"
         )}
    end
  end

  defp check_columns(census, facts) do
    Enum.find_value(facts, :ok, fn {{schema, table}, fact} ->
      live =
        census |> Map.fetch!({schema, table}) |> Map.get(:columns) |> Map.new(&{&1.name, &1.type})

      live_names = live |> Map.keys() |> MapSet.new()

      missing_declared =
        fact.mapped
        |> MapSet.difference(live_names)
        |> MapSet.to_list()

      stale_skips =
        fact.skips
        |> MapSet.difference(live_names)
        |> MapSet.to_list()

      unmapped =
        live_names
        |> MapSet.difference(fact.mapped)
        |> MapSet.difference(fact.skips)
        |> MapSet.to_list()

      cond do
        missing_declared != [] ->
          {:error,
           Error.exception(
             reason: :source_column_missing,
             resource: fact.resource,
             op: :preflight,
             shape: "#{schema}.#{table}(#{Enum.join(Enum.sort(missing_declared), ",")})"
           )}

        stale_skips != [] ->
          {:error,
           Error.exception(
             reason: :source_skip_stale,
             resource: fact.resource,
             op: :preflight,
             shape: "#{schema}.#{table}(#{Enum.join(Enum.sort(stale_skips), ",")})"
           )}

        unmapped != [] ->
          {:error,
           Error.exception(
             reason: :source_column_unmapped,
             resource: fact.resource,
             op: :preflight,
             shape: "#{schema}.#{table}(#{Enum.join(Enum.sort(unmapped), ",")})"
           )}

        true ->
          :ok
      end
    end)
  end

  defp check_types(census, facts) do
    Enum.find_value(facts, :ok, fn {{schema, table}, fact} ->
      live = census |> Map.fetch!({schema, table}) |> Map.get(:columns)

      # find_value's default :ok fires only when NO column violates; an
      # allowed/skipped column yields nil so the scan continues.
      Enum.find_value(live, :ok, fn column ->
        column_type_error(fact, schema, table, column)
      end)
    end)
  end

  # nil continues the scan (unmapped columns are rule 5's class); a returned
  # error tuple halts it.
  defp column_type_error(fact, schema, table, column) do
    case Map.get(fact.target_types, column.name) do
      nil ->
        nil

      target_type ->
        unless type_allowed?(target_type, column.type) do
          {:error,
           Error.exception(
             reason: :source_type_invalid,
             resource: fact.resource,
             op: :preflight,
             shape: "#{schema}.#{table}(#{column.name}:#{column.type})"
           )}
        end
    end
  end

  @doc """
  Rule 10 (replica identity) evaluated ALONE, over the same census and facts
  `evaluate/3` takes. A missing declared table remains the structural rule-2
  failure because there is no live relation whose identity can be judged.

  `evaluate/3` short-circuits and runs this rule last, so an earlier coverage
  violation hides the replica-identity verdict entirely. The operator diagnosis
  surface (`AshReplicant.Doctor`) must report the two as distinct checks, so it
  reaches the rule through here — the same body, never a second copy that could
  drift from what activation enforces.
  """
  @spec replica_identity_check(census(), relation_facts()) :: :ok | {:error, Error.t()}
  def replica_identity_check(census, facts) do
    with :ok <- check_missing_expected(census, facts) do
      check_replica_identity(census, facts)
    end
  end

  defp check_replica_identity(census, facts) do
    Enum.find_value(facts, :ok, fn {{schema, table}, fact} ->
      live = Map.fetch!(census, {schema, table})

      needs_full? =
        fact.append? or fact.tenant? or
          (fact.scd2? and not business_key_is_pk?(fact, live.pk))

      if needs_full? and live.relreplident != "f" do
        {:error,
         Error.exception(
           reason: :source_replica_identity,
           resource: fact.resource,
           op: :preflight,
           shape: "#{schema}.#{table}=#{live.relreplident}"
         )}
      else
        :ok
      end
    end)
  end

  defp business_key_is_pk?(fact, pk) do
    bk = fact.business_key
    bk != [] and Enum.sort(bk) == Enum.sort(pk)
  end

  @doc """
  True when the live source typname is admissible for the target Ash type.
  Arrays (`_`-prefixed pg names) unwrap to the element rule; unknown/custom
  target types are NOT judged (documented fail-open-for-unknown boundary —
  the runtime Ash cast stays per-row fail-closed).
  """
  @spec type_allowed?(term(), String.t()) :: boolean()
  def type_allowed?(target_type, source_type) do
    base = unwrapped_type(target_type)

    # The contract's types carry Ash's runtime module atoms (e.g. Ash.Type.String
    # for the :string builtin — OBSERVED from relation_facts on the live
    # substrate); normalize to the builtin literal before the matrix lookup.
    base = builtin_type(base)

    cond do
      not is_atom(base) ->
        # Unknown/custom target type: not statically judgable.
        true

      is_nil(Map.get(@type_matrix, base)) ->
        true

      String.starts_with?(source_type, @default_array_prefix) ->
        element = String.trim_leading(source_type, @default_array_prefix)
        Map.get(@type_matrix, base) |> List.wrap() |> Enum.member?(element)

      true ->
        Map.get(@type_matrix, base) |> List.wrap() |> Enum.member?(source_type)
    end
  end

  defp unwrapped_type({:array, inner}), do: unwrapped_type(inner)
  defp unwrapped_type(other), do: other

  # The contract's types carry Ash's runtime module atoms (Ash.Type.String
  # for the :string builtin — OBSERVED live); Ash.Type.storage_type/2
  # normalizes them to the literal the matrix keys on. Unknown/custom types
  # keep their atom and hit the fail-open-for-unknown boundary.
  defp builtin_type({:array, inner}), do: {:array, builtin_type(inner)}

  defp builtin_type(base) when is_atom(base) do
    cond do
      Map.has_key?(@type_matrix, base) ->
        base

      Code.ensure_loaded?(base) and function_exported?(base, :storage_type, 1) ->
        Ash.Type.storage_type(base)

      true ->
        base
    end
  catch
    _, _ -> base
  end

  defp builtin_type(other), do: other

  # --- delivery-side accounting guards ---

  @doc """
  The per-change column accounting (streaming): the change's table must be
  mapped (or explicitly ignored) and every delivered column must be mapped or
  skipped. Halts (raises a value-free Error) BEFORE any write.
  """
  @spec assert_change!(relation_facts(), MapSet.t(), Replicant.Change.t()) :: :ok
  def assert_change!(facts, ignored_tables, %Replicant.Change{} = change) do
    key = {change.schema || "public", change.table}

    cond do
      MapSet.member?(ignored_tables, key) ->
        :ok

      not Map.has_key?(facts, key) ->
        raise Error.exception(
                reason: :source_table_unmapped,
                resource: nil,
                op: :apply,
                shape: "#{elem(key, 0)}.#{elem(key, 1)}"
              )

      true ->
        fact = Map.fetch!(facts, key)

        change.columns
        |> Enum.map(&to_string(&1.name))
        |> Enum.each(&assert_column_mapped!(fact, key, &1, :apply))

        :ok
    end
  end

  @doc """
  The snapshot-side column accounting: snapshot changes carry `columns: []`,
  so the record's keys are the live column set. Same rule, same halt shape.
  """
  @spec assert_record_columns!(relation_facts(), MapSet.t(), String.t() | nil, String.t(), map()) ::
          :ok
  def assert_record_columns!(facts, ignored_tables, schema, table, record)
      when is_map(record) do
    key = {schema || "public", table}

    cond do
      MapSet.member?(ignored_tables, key) ->
        :ok

      not Map.has_key?(facts, key) ->
        raise Error.exception(
                reason: :source_table_unmapped,
                resource: nil,
                op: :snapshot,
                shape: "#{elem(key, 0)}.#{elem(key, 1)}"
              )

      true ->
        fact = Map.fetch!(facts, key)

        record
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.each(&assert_column_mapped!(fact, key, &1, :snapshot))

        :ok
    end
  end

  defp assert_column_mapped!(fact, key, name, op) do
    unless member_any?(fact.mapped, name) or member_any?(fact.skips, name) do
      raise Error.exception(
              reason: :source_column_unmapped,
              resource: fact.resource,
              op: op,
              shape: "#{elem(key, 0)}.#{elem(key, 1)}(#{name})"
            )
    end
  end

  # Record keys arrive as strings; declared sets may hold atoms — normalize.
  defp member_any?(set, name) do
    MapSet.member?(set, name) or MapSet.member?(set, String.to_atom(name))
  rescue
    ArgumentError -> MapSet.member?(set, name)
  end

  # --- relation facts derivation ---

  @doc """
  Derive the per-relation declared facts from the resolver index + the
  canonical contract (mapped columns, skips, target types, tenant flag,
  SCD2 flag, business key). Pure reflection over compiled resources.
  """
  @spec relation_facts(map(), Identity.manifest()) :: relation_facts()
  def relation_facts(index, contract) do
    relations =
      contract
      |> Map.get(:relations, [])
      |> Map.new(&{{&1.schema, &1.table}, &1})

    index
    |> Map.new(fn {{schema, table}, resource} ->
      relation = Map.fetch!(relations, {schema, table})

      # Coverage judges only SOURCE-side columns; the contract's column list
      # includes SCD2 window targets (sink-generated on the destination).
      declared_sources = relation.columns |> Enum.map(& &1.source) |> MapSet.new()

      sink_generated =
        relation.columns
        |> Enum.filter(&(&1.target in sink_generated_attribute_atoms(resource)))
        |> Enum.map(& &1.source)
        |> MapSet.new()

      source_mapped = MapSet.difference(declared_sources, sink_generated)
      skips = relation.skips |> MapSet.new()

      target_types =
        relation.columns
        |> Enum.reject(&MapSet.member?(sink_generated, &1.source))
        |> Map.new(&{&1.source, Map.fetch!(relation.types, &1.target)})

      facts = %{
        resource: resource,
        mapped: source_mapped,
        skips: skips,
        target_types: target_types,
        tenant?: relation.tenant != nil,
        append?: Info.append_log?(resource),
        scd2?: Info.history_scd2?(resource),
        business_key: business_key_sources(resource)
      }

      {{schema, table}, facts}
    end)
  end

  @doc """
  The SOURCE-side mapped column set (strings): the upsert reflection's
  attributes minus declared skips and destination-only metadata. SCD2 window
  columns, snapshot-provenance attributes, and an append target's structural
  identity/label columns are sink-generated on the target, never source columns
  (their absence from the live source table is not a missing mapping).
  """
  @spec source_mapped_set(module()) :: MapSet.t(String.t())
  def source_mapped_set(resource) do
    {skip, cloak, attrs} = AshReplicant.Resolver.upsert_reflection(resource)

    window = sink_generated_attribute_atoms(resource)

    # AshCloak replaces the plaintext attribute with encrypted_<name>; the
    # SOURCE column keeps the plaintext name — reverse-map so coverage judges
    # the real source column (the contract builder does the same).
    cloak_sources =
      cloak
      |> Enum.map(&Atom.to_string/1)
      |> MapSet.new()

    attrs
    |> MapSet.to_list()
    |> Kernel.--(skip)
    |> Kernel.--(window)
    |> Enum.map(&reverse_cloak_name(&1, cloak_sources))
    |> MapSet.new()
  end

  # `encrypted_<plain>` reverses to the plaintext SOURCE column name only
  # when the plaintext really is AshCloak-covered; anything else keeps its
  # own name (an unrelated `encrypted_` prefix is an ordinary column).
  defp reverse_cloak_name(attr, cloak_sources) do
    name = Atom.to_string(attr)

    case String.replace_prefix(name, "encrypted_", "") do
      ^name -> name
      plain -> if plain in cloak_sources, do: plain, else: name
    end
  end

  # Destination-only ATTRIBUTE atoms: SCD2 window/current columns and the two
  # protected snapshot-provenance fields. Excluding the provenance fields only
  # when the resource opts in preserves ordinary source columns with those names.
  defp sink_generated_attribute_atoms(resource) do
    history =
      if Info.history_scd2?(resource) do
        [
          elem(Info.replicant_history_valid_from_lsn_attribute(resource), 1),
          elem(Info.replicant_history_valid_to_lsn_attribute(resource), 1),
          opt_value(Info.replicant_history_valid_from_timestamp_attribute(resource)),
          opt_value(Info.replicant_history_valid_to_timestamp_attribute(resource)),
          opt_value(Info.replicant_history_current_attribute(resource)),
          # The destination-side SURROGATE primary key (uuid_primary_key) is not a
          # source column — but ONLY on SCD2 version resources; an SCD1 mirror's
          # single PK IS its source PK.
          scd2_surrogate_pk(resource)
        ]
      else
        []
      end

    provenance =
      if Info.replicant_snapshot_provenance!(resource) do
        [:replica_fingerprint, :replica_seen_attempt]
      else
        []
      end

    # ADR-0018: an append target's structural columns — the five identity axes,
    # the two labels, the backfill attempt, and the two message-route payload
    # columns — are stamped by the sink from the replication session/change or
    # the logical-message callback, never read from a source table row. The
    # append surrogate primary key is destination-only for the same reason.
    # Without this the coverage preflight would demand `commit_lsn`, `ordinal`,
    # `operation` … exist on the SOURCE table and fail every append activation.
    append =
      if Info.append_log?(resource) do
        Map.values(Info.append_attributes(resource)) ++
          Map.values(Info.append_message_attributes(resource)) ++
          [append_surrogate_pk(resource)]
      else
        []
      end

    (history ++ provenance ++ append)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  # An append target's PK is a surrogate by construction: the append identity is
  # the five-axis unique identity, never the primary key.
  defp append_surrogate_pk(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [pk] -> pk
      _other -> nil
    end
  rescue
    _ -> nil
  end

  defp scd2_surrogate_pk(resource) do
    if Info.history_scd2?(resource), do: primary_key_atom(resource)
  end

  defp primary_key_atom(resource) do
    history_pk = elem(Info.replicant_history_valid_from_lsn_attribute(resource), 1)

    business_key = business_key_atoms(resource)

    case Ash.Resource.Info.primary_key(resource) do
      [pk] ->
        # A single-column PK distinct from the window anchor and from the
        # business key is the surrogate (uuid_primary_key) — sink-generated,
        # not a source column.
        if pk != history_pk and pk not in business_key, do: pk

      _other ->
        nil
    end
  rescue
    _ -> nil
  end

  defp business_key_atoms(resource) do
    # The accessor RAISES when unset (no default) — a non-SCD2 or
    # business-key-less resource has no business key.
    Info.replicant_history_business_key!(resource)
  rescue
    _ -> []
  end

  defp opt_value({:ok, value}), do: value
  defp opt_value(_), do: nil

  defp business_key_sources(resource) do
    # The Spark accessor RAISES when the option is unset (no default); a
    # non-SCD2 resource has no business key.
    keys = Info.replicant_history_business_key!(resource)
    Enum.map(keys, &to_string/1)
  rescue
    _ -> []
  end

  @doc """
  The runtime coverage view cached in the Generation: the relation facts +
  the ignored-table key set (one source of truth for the contract, the bind
  classifier, and the delivery guards).
  """
  @spec from_manifest(map(), Identity.manifest()) :: %{
          facts: relation_facts(),
          ignored: MapSet.t()
        }
  def from_manifest(index, contract) do
    %{
      facts: relation_facts(index, contract),
      ignored: MapSet.new(Map.get(contract, :ignores, []), &{&1.schema, &1.table})
    }
  end

  @doc """
  The reconnect re-check (rule-2/3 subset): every mapped table must still be
  published and every publication table mapped or ignored. ONE short-lived
  identity-verified connection; catalog faults DEFER (the source was
  unreachable — it cannot stream, so the bind proceeds and the next reachable
  re-check renders the verdict). Value-free reasons on violation.
  """
  @spec reconnect_check(keyword(), map(), [String.t()], map(), Identity.manifest()) ::
          :ok | {:error, Error.t()}
  def reconnect_check(connection_opts, source_identity, publication, index, contract) do
    opts = Keyword.merge(connection_opts || [], pool_size: 1)
    conn = start_preflight_connection(opts)

    result =
      with {:ok, conn} <- conn,
           {:ok, census} <- collect_census(conn, publication),
           :ok <- verify_probe_identity(census.identity, source_identity) do
        facts = relation_facts(index, contract)
        ignored = MapSet.new(contract.ignores, &{&1.schema, &1.table})

        with :ok <- check_missing_expected(census.tables, facts) do
          check_unignored_publication(census.tables, facts, ignored)
        end
      else
        {:error, %Error{} = error} ->
          {:error, error}

        _census_connection_fault ->
          :ok
      end

    with {:ok, db_conn} <- conn do
      GenServer.stop(db_conn)
    end

    case result do
      :ok -> :ok
      {:error, %Error{} = error} -> emit_bind_conflict(error)
    end
  end

  # (emit_bind_conflict returns the error so reconnect_check's caller halts)

  # The bind-scoped halt telemetry (the same event the other bind guards use).
  defp emit_bind_conflict(%Error{reason: reason}) do
    AshReplicant.Telemetry.event(
      [:ash_replicant, :checkpoint, :conflict],
      %{count: 1},
      %{reason: reason, error_class: :invalid}
    )

    {:error, %Error{reason: reason}}
  end

  # --- catalog SQL (the framework's public QueryBuilder strings are reused
  # --- verbatim where they already expose the required census) ---

  @doc """
  ONE round-trip identity + version probe. `pg_control_system()` exposes the
  system identifier across the supported PostgreSQL 15 through 18 matrix, so
  every supported release verifies the same system-and-database pair.
  """
  @spec sql_identity_probe() :: String.t()
  def sql_identity_probe do
    "SELECT current_setting('server_version_num')::int, " <>
      "(SELECT system_identifier::text FROM pg_control_system()), " <>
      "current_database()"
  end

  @doc """
  The adapter-owned replica-identity census (one new SQL string; the join
  shape mirrors the framework's `pk_columns/0`). Publication list binds `$1`.
  """
  @spec sql_relreplident() :: String.t()
  def sql_relreplident do
    "SELECT p.schemaname, p.tablename, c.relreplident " <>
      "FROM (SELECT DISTINCT schemaname, tablename FROM pg_publication_tables WHERE pubname = ANY($1)) p " <>
      "JOIN pg_class c ON c.relname = p.tablename " <>
      "JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = p.schemaname"
  end

  # --- the activation preflight ---

  @doc """
  Run the full source-catalog preflight on ONE short-lived, identity-verified
  Postgrex connection (the snapshotter's `pool_size: 1` precedent). The
  identity probe must match the CONFIGURED source identity (the B2 session
  gate separately proves configured == actual replication session on the
  stream); catalog faults are scrubbed value-free. Any rule violation fails
  the pipeline start BEFORE the generation installs.
  """
  @spec preflight(
          keyword(),
          map(),
          [String.t()],
          map(),
          map(),
          AshReplicant.Checkpoint.Identity.manifest()
        ) ::
          {:ok, %{facts: relation_facts(), ignored: MapSet.t()}} | {:error, Error.t()}
  def preflight(connection_opts, source_identity, publication, _sink_config, index, contract) do
    opts = Keyword.merge(connection_opts || [], pool_size: 1)

    conn = start_preflight_connection(opts)

    result =
      with {:ok, conn} <- conn,
           {:ok, census} <- collect_census(conn, publication),
           :ok <- verify_probe_identity(census.identity, source_identity) do
        coverage = __MODULE__.from_manifest(index, contract)

        case __MODULE__.evaluate(census.tables, coverage.facts, contract.ignores) do
          :ok -> {:ok, coverage}
          {:error, _} = error -> error
        end
      else
        {:error, %Error{} = error} ->
          {:error, error}

        _census_connection_fault ->
          # A fault while READING the catalog (unreachable server, dropped
          # mid-probe) is the unreachable class — deferred verdict, not a
          # rule violation. Rule verdicts carry their own %Error{} above.
          :deferred
      end

    with {:ok, db_conn} <- conn do
      GenServer.stop(db_conn)
    end

    case result do
      # The deferred verdict (unreachable-at-boot OR faulted mid-probe): the
      # bind re-check completes the FULL preflight before any checkpoint read
      # (an unreachable source cannot advance a checkpoint, so nothing is
      # skipped). Reachable-and-violating still halts fail-closed.
      :deferred ->
        {:ok, :deferred}

      {:ok, _} = ok ->
        ok

      {:error, %Error{} = error} ->
        emit_preflight_failed(error)
        {:error, error}
    end
  end

  # Boot-resilience rule (design amendment, task-2 RED finding): an
  # UNREACHABLE source at activation defers the coverage verdict rather than
  # crashing the host. This cannot skip data — an unreachable source delivers
  # nothing, so no checkpoint can advance — and the bind re-check completes the
  # FULL preflight on the first connection that can actually stream
  # (before any checkpoint read). A REACHABLE source that violates a rule
  # still halts activation fail-closed.
  #
  # Admission: `Postgrex.start_link/1` only discovers an unresolvable
  # :database inside the pool's connect callback — the start itself returns
  # `{:ok, pool}`, every retry logs `[error] missing the :database key`, and
  # the census query burns the checkout queue-timeout before faulting. A
  # database the STREAM could not resolve either is the unreachable class
  # BEFORE any pool exists: same deferred verdict, no wall-clock burn, no
  # uncontrolled log output. Every non-pool outcome is the one structural
  # `{:error, :unreachable}` atom — callers route it through their
  # census-fault branch and never query or stop a placeholder.
  defp start_preflight_connection(opts) do
    if is_nil(resolved_database(opts)) do
      {:error, :unreachable}
    else
      case Postgrex.start_link(opts) do
        {:ok, conn} -> {:ok, conn}
        {:error, _reason} -> {:error, :unreachable}
      end
    end
  rescue
    _ -> {:error, :unreachable}
  end

  # Postgrex's own database resolution (`Postgrex.Utils.default_opts/1` — the
  # SAME resolution the replication stream's connection applies, so the census
  # and the stream can never disagree): an absent :database key falls back to
  # PGDATABASE; an explicit nil is NOT env-rescued (put_new sees the key) and
  # is stripped with every other nil. nil here means the stream's own
  # connection could not resolve a database either.
  defp resolved_database(opts) do
    case Keyword.fetch(opts, :database) do
      {:ok, database} -> database
      :error -> System.get_env("PGDATABASE")
    end
  end

  # The census: identity probe + the three framework statements + the
  # relreplident query, all read-only, publication bound $1.
  defp collect_census(conn, publication) do
    with {:ok, %{rows: [[version, system_identifier, database]]}} <-
           query(conn, sql_identity_probe()),
         {:ok, %Postgrex.Result{} = pub_rows} <-
           query_framework(
             conn,
             fn -> Replicant.QueryBuilder.publication_tables(publication) end,
             publication
           ),
         {:ok, %Postgrex.Result{} = column_rows} <-
           query_framework(conn, fn -> Replicant.QueryBuilder.table_columns() end, publication),
         {:ok, %Postgrex.Result{} = pk_rows} <-
           query_framework(conn, fn -> Replicant.QueryBuilder.pk_columns() end, publication),
         {:ok, %Postgrex.Result{} = ident_rows} <- query(conn, sql_relreplident(), [publication]) do
      columns_by_table = group_columns(column_rows)
      pk_by_table = group_pk(pk_rows)

      ident_by_table =
        Map.new(ident_rows.rows, fn [schema, table, ident] -> {{schema, table}, ident} end)

      tables =
        pub_rows.rows
        |> Map.new(fn [schema, table, _qualified] ->
          {{schema, table},
           %{
             columns: columns_by_table[{schema, table}] || [],
             relreplident: ident_by_table[{schema, table}] || "d",
             pk: pk_by_table[{schema, table}] || []
           }}
        end)

      {:ok,
       %{
         identity: %{version: version, system_identifier: system_identifier, database: database},
         tables: tables
       }}
    end
  end

  defp group_columns(%{rows: rows}) do
    Map.new(rows, fn [schema, table, _qualified, col_raw, _col_quoted, col_type_oids] ->
      columns =
        col_raw
        |> Enum.zip(col_type_oids)
        |> Enum.map(fn {name, oid} ->
          %{name: name, type: OidDatabase.name_for_type_id(oid)}
        end)

      {{schema, table}, columns}
    end)
  end

  defp group_pk(%{rows: rows}) do
    Map.new(rows, fn [schema, table, _qualified, pk_raw, _pk_quoted] ->
      {{schema, table}, Enum.map(pk_raw, &to_string/1)}
    end)
  end

  defp query_framework(conn, sql_fun, publication) do
    case sql_fun.() do
      {:ok, sql} -> query(conn, sql, [publication])
      # table_columns/0 and pk_columns/0 return bare SQL strings (only the
      # list-taking builders tag); both bind $1 the same way.
      sql when is_binary(sql) -> query(conn, sql, [publication])
      {:error, :invalid_identifier} -> {:error, :invalid_identifier}
    end
  end

  defp query(conn, sql, params \\ []) do
    case Postgrex.query(conn, sql, params) do
      {:ok, %Postgrex.Result{} = result} -> {:ok, result}
      {:error, _} = error -> error
    end
  end

  @doc """
  The probe-identity rule reachable on its own, over the same probed and
  configured identity maps `preflight/6` compares.

  The operator diagnosis surface (`AshReplicant.Doctor`) reports source identity
  as its own check and must apply exactly this rule rather than a second copy
  that could drift from what activation enforces.
  """
  @spec probe_identity_check(map(), map()) :: :ok | {:error, Error.t()}
  def probe_identity_check(probed, expected), do: verify_probe_identity(probed, expected)

  # The identity the preflight connection reports must equal the CONFIGURED
  # identity (the same triple the replication session separately proves).
  defp verify_probe_identity(%{system_identifier: system_id, database: db}, %{
         system_identifier: expected_system,
         database: expected_db
       }) do
    identity_ok? =
      db == expected_db and system_identifier_matches?(system_id, expected_system)

    if identity_ok? do
      :ok
    else
      {:error,
       Error.exception(
         reason: :source_identity_mismatch,
         resource: nil,
         op: :preflight,
         shape: "probe_database=#{db}"
       )}
    end
  end

  defp system_identifier_matches?(system_id, expected_system),
    do: to_string(system_id) == expected_system

  defp emit_preflight_failed(%Error{reason: reason}) do
    kind =
      case reason do
        :source_identity_mismatch -> :identity
        :source_replica_identity -> :replica_identity
        _coverage_class -> :coverage
      end

    AshReplicant.Telemetry.event(
      [:ash_replicant, :preflight, :failed],
      %{count: 1},
      %{reason: reason, kind: kind, slot_name: nil}
    )
  end
end
