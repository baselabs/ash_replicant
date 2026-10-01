defmodule AshReplicant.Test.PgOld do
  @moduledoc """
  The pre-15 plugin-decoder substrate helper (ADR-0026): DDL and identity
  reads on a DIRECT Postgrex connection to the old-major source — never
  Ecto, never TestRepo (the destination stays the ordinary 16–18 test
  database; the old server is a SOURCE only).

  Gated on `ASH_REPLICANT_PGOLD_URL` (the same gating pattern as
  `AshReplicant.Test.PG`). The substrate image is
  `test/support/pg_old.dockerfile` (pglogical 2.4.8 + wal2json, both
  commit-pinned, mirroring the upstream ADR-0009 substrate); CI runs one cell
  per major with `wal_level=logical`.
  """

  alias AshReplicant.Test.PG

  @doc "True iff the old-major source URL is set (gates the decoder lane)."
  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env("ASH_REPLICANT_PGOLD_URL") not in [nil, ""]

  @doc "The source-side `connection:` opts for the pipeline and the DDL helper."
  @spec connection() :: keyword()
  def connection do
    url = System.fetch_env!("ASH_REPLICANT_PGOLD_URL")

    opts = url_opts(url)
    Keyword.merge(opts, queue_target: 50, queue_interval: 1000, timeout: 15_000)
  end

  @doc """
  The old source's ACTUAL session identity — the `source_identity:` the
  activation must be configured with (`pg_control_system()` exists from 9.6).
  """
  @spec identity!() :: [system_identifier: String.t(), database: String.t()]
  def identity! do
    {system_identifier, database} =
      query!(
        "SELECT (SELECT system_identifier::text FROM pg_control_system()), current_database()"
      ).rows
      |> List.first()
      |> then(fn [sys, db] -> {sys, db} end)

    [system_identifier: system_identifier, database: database]
  end

  @doc "The old source's `server_version_num` (the release-floor fixture fact)."
  @spec release!() :: integer()
  def release! do
    [[release]] = query!("SELECT current_setting('server_version_num')::int").rows
    release
  end

  @doc """
  Source-side DDL for one decoder lane: the source table, REPLICA IDENTITY
  FULL, and the decoder's own wiring — a pglogical node + replication set
  carrying the table for `:pglogical`, nothing beyond the table for
  `:wal2json` (its table set is config). Idempotent.
  """
  @spec setup_source!(String.t(), :pgoutput | :pglogical | :wal2json) :: :ok
  def setup_source!(table, decoder) do
    release = release!()
    setup_source!(table, decoder, release)
  end

  defp setup_source!(table, decoder, release) do
    query!("DROP TABLE IF EXISTS #{table}")
    query!("CREATE TABLE #{table} (id text primary key, note text, body text)")

    # wal2json delivers the full old record under REPLICA IDENTITY FULL;
    # pglogical 2.x REFUSES set membership for FULL tables (its native
    # protocol keys off the primary key — observed live: "table does not
    # have PRIMARY KEY and given replication set is configured to replicate
    # UPDATEs and/or DELETEs"), so the pglogical lane runs DEFAULT identity.
    unless decoder == :pglogical do
      query!("ALTER TABLE #{table} REPLICA IDENTITY FULL")
    end

    case decoder do
      :pgoutput when release >= 100_000 ->
        # The pgoutput lane proves the PUBLICATION path on the old major
        # (pgoutput 12 is the floor the doctor admits). Pre-10 has no
        # publications at all — the lane asserts the probe-failure class
        # there instead (the floor itself is unit-proven in doctor_test).
        query!("DROP PUBLICATION IF EXISTS decoder_lane_pub")
        query!("CREATE PUBLICATION decoder_lane_pub FOR TABLE #{table}")
        :ok

      :pgoutput ->
        :ok

      :pglogical ->
        query!("CREATE EXTENSION IF NOT EXISTS pglogical")
        drop_node!()

        query!(
          "SELECT pglogical.create_node('ash_replicant_lane', 'dbname=' || current_database())"
        )

        query!("SELECT pglogical.create_replication_set('lane_set')")
        query!("SELECT pglogical.replication_set_add_table('lane_set', '#{table}')")
        :ok

      :wal2json ->
        :ok
    end
  end

  @doc "Tear the source back down (slot + pglogical node + table)."
  @spec teardown_source!(String.t(), String.t(), :pglogical | :wal2json) :: :ok
  def teardown_source!(table, slot, decoder) do
    drop_slot!(slot)

    if decoder == :pglogical do
      drop_node!()
    end

    if decoder == :pgoutput and release!() >= 100_000 do
      query!("DROP PUBLICATION IF EXISTS decoder_lane_pub")
    end

    query!("DROP TABLE IF EXISTS #{table}")
    :ok
  end

  @doc "Value-free DDL row changes: insert / update / delete on the lane's table."
  def insert_row!(table, id, note),
    do: query!("INSERT INTO #{table} VALUES ($1, $2, NULL)", [id, note])

  def update_row!(table, id, note),
    do: query!("UPDATE #{table} SET note = $2 WHERE id = $1", [id, note])

  def delete_row!(table, id), do: query!("DELETE FROM #{table} WHERE id = $1", [id])

  @doc """
  A catalog-touching transaction with ZERO published changes — the exact
  shape Replicant 1.4 suppresses on pre-15 servers (every DDL txn): the
  decoder lane asserts the pipeline tolerates the suppression (ADR-0026).
  """
  def empty_catalog_txn!(table) do
    query!("COMMENT ON TABLE #{table} IS 'lane'")
  end

  @doc "Run a query on a short-lived direct connection (read or DDL)."
  @spec query!(String.t(), [term()]) :: Postgrex.Result.t()
  def query!(sql, params \\ []) do
    {:ok, conn} = Postgrex.start_link(Keyword.merge(connection(), pool_size: 1))

    try do
      case Postgrex.query(conn, sql, params) do
        {:ok, result} ->
          result

        {:error, error} ->
          raise "pgold query failed: " <> (error |> query_error_text() |> String.slice(0, 120))
      end
    after
      GenServer.stop(conn)
    end
  end

  @doc """
  The non-raising query the slot drop polls with: a busy walsender answers
  55006 (object_in_use) while the slot's client socket drains, so the poll
  must SEE the error, not die on it.
  """
  @spec query(String.t(), [term()]) :: {:ok, Postgrex.Result.t()} | {:error, term()}
  def query(sql, params \\ []) do
    {:ok, conn} = Postgrex.start_link(Keyword.merge(connection(), pool_size: 1))

    try do
      Postgrex.query(conn, sql, params)
    after
      GenServer.stop(conn)
    end
  end

  defp query_error_text(%Postgrex.Error{postgres: %{message: message}}), do: message
  defp query_error_text(other), do: inspect(other)

  defp drop_slot!(slot) do
    # The walsender releases a slot asynchronously after the client socket
    # closes (the marquee drop_slot! precedent): poll the drop through 55006.
    PG.wait_until(fn ->
      case query(
             "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = $1",
             [slot]
           ) do
        {:ok, %Postgrex.Result{num_rows: 0}} -> true
        {:ok, _dropped} -> false
        {:error, _busy} -> false
      end
    end)

    :ok
  end

  defp drop_node! do
    case query("SELECT pglogical.drop_node('ash_replicant_lane', true)") do
      {:ok, _dropped} -> :ok
      {:error, _absent_node} -> :ok
    end
  end

  defp url_opts(url) do
    uri = URI.parse(url)

    [
      hostname: uri.host,
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/", "/")
    ] ++ credentials(uri)
  end

  # Postgrex 0.22 has no URL parser module: derive the opts from the URI the
  # same way config/test.exs and the dynamic-destination fixture do — the
  # userinfo is `user` or `user:password`.
  defp credentials(%URI{userinfo: nil}), do: [username: "postgres"]

  defp credentials(%URI{userinfo: userinfo}) do
    case String.split(userinfo, ":", parts: 2) do
      [user] -> [username: user]
      [user, password] -> [username: user, password: password]
    end
  end
end
