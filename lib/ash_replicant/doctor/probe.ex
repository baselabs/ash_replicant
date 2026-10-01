defmodule AshReplicant.Doctor.Error do
  @moduledoc """
  Raised when a statement that is not provably read-only reaches the operator
  diagnosis probes. This is a programmer error, never operator input: the
  preflight/doctor surface issues a fixed set of catalog reads, and admission is
  the leg of the no-writes guarantee that holds with no database present.

  The offending statement is NOT carried on the exception — a SQL string can
  embed a literal, and this error renders into operator output.
  """
  defexception [:message]

  @impl true
  def exception(_opts),
    do: %__MODULE__{message: "ash_replicant doctor refused a statement that is not read-only"}
end

defmodule AshReplicant.Doctor.Probe do
  @moduledoc false
  # The source-side read-only probes for `mix ash_replicant.preflight` /
  # `mix ash_replicant.doctor`. Three independent legs enforce "performs no
  # writes":
  #
  #   1. `admit!/1` — a fail-closed statement admission every probe statement
  #      passes. Provable with no substrate at all, which is why it exists.
  #   2. `connection_options/1` — the probe connection is opened with
  #      `default_transaction_read_only=on`, so PostgreSQL itself refuses a
  #      write the admission missed.
  #   3. The destination side never takes a row lock (see `AshReplicant.Doctor`).
  #
  # Everything here reads CATALOGS only. Publication names bind `$1`; the slot
  # name binds `$1`. No row data crosses (Critical Rule 4).

  alias AshReplicant.{Coverage, SourceSet}
  alias AshReplicant.Doctor.Error
  alias Replicant.Decoder.OidDatabase
  alias Replicant.Identifier

  # Any of these appearing as a WHOLE WORD refuses the statement. The set is a
  # fail-closed superset: `ANALYZE`, `SET`, and `LOCK` are harmless in isolation
  # but none of the admitted statements needs them, so refusing costs nothing
  # and closes the smuggling route. `WITH` is absent deliberately — `WITH
  # ORDINALITY` appears in the framework's own catalog reads, and a
  # data-modifying CTE is caught by its own verb.
  @forbidden_words ~w(
    INSERT UPDATE DELETE MERGE TRUNCATE CREATE DROP ALTER GRANT REVOKE
    COPY CALL DO SET LOCK VACUUM ANALYZE REFRESH COMMENT NOTIFY LISTEN
    UNLISTEN INTO PREPARE EXECUTE DEALLOCATE DECLARE FETCH MOVE CLOSE
    BEGIN COMMIT ROLLBACK SAVEPOINT REASSIGN REINDEX CLUSTER IMPORT
  )

  @forbidden_word_pattern ~r/\b(?:#{Enum.join(@forbidden_words, "|")})\b/i

  # Functions that write, or that reach outside the read-only session, from
  # INSIDE a legitimate SELECT — the one shape neither the leading-verb rule nor
  # the whole-word scan can see. `set_config` would turn leg 2 (the read-only
  # session parameter) off; `dblink*` executes on another server where leg 2
  # does not apply at all.
  @forbidden_function_pattern ~r/\b(?:set_config|dblink\w*|pg_read_file|pg_read_binary_file|lo_\w+)\s*\(/i

  # Row locks are write intent even inside a SELECT.
  @lock_pattern ~r/\bFOR\s+(?:UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b/i

  @leading_select_pattern ~r/\A\s*SELECT\b/i

  @doc """
  Admit one statement as read-only, or raise. Returns the statement unchanged so
  it can be used inline at the call site — an unadmitted statement can never
  reach `Postgrex.query/3`.
  """
  @spec admit!(String.t()) :: String.t()
  def admit!(sql) when is_binary(sql) do
    if read_only?(sql), do: sql, else: raise(Error)
  end

  def admit!(_sql), do: raise(Error)

  defp read_only?(sql) do
    Regex.match?(@leading_select_pattern, sql) and
      not String.contains?(sql, ";") and
      not Regex.match?(@forbidden_word_pattern, sql) and
      not Regex.match?(@forbidden_function_pattern, sql) and
      not Regex.match?(@lock_pattern, sql)
  end

  @doc """
  Every statement the probes issue for an admitted source set — the
  non-vacuity anchor for `admit!/1`: a guard that admits nothing would be
  green and useless, so the test asserts this whole list is admitted, for
  EVERY decoder's statement set plus BOTH release forms of the slot
  statement (ADR-0026).
  """
  @spec statements(SourceSet.t()) :: [String.t()]
  def statements(%SourceSet{} = source_set) do
    [
      Coverage.sql_identity_probe(),
      sql_role_privileges(),
      sql_output_plugin_extension(),
      sql_replication_slot(130_000),
      sql_replication_slot(90_600)
    ] ++ table_set_statements(SourceSet.census_member(source_set))
  end

  defp table_set_statements({:publication, publication}) do
    [
      Coverage.sql_relreplident(),
      sql_table_privileges(),
      framework_sql(fn -> Replicant.QueryBuilder.publication_tables(publication) end),
      framework_sql(fn -> Replicant.QueryBuilder.table_columns() end),
      framework_sql(fn -> Replicant.QueryBuilder.pk_columns() end)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # pglogical's members are server state, not config, so its per-table
  # statements cannot be built at plan time — the statement set carries the
  # (identifier-validated) set-name discovery query, and `gather` builds the
  # per-table statements from the discovered members.
  defp table_set_statements({:replication_sets, sets}) do
    [framework_sql(fn -> Replicant.QueryBuilder.replication_set_tables(sets) end)]
    |> Enum.reject(&is_nil/1)
  end

  defp table_set_statements({:tables, tables}) do
    case tables do
      [] ->
        []

      _ ->
        [
          ok_sql(fn -> Coverage.sql_relreplident_for(tables) end),
          ok_sql(fn -> sql_table_privileges_for(tables) end),
          ok_sql(fn -> Replicant.QueryBuilder.table_columns_for(tables) end),
          ok_sql(fn -> Replicant.QueryBuilder.pk_columns_for(tables) end)
        ]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp framework_sql(builder) do
    case builder.() do
      {:ok, sql} when is_binary(sql) -> sql
      sql when is_binary(sql) -> sql
      _invalid -> nil
    end
  end

  defp ok_sql(builder) do
    case builder.() do
      {:ok, sql} when is_binary(sql) -> sql
      _invalid -> nil
    end
  end

  @doc """
  The role's replication capability and superuser status. `pg_roles` is
  world-readable minus `rolpassword`, which this never selects.
  """
  @spec sql_role_privileges() :: String.t()
  def sql_role_privileges,
    do: "SELECT rolsuper, rolreplication FROM pg_roles WHERE rolname = current_user"

  @doc """
  Per published table, whether the connecting role may `SELECT` it. `format('%I.%I')`
  is the server's own identifier quoting; the publication list binds `$1`.
  """
  @spec sql_table_privileges() :: String.t()
  def sql_table_privileges do
    "SELECT p.schemaname, p.tablename, " <>
      "has_table_privilege(format('%I.%I', p.schemaname, p.tablename), 'SELECT') " <>
      "FROM (SELECT DISTINCT schemaname, tablename FROM pg_publication_tables WHERE pubname = ANY($1)) p"
  end

  @doc """
  The `sql_table_privileges/0` row shape for an EXPLICIT table list (the
  plugin decoders, ADR-0026): both parts of every pair
  `Replicant.Identifier`-validated before the `VALUES` interpolation, the
  framework's own `*_for/1` rule.
  """
  @spec sql_table_privileges_for([{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, :invalid_identifier}
  def sql_table_privileges_for(tables) when is_list(tables) and tables != [] do
    with :ok <- validate_table_pairs(tables) do
      values = Enum.map_join(tables, ", ", fn {schema, table} -> "('#{schema}','#{table}')" end)

      {:ok,
       "SELECT n.nspname, c.relname, " <>
         "has_table_privilege(format('%I.%I', n.nspname, c.relname), 'SELECT') " <>
         "FROM (VALUES #{values}) AS p0(nsp, rel) " <>
         "JOIN pg_namespace n ON n.nspname = p0.nsp " <>
         "JOIN pg_class c ON c.relname = p0.rel AND c.relnamespace = n.oid"}
    end
  end

  def sql_table_privileges_for(_other), do: {:error, :invalid_identifier}

  @doc """
  Whether an output plugin's EXTENSION is available on the server — the one
  plugin-presence fact a catalog read can prove (pglogical ships as an
  extension; wal2json is a decoding library with no extension row, so its
  presence stays the transport's connect-time probe). The fixed name binds
  `$1`; value-free.
  """
  @spec sql_output_plugin_extension() :: String.t()
  def sql_output_plugin_extension do
    "SELECT name, installed_version IS NOT NULL FROM pg_available_extensions WHERE name = $1"
  end

  defp validate_table_pairs(tables) do
    tables
    |> Enum.reduce_while(:ok, fn {schema, table}, :ok ->
      with :ok <- Identifier.validate(schema),
           :ok <- Identifier.validate(table) do
        {:cont, :ok}
      else
        {:error, :invalid_identifier} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  The slot's type, plugin, liveness, and retention horizon, for the server
  release the probe already read. `wal_status` and `safe_wal_size` exist from
  PostgreSQL 13 — a pre-13 release gets the same row shape with NULL for both,
  and the risk classifier reads an absent status as `:unknown`, never a
  guess. O03 (ADR-0022) reads `safe_wal_size` from the SAME statement — one
  SQL home (rule 11). The slot name binds `$1`.
  """
  @spec sql_replication_slot(pos_integer()) :: String.t()
  def sql_replication_slot(release) when is_integer(release) and release >= 130_000 do
    "SELECT slot_type, plugin, active, wal_status, " <>
      "(safe_wal_size IS NOT NULL AND safe_wal_size <= 0) AS exhausted, " <>
      "safe_wal_size " <>
      "FROM pg_replication_slots WHERE slot_name = $1"
  end

  def sql_replication_slot(_pre_13_release) do
    "SELECT slot_type, plugin, active, NULL::text AS wal_status, " <>
      "NULL::bool AS exhausted, NULL::int8 AS safe_wal_size " <>
      "FROM pg_replication_slots WHERE slot_name = $1"
  end

  @doc """
  Gather every source-side fact the diagnosis needs, on ONE short-lived
  read-only connection: the identity/release probe, the publication census
  (tables, columns, primary keys, replica identity), the connecting role's
  capability, per-table `SELECT` privilege, and the slot row.

  Returns `{:error, :unreachable}` for every connection-level outcome — an
  unresolvable database (classified BEFORE a pool exists, so no retry storm and
  no uncontrolled log output), a refused connection, or a dropped connection
  mid-probe. A statement-level permission failure remains
  `:permission_denied`; another statement fault remains `:query_failed`. The
  caller can therefore preserve established reachability and report the
  unjudgeable checks without calling a responding server unreachable.
  """
  @spec gather(keyword(), SourceSet.t(), String.t()) ::
          {:ok, map()} | {:error, :unreachable | :permission_denied | :query_failed}
  def gather(connection_opts, source_set, slot_name) do
    opts = connection_options(connection_opts || [])

    case open(opts) do
      {:ok, conn} ->
        try do
          collect(conn, source_set, slot_name)
        after
          GenServer.stop(conn)
        end

      {:error, :unreachable} = error ->
        error
    end
  end

  # Postgrex only discovers an unresolvable `:database` inside the pool's
  # connect callback: the start returns `{:ok, pool}`, every retry logs, and the
  # first query burns the checkout timeout. Mirror `AshReplicant.Coverage`'s
  # admission and classify that BEFORE any pool exists, using postgrex's own
  # resolution so the probe and the replication stream can never disagree.
  defp open(opts) do
    if is_nil(resolved_database(opts)) do
      {:error, :unreachable}
    else
      case Postgrex.start_link(opts) do
        {:ok, conn} -> {:ok, conn}
        {:error, _reason} -> {:error, :unreachable}
      end
    end
  rescue
    _error -> {:error, :unreachable}
  end

  defp resolved_database(opts) do
    case Keyword.fetch(opts, :database) do
      {:ok, database} -> database
      :error -> System.get_env("PGDATABASE")
    end
  end

  @doc """
  O03 (ADR-0022): the one slot-fact probe the runtime (census + the
  activation resume gate) shares with the doctor — a short-lived read-only
  connection, `admit!/1`, and the SAME `sql_replication_slot/0` statement
  (rule 11: one SQL home, never a copy). Returns the slot fact map, `nil`
  for no slot row, or `:unreachable` for any connection- or statement-level
  fault (the runtime cannot act on the finer classes the doctor reports).
  """
  @spec probe_slot(keyword(), String.t()) :: map() | nil | :unreachable
  def probe_slot(connection_opts, slot_name) when is_binary(slot_name) do
    opts = connection_options(connection_opts || [])

    case open(opts) do
      {:ok, conn} ->
        try do
          read_slot(conn, slot_name)
        after
          GenServer.stop(conn)
        end

      {:error, :unreachable} ->
        :unreachable
    end
  end

  defp collect(conn, source_set, slot_name) do
    with {:ok, %{rows: [[release, system_identifier, database]]}} <-
           query(conn, Coverage.sql_identity_probe()),
         # The extension read runs BEFORE the table-set probes: with the
         # pglogical extension absent, `pglogical.tables` does not exist and
         # the census query faults — the plugin verdict must SURVIVE that
         # failure to be reportable at all (ADR-0026).
         {:ok, extension} <- probe_extension(conn, source_set),
         {:ok, table_rows} <- probe_table_rows(conn, SourceSet.census_member(source_set)),
         {:ok, privilege_rows} <- probe_privileges(conn, SourceSet.census_member(source_set)),
         {:ok, role_rows} <- query(conn, sql_role_privileges()),
         {:ok, slot_rows} <- query(conn, sql_replication_slot(release), [slot_name]) do
      {pub_rows, column_rows, pk_rows, ident_rows} = table_rows

      {:ok,
       %{
         release: release,
         identity: %{system_identifier: system_identifier, database: database},
         tables: census(pub_rows, column_rows, pk_rows, ident_rows),
         role: role(role_rows),
         table_privileges: table_privileges(privilege_rows),
         extension: extension,
         slot: slot(slot_rows)
       }}
    else
      {:error, reason} when reason in [:unreachable, :permission_denied, :query_failed] ->
        {:error, reason}

      _fault ->
        {:error, :query_failed}
    end
  end

  # The census table rows per decoder — the same statements
  # `AshReplicant.Coverage.collect_census/2` runs, re-derived through the
  # same builders (rule 11: one SQL home).
  defp probe_table_rows(conn, {:publication, publication}) do
    with {:ok, pub_rows} <-
           framework_query(conn, publication, fn ->
             Replicant.QueryBuilder.publication_tables(publication)
           end),
         {:ok, column_rows} <-
           framework_query(conn, publication, fn -> Replicant.QueryBuilder.table_columns() end),
         {:ok, pk_rows} <-
           framework_query(conn, publication, fn -> Replicant.QueryBuilder.pk_columns() end),
         {:ok, ident_rows} <- query(conn, Coverage.sql_relreplident(), [publication]) do
      {:ok, {pub_rows, column_rows, pk_rows, ident_rows}}
    end
  end

  defp probe_table_rows(conn, {:tables, tables}) do
    probe_tables_explicit(conn, tables)
  end

  defp probe_table_rows(conn, {:replication_sets, sets}) do
    with {:ok, sql} <- Replicant.QueryBuilder.replication_set_tables(sets),
         {:ok, %Postgrex.Result{} = pub_rows} <- query(conn, sql, []) do
      tables = Enum.map(pub_rows.rows, fn [schema, table, _qualified] -> {schema, table} end)
      probe_tables_explicit(conn, tables)
    else
      {:error, :invalid_identifier} -> {:error, :query_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe_tables_explicit(_conn, []) do
    {:ok, {empty(), empty(), empty(), empty()}}
  end

  defp probe_tables_explicit(conn, tables) do
    with {:ok, column_sql} <- Replicant.QueryBuilder.table_columns_for(tables),
         {:ok, column_rows} <- query(conn, column_sql, []),
         {:ok, pk_sql} <- Replicant.QueryBuilder.pk_columns_for(tables),
         {:ok, pk_rows} <- query(conn, pk_sql, []),
         {:ok, ident_sql} <- Coverage.sql_relreplident_for(tables),
         {:ok, ident_rows} <- query(conn, ident_sql, []) do
      # Only server-PRESENT tables enter the synthesized table set: a
      # configured-but-absent table must hit the missing-expected-table rule
      # (:source_table_missing), never a column-shape verdict.
      {:ok, {present_table_set(tables, column_rows), column_rows, pk_rows, ident_rows}}
    else
      {:error, :invalid_identifier} -> {:error, :query_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp present_table_set(tables, column_rows) do
    present =
      column_rows.rows
      |> MapSet.new(fn [schema, table | _rest] -> {schema, table} end)

    tables
    |> Enum.filter(&MapSet.member?(present, &1))
    |> table_set_result()
  end

  defp probe_privileges(conn, {:publication, publication}) do
    query(conn, sql_table_privileges(), [publication])
  end

  defp probe_privileges(conn, {:tables, tables}), do: explicit_privileges(conn, tables)

  defp probe_privileges(conn, {:replication_sets, sets}) do
    with {:ok, sql} <- Replicant.QueryBuilder.replication_set_tables(sets),
         {:ok, %Postgrex.Result{} = pub_rows} <- query(conn, sql, []) do
      tables = Enum.map(pub_rows.rows, fn [schema, table, _qualified] -> {schema, table} end)
      explicit_privileges(conn, tables)
    else
      {:error, :invalid_identifier} -> {:error, :query_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp explicit_privileges(_conn, []) do
    {:ok, %Postgrex.Result{rows: []}}
  end

  defp explicit_privileges(conn, tables) do
    case sql_table_privileges_for(tables) do
      {:ok, sql} -> query(conn, sql, [])
      {:error, :invalid_identifier} -> {:error, :query_failed}
    end
  end

  # The output-plugin extension fact, for the decoders whose presence a
  # catalog read can prove.
  defp probe_extension(conn, %SourceSet{decoder: :pglogical}) do
    case query(conn, sql_output_plugin_extension(), ["pglogical"]) do
      {:ok, result} -> {:ok, extension(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe_extension(_conn, %SourceSet{decoder: :pgoutput}), do: {:ok, :not_applicable}

  # wal2json is a decoding library, not an extension: no catalog row can
  # prove it, and the transport's connect-time probe stays the authority.
  defp probe_extension(_conn, %SourceSet{decoder: :wal2json}), do: {:ok, :not_provable}

  defp extension(%{rows: rows}) do
    case rows do
      [[name, installed?]] -> %{name: name, installed?: installed? == true}
      [] -> nil
    end
  end

  defp table_set_result(tables) do
    %Postgrex.Result{rows: Enum.map(tables, fn {schema, table} -> [schema, table, nil] end)}
  end

  defp empty, do: %Postgrex.Result{rows: []}

  defp census(pub_rows, column_rows, pk_rows, ident_rows) do
    columns_by_table =
      Map.new(column_rows.rows, fn [schema, table, _qualified, raw, _quoted, oids] ->
        columns =
          raw
          |> Enum.zip(oids)
          |> Enum.map(fn {name, oid} ->
            %{name: name, type: OidDatabase.name_for_type_id(oid)}
          end)

        {{schema, table}, columns}
      end)

    pk_by_table =
      Map.new(pk_rows.rows, fn [schema, table, _qualified, raw, _quoted] ->
        {{schema, table}, Enum.map(raw, &to_string/1)}
      end)

    ident_by_table =
      Map.new(ident_rows.rows, fn [schema, table, ident] -> {{schema, table}, ident} end)

    Map.new(pub_rows.rows, fn [schema, table, _qualified] ->
      {{schema, table},
       %{
         columns: columns_by_table[{schema, table}] || [],
         relreplident: ident_by_table[{schema, table}] || "d",
         pk: pk_by_table[{schema, table}] || []
       }}
    end)
  end

  defp role(%{rows: [[superuser?, replication?] | _]}),
    do: %{superuser?: superuser? == true, replication?: replication? == true}

  defp role(_rows), do: %{superuser?: false, replication?: false}

  defp table_privileges(%{rows: rows}),
    do: Enum.map(rows, fn [schema, table, allowed?] -> {schema, table, allowed? == true} end)

  defp slot(%{rows: [[slot_type, plugin, active, wal_status, exhausted, safe_wal_size] | _]}) do
    %{
      slot_type: slot_type,
      plugin: plugin,
      active: active == true,
      wal_status: wal_status,
      exhausted: exhausted == true,
      safe_wal_size: safe_wal_size
    }
  end

  defp slot(_no_row), do: nil

  defp framework_query(conn, publication, builder) do
    case framework_sql(builder) do
      nil -> {:error, :query_failed}
      sql -> query(conn, sql, [publication])
    end
  end

  # `admit!/1` is the gate: an unadmitted statement raises before it can reach
  # the wire, so there is no path from this module to a write.
  defp query(conn, sql, params \\ []) do
    case Postgrex.query(conn, admit!(sql), params) do
      {:ok, %Postgrex.Result{} = result} -> {:ok, result}
      {:error, reason} -> {:error, classify_query_error(reason)}
    end
  rescue
    error -> {:error, classify_query_error(error)}
  catch
    :exit, _reason -> {:error, :unreachable}
    _kind, _reason -> {:error, :query_failed}
  end

  @doc false
  @spec classify_query_error(term()) :: :unreachable | :permission_denied | :query_failed
  def classify_query_error(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}),
    do: :permission_denied

  def classify_query_error(%DBConnection.ConnectionError{}), do: :unreachable
  def classify_query_error(_error), do: :query_failed

  defp read_slot(conn, slot_name) do
    with {:ok, release} <- release_of(conn),
         {:ok, result} <- query(conn, sql_replication_slot(release), [slot_name]) do
      case result do
        %{rows: []} -> nil
        _read -> slot(result)
      end
    else
      _fault -> :unreachable
    end
  end

  defp release_of(conn) do
    case query(conn, "SELECT current_setting('server_version_num')::int", []) do
      {:ok, %{rows: [[release]]}} when is_integer(release) -> {:ok, release}
      _other -> {:error, :query_failed}
    end
  end

  @doc """
  The probe connection options: the operator's own connection facts, with the
  session forced read-only at the substrate and the pool bound to one
  connection. A caller-supplied `default_transaction_read_only` can only be
  overridden TOWARDS read-only — the diagnosis surface has no legitimate reason
  to write, so there is no opt-out.
  """
  @spec connection_options(keyword()) :: keyword()
  def connection_options(connection_opts) do
    parameters =
      connection_opts
      |> Keyword.get(:parameters, [])
      |> Keyword.put(:default_transaction_read_only, "on")

    connection_opts
    |> Keyword.put(:parameters, parameters)
    |> Keyword.put(:pool_size, 1)
  end
end
