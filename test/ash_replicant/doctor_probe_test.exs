defmodule AshReplicant.DoctorProbeTest do
  @moduledoc """
  The read-only admission tripwire for the operator diagnosis surface: every SQL
  string the preflight/doctor probes issue passes a fail-closed admission that
  rejects writes, data-modifying CTEs, row locks, statement separators, and
  `SELECT ... INTO`. No database — this is the leg of the no-writes property
  that must hold with no substrate at all.
  """
  use ExUnit.Case, async: true

  alias AshReplicant.Doctor.Error, as: DoctorError
  alias AshReplicant.Doctor.Probe

  describe "admit!/1 rejects every write shape" do
    test "a bare data-modifying statement is refused" do
      for sql <- [
            "UPDATE orders SET note = 'x'",
            "INSERT INTO orders (id) VALUES (1)",
            "DELETE FROM orders",
            "TRUNCATE orders",
            "MERGE INTO orders USING src ON true WHEN MATCHED THEN DO NOTHING",
            "DROP TABLE orders",
            "ALTER TABLE orders REPLICA IDENTITY FULL",
            "CREATE TABLE t (id int)",
            "GRANT SELECT ON orders TO someone",
            "REVOKE SELECT ON orders FROM someone",
            "COPY orders TO STDOUT",
            "VACUUM orders",
            "REFRESH MATERIALIZED VIEW m",
            "SET default_transaction_read_only = off",
            "LOCK TABLE orders",
            "CALL some_procedure()",
            "DO $$ BEGIN PERFORM 1; END $$"
          ] do
        assert_raise DoctorError, fn -> Probe.admit!(sql) end
      end
    end

    test "a data-modifying CTE hiding behind a leading SELECT is refused" do
      assert_raise DoctorError, fn ->
        Probe.admit!("WITH gone AS (DELETE FROM orders RETURNING id) SELECT count(*) FROM gone")
      end

      assert_raise DoctorError, fn ->
        Probe.admit!("SELECT count(*) FROM (INSERT INTO orders (id) VALUES (1) RETURNING id) s")
      end
    end

    test "a row-lock clause is refused — it is write intent" do
      for sql <- [
            "SELECT 1 FROM orders FOR UPDATE",
            "SELECT 1 FROM orders FOR NO KEY UPDATE",
            "SELECT 1 FROM orders FOR SHARE",
            "SELECT 1 FROM orders FOR KEY SHARE",
            "SELECT 1 FROM orders\n  FOR   UPDATE"
          ] do
        assert_raise DoctorError, fn -> Probe.admit!(sql) end
      end
    end

    test "a second statement smuggled past the separator is refused" do
      assert_raise DoctorError, fn -> Probe.admit!("SELECT 1; DROP TABLE orders") end
    end

    # The leading-SELECT rule alone cannot catch these: the statement really is a
    # SELECT and the write rides inside a function argument. The function name is
    # deliberately NOT `dblink*` here, so these cases isolate the whole-word scan —
    # removing a verb from that set must redden this test and nothing else.
    test "a write verb carried inside a function argument of a SELECT is refused" do
      for inner <- [
            "DELETE FROM orders",
            "INSERT INTO orders VALUES (1)",
            "UPDATE orders SET note = 'x'",
            "MERGE INTO orders USING s ON true WHEN MATCHED THEN DO NOTHING",
            "TRUNCATE orders",
            "CREATE TABLE t (i int)",
            "DROP TABLE orders",
            "ALTER TABLE orders REPLICA IDENTITY FULL",
            "GRANT ALL ON orders TO someone",
            "REVOKE ALL ON orders FROM someone",
            "REINDEX TABLE orders",
            "COMMIT"
          ] do
        assert_raise DoctorError, fn ->
          Probe.admit!("SELECT host_maintenance_hook('#{inner}')")
        end
      end
    end

    # These carry NO forbidden verb, so they isolate the forbidden-FUNCTION rule:
    # `set_config` switches the read-only session parameter off, and `dblink`
    # executes on a server where that parameter does not apply at all.
    test "a call that escapes the read-only session is refused" do
      for sql <- [
            "SELECT set_config('default_transaction_read_only', 'off', false)",
            "SELECT dblink('dbname=source', 'SELECT 1')",
            "SELECT dblink_exec('dbname=source', 'SELECT 1')",
            "SELECT lo_import('/etc/passwd')",
            "SELECT pg_read_file('postgresql.conf')"
          ] do
        assert_raise DoctorError, fn -> Probe.admit!(sql) end
      end
    end

    test "SELECT ... INTO materializes a table and is refused" do
      assert_raise DoctorError, fn -> Probe.admit!("SELECT id INTO copy_of FROM orders") end
    end

    test "a statement that does not begin with SELECT is refused" do
      for sql <- [
            "",
            "   ",
            "SHOW server_version_num",
            "-- SELECT 1",
            "WITH p AS (SELECT 1) SELECT * FROM p"
          ] do
        assert_raise DoctorError, fn -> Probe.admit!(sql) end
      end
    end
  end

  describe "admit!/1 non-vacuity" do
    test "every statement the probes actually issue is admitted" do
      statements = Probe.statements(["pub_one", "pub_two"])

      assert length(statements) >= 5

      for sql <- statements do
        assert Probe.admit!(sql) == sql
      end
    end

    test "a plain catalog read is admitted, whitespace and case notwithstanding" do
      assert Probe.admit!("SELECT current_setting('server_version_num')::int") ==
               "SELECT current_setting('server_version_num')::int"

      assert Probe.admit!("\n  select 1\n") == "\n  select 1\n"
    end
  end

  describe "connection_options/1" do
    test "forces the session read-only at the substrate, not just in the guard" do
      opts = Probe.connection_options(hostname: "source.example.com", database: "src")

      assert opts[:parameters][:default_transaction_read_only] == "on"
    end

    test "bounds the pool and never inherits a caller pool size" do
      opts = Probe.connection_options(hostname: "h", database: "d", pool_size: 25)

      assert opts[:pool_size] == 1
    end

    test "preserves the operator's own connection facts" do
      opts = Probe.connection_options(hostname: "h", database: "d", port: 5599)

      assert opts[:hostname] == "h"
      assert opts[:database] == "d"
      assert opts[:port] == 5599
    end

    test "a caller-supplied read-only override cannot be turned off" do
      opts =
        Probe.connection_options(
          database: "d",
          parameters: [default_transaction_read_only: "off"]
        )

      assert opts[:parameters][:default_transaction_read_only] == "on"
    end
  end
end
