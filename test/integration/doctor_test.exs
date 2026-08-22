defmodule AshReplicant.Integration.DoctorTest do
  @moduledoc """
  The read-only diagnosis against a LIVE PostgreSQL substrate.

  Three things only a real server can prove, and which the unit tests
  deliberately cannot:

    * `default_transaction_read_only=on` is honoured by the SERVER, not merely
      present in the connection options — a write on the probe connection is
      refused by PostgreSQL itself, with its own SQLSTATE. This leg holds even
      if the statement admission were removed entirely.
    * Every catalog statement the probes issue actually PARSES and RUNS on this
      server. Admission proves a string is not a write; only the server proves
      it is valid SQL for the supported majors.
    * A full diagnosis leaves the checkpoint table and the slot set unchanged.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshReplicant.Doctor
  alias AshReplicant.Doctor.Probe
  alias AshReplicant.Test.Marquee
  alias Ecto.Adapters.SQL.Sandbox

  @publication "repl_doctor_diag_pub"
  @source_table "doctor_diag_orders"
  @slot "doctor_diag_slot"

  defmodule LiveDiagnosisSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "doctor_diag_slot"
  end

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)

    Marquee.setup_schema!()
    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@source_table}")
    Marquee.q!("CREATE TABLE #{@source_table} (id text primary key, note text)")
    Marquee.q!("ALTER TABLE #{@source_table} REPLICA IDENTITY FULL")
    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@source_table}")

    {:ok, conn} = Postgrex.start_link(Probe.connection_options(Marquee.conn()))

    on_exit(fn ->
      stop_quietly(conn)
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@source_table}")
      Sandbox.mode(AshReplicant.TestRepo, :manual)
    end)

    %{conn: conn}
  end

  describe "the probe session is read-only at the SERVER" do
    test "PostgreSQL itself refuses DDL on the probe connection", %{conn: conn} do
      # Bypasses `admit!/1` deliberately: this asserts leg 2 of the no-writes
      # guarantee INDEPENDENTLY of leg 1.
      assert {:error, %Postgrex.Error{postgres: %{code: code}}} =
               Postgrex.query(conn, "CREATE TABLE doctor_diag_scratch (i int)", [])

      assert code == :read_only_sql_transaction
    end

    test "PostgreSQL refuses a DELETE against a real table", %{conn: conn} do
      assert {:error, %Postgrex.Error{postgres: %{code: :read_only_sql_transaction}}} =
               Postgrex.query(conn, "DELETE FROM #{@source_table}", [])
    end

    test "reads on the same connection still work", %{conn: conn} do
      assert {:ok, %Postgrex.Result{rows: [[database]]}} =
               Postgrex.query(conn, "SELECT current_database()", [])

      assert is_binary(database)
    end
  end

  describe "every probe statement runs on this server" do
    test "each admitted statement parses and executes", %{conn: conn} do
      for sql <- Probe.statements([@publication]) do
        assert {:ok, %Postgrex.Result{}} = Postgrex.query(conn, sql, statement_params(sql)),
               "statement failed on the live server: #{first_line(sql)}"
      end
    end
  end

  describe "gather/3 returns real source facts" do
    test "the identity probe, census, role, privileges, and slot come back" do
      assert {:ok, probed} = Probe.gather(Marquee.conn(), [@publication], @slot)

      assert is_integer(probed.release)
      assert probed.release >= 150_000
      assert probed.identity.system_identifier == Marquee.source_identity()[:system_identifier]
      assert is_binary(probed.identity.database)
      assert is_boolean(probed.role.superuser?)
      assert is_boolean(probed.role.replication?)

      # The published table is really there, with the FULL identity we set.
      assert Map.has_key?(probed.tables, {"public", @source_table})
      assert probed.tables[{"public", @source_table}].relreplident == "f"
      assert probed.tables[{"public", @source_table}].pk == ["id"]

      assert {"public", @source_table, true} in probed.table_privileges

      # No such slot on this instance — the absent case, live.
      assert probed.slot == nil
    end

    test "this server's release classifies as supported" do
      assert {:ok, probed} = Probe.gather(Marquee.conn(), [@publication], @slot)

      check = Doctor.check_source_release(probed.release)

      assert check.status in [:pass, :warn]
      refute check.reason == :source_release_unsupported
    end

    test "the live replica identity is judged by the same rule activation uses" do
      assert {:ok, probed} = Probe.gather(Marquee.conn(), [@publication], @slot)

      assert probed.tables[{"public", @source_table}].relreplident == "f"
    end
  end

  describe "a full diagnosis mutates nothing" do
    test "the checkpoint table is unchanged before and after", %{conn: conn} do
      before_state = checkpoint_state(conn)

      report = Doctor.run(:doctor, diagnosis_opts())

      assert report.exit_code in [0, 1, 2]
      assert checkpoint_state(conn) == before_state
    end

    test "the slot set is unchanged by a diagnosis", %{conn: conn} do
      before_slots = slot_names(conn)

      Doctor.run(:preflight, diagnosis_opts())

      assert slot_names(conn) == before_slots
    end

    test "the published table's rows and shape are unchanged", %{conn: conn} do
      before_shape = source_shape(conn)

      Doctor.run(:doctor, diagnosis_opts())

      assert source_shape(conn) == before_shape
    end

    # The cross-check only `:doctor` can make: a durable watermark whose slot has
    # disappeared means the WAL behind that position is unrecoverable. It needs
    # the checkpoint row and the slot row in the SAME run, so the orchestration
    # has to read the checkpoint BEFORE it judges retention — passing a `nil`
    # watermark there would make the whole rule unreachable in a real run.
    test "a durable watermark whose slot is gone is reported as lost retention" do
      identity = Marquee.source_identity()

      Marquee.q!(
        "INSERT INTO ash_replicant_checkpoints " <>
          "(source_system_id, source_database, slot_name, commit_lsn, inserted_at, updated_at) " <>
          "VALUES ($1, $2, $3, $4, now(), now())",
        [identity[:system_identifier], identity[:database], @slot, 4_294_967_296]
      )

      on_exit(fn ->
        Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      end)

      report = Doctor.run(:doctor, diagnosis_opts())

      checkpoint = Enum.find(report.checks, &(&1.name == :checkpoint_state))
      retention = Enum.find(report.checks, &(&1.name == :slot_retention))

      # The row really was read — otherwise the retention verdict below could be
      # satisfied vacuously by an unavailable destination.
      assert checkpoint.status == :pass
      assert checkpoint.reason == :checkpoint_bound

      assert retention.status == :fail
      assert retention.reason == :retention_lost
    end

    test "a live diagnosis reaches a real verdict, not a skipped one" do
      report = Doctor.run(:preflight, diagnosis_opts())

      reachable = Enum.find(report.checks, &(&1.name == :source_reachable))

      coverage = Enum.find(report.checks, &(&1.name == :source_coverage))
      replica_identity = Enum.find(report.checks, &(&1.name == :source_replica_identity))

      assert reachable.status == :pass

      assert coverage.status == :fail
      assert coverage.reason == :source_table_missing

      assert replica_identity.status == :skipped
      assert replica_identity.reason == :coverage_unjudgeable

      # Every source-derived check was actually JUDGED against the live census.
      for name <- [:source_release, :source_privileges, :slot_presence, :slot_retention] do
        assert Enum.find(report.checks, &(&1.name == name)).status != :skipped
      end
    end

    test "the real Mix task starts only its PostgreSQL client runtime" do
      identity = Marquee.source_identity()

      script = """
      defmodule AshReplicant.Integration.DoctorSubprocessPipeline do
        use AshReplicant.Pipeline,
          otp_app: :ash_replicant,
          sink: AshReplicant.Test.Marquee.Sink
      end

      connection = AshReplicant.Test.Marquee.conn()

      Application.put_env(
        :ash_replicant,
        AshReplicant.Integration.DoctorSubprocessPipeline,
        connection: connection,
        publication: \"#{@publication}\",
        source_identity: [
          system_identifier: System.fetch_env!(\"ASH_REPLICANT_DOCTOR_SYSTEM_IDENTIFIER\"),
          database: Keyword.fetch!(connection, :database)
        ]
      )

      Mix.Tasks.AshReplicant.Preflight.run([
        \"--pipeline\",
        \"AshReplicant.Integration.DoctorSubprocessPipeline\",
        \"--format\",
        \"json\"
      ])
      """

      {output, status} =
        System.cmd(System.find_executable("mix"), ["run", "--no-start", "-e", script],
          env: [
            {"MIX_ENV", "test"},
            {"ASH_REPLICANT_DOCTOR_SYSTEM_IDENTIFIER", identity[:system_identifier]}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      refute output =~ "DBConnection.Watcher"

      report = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      reachable = Enum.find(report["checks"], &(&1["name"] == "source_reachable"))

      assert reachable["status"] == "pass"
      assert reachable["reason"] == "ok"
    end
  end

  defp diagnosis_opts do
    [
      sink: LiveDiagnosisSink,
      connection: Marquee.conn(),
      publication: @publication,
      source_identity: Marquee.source_identity()
    ]
  end

  # The publication list binds `$1` on every census statement; the slot
  # statement binds the slot name; the identity probe binds nothing.
  defp statement_params(sql) do
    cond do
      String.contains?(sql, "pg_replication_slots WHERE slot_name") -> [@slot]
      String.contains?(sql, "$1") -> [[@publication]]
      true -> []
    end
  end

  defp first_line(sql), do: sql |> String.split("\n") |> hd() |> String.slice(0, 80)

  defp checkpoint_state(conn) do
    query!(
      conn,
      "SELECT count(*), coalesce(md5(string_agg(t.row_text, '|' ORDER BY t.row_text)), '') " <>
        "FROM (SELECT c::text AS row_text FROM ash_replicant_checkpoints c) t"
    )
  end

  defp slot_names(conn),
    do: query!(conn, "SELECT slot_name FROM pg_replication_slots ORDER BY slot_name")

  defp source_shape(conn),
    do:
      query!(
        conn,
        "SELECT count(*), coalesce(md5(string_agg(t::text, '|')), '') FROM #{@source_table} t"
      )

  defp query!(conn, sql) do
    {:ok, %Postgrex.Result{rows: rows}} = Postgrex.query(conn, sql, [])
    rows
  end

  defp stop_quietly(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn)
  catch
    :exit, _reason -> :ok
  end
end
