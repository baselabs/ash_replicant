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

  alias AshReplicant.Coverage
  alias AshReplicant.Doctor.Error
  alias Replicant.Decoder.OidDatabase

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
  Every statement the probes issue for a publication list. The non-vacuity
  anchor for `admit!/1`: a guard that admits nothing would be green and useless,
  so the test asserts this whole list is admitted.
  """
  @spec statements([String.t()]) :: [String.t()]
  def statements(publication) when is_list(publication) do
    [
      Coverage.sql_identity_probe(),
      Coverage.sql_relreplident(),
      sql_role_privileges(),
      sql_table_privileges(),
      sql_replication_slot()
    ] ++ framework_statements(publication)
  end

  defp framework_statements(publication) do
    [
      framework_sql(fn -> Replicant.QueryBuilder.publication_tables(publication) end),
      framework_sql(fn -> Replicant.QueryBuilder.table_columns() end),
      framework_sql(fn -> Replicant.QueryBuilder.pk_columns() end)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp framework_sql(builder) do
    case builder.() do
      {:ok, sql} when is_binary(sql) -> sql
      sql when is_binary(sql) -> sql
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
  The slot's type, plugin, liveness, and retention horizon. `wal_status` and
  `safe_wal_size` exist from PostgreSQL 13, so this is portable across the whole
  PostgreSQL 15 through 18 support matrix — unlike `invalidation_reason` (PG18), `conflicting`
  (PG16), and `inactive_since` (PG17). The slot name binds `$1`.
  """
  @spec sql_replication_slot() :: String.t()
  def sql_replication_slot do
    "SELECT slot_type, plugin, active, wal_status, " <>
      "(safe_wal_size IS NOT NULL AND safe_wal_size <= 0) AS exhausted " <>
      "FROM pg_replication_slots WHERE slot_name = $1"
  end

  @doc """
  Gather every source-side fact the diagnosis needs, on ONE short-lived
  read-only connection: the identity/release probe, the publication census
  (tables, columns, primary keys, replica identity), the connecting role's
  capability, per-table `SELECT` privilege, and the slot row.

  Returns `{:error, :unreachable}` for every connection-level outcome — an
  unresolvable database (classified BEFORE a pool exists, so no retry storm and
  no uncontrolled log output), a refused connection, or a fault mid-probe. The
  caller reports that as a failed reachability check and SKIPS everything it
  could not judge; it never guesses a verdict.
  """
  @spec gather(keyword(), [String.t()], String.t()) :: {:ok, map()} | {:error, :unreachable}
  def gather(connection_opts, publication, slot_name) do
    opts = connection_options(connection_opts || [])

    case open(opts) do
      {:ok, conn} ->
        try do
          collect(conn, publication, slot_name)
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

  defp collect(conn, publication, slot_name) do
    with {:ok, %{rows: [[release, system_identifier, database]]}} <-
           query(conn, Coverage.sql_identity_probe()),
         {:ok, pub_rows} <-
           framework_query(conn, publication, fn ->
             Replicant.QueryBuilder.publication_tables(publication)
           end),
         {:ok, column_rows} <-
           framework_query(conn, publication, fn -> Replicant.QueryBuilder.table_columns() end),
         {:ok, pk_rows} <-
           framework_query(conn, publication, fn -> Replicant.QueryBuilder.pk_columns() end),
         {:ok, ident_rows} <- query(conn, Coverage.sql_relreplident(), [publication]),
         {:ok, role_rows} <- query(conn, sql_role_privileges()),
         {:ok, privilege_rows} <- query(conn, sql_table_privileges(), [publication]),
         {:ok, slot_rows} <- query(conn, sql_replication_slot(), [slot_name]) do
      {:ok,
       %{
         release: release,
         identity: %{system_identifier: system_identifier, database: database},
         tables: census(pub_rows, column_rows, pk_rows, ident_rows),
         role: role(role_rows),
         table_privileges: table_privileges(privilege_rows),
         slot: slot(slot_rows)
       }}
    else
      _fault -> {:error, :unreachable}
    end
  end

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

  defp slot(%{rows: [[slot_type, plugin, active, wal_status, exhausted] | _]}) do
    %{
      slot_type: slot_type,
      plugin: plugin,
      active: active == true,
      wal_status: wal_status,
      exhausted: exhausted == true
    }
  end

  defp slot(_no_row), do: nil

  defp framework_query(conn, publication, builder) do
    case framework_sql(builder) do
      nil -> :error
      sql -> query(conn, sql, [publication])
    end
  end

  # `admit!/1` is the gate: an unadmitted statement raises before it can reach
  # the wire, so there is no path from this module to a write.
  defp query(conn, sql, params \\ []) do
    case Postgrex.query(conn, admit!(sql), params) do
      {:ok, %Postgrex.Result{} = result} -> {:ok, result}
      {:error, _reason} -> :error
    end
  rescue
    _error -> :error
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
