defmodule AshReplicant.CoverageTest do
  @moduledoc """
  Pure unit tests for the strict source-coverage rule evaluation and the
  delivery-side accounting guards (roadmap B3) — hand-built census fixtures,
  no database. Every rule's violating fixture asserts the specific value-free
  reason; the closeout mutation proof flips one verdict to redden the matrix.
  """
  use ExUnit.Case, async: true

  alias AshReplicant.Coverage

  @table {"public", "orders"}
  @other {"public", "other"}

  defp census(overrides \\ []) do
    base = %{
      @table => %{
        columns: [
          %{name: "id", type: "text"},
          %{name: "note", type: "text"},
          %{name: "external_code", type: "text"},
          %{name: "audit_note", type: "text"}
        ],
        relreplident: "d",
        pk: ["id"]
      }
    }

    Enum.into(overrides, base)
  end

  defp facts(overrides \\ []) do
    base = %{
      @table => %{
        resource: AshReplicant.Test.Order,
        mapped: MapSet.new(["id", "note", "external_code"]),
        skips: MapSet.new(["audit_note"]),
        target_types: %{"id" => :string, "note" => :string, "external_code" => :string},
        tenant?: false,
        scd2?: false,
        business_key: []
      }
    }

    Enum.into(overrides, base)
  end

  describe "census connection admission — a database-less opts list never starts a pool" do
    import ExUnit.CaptureLog

    # Postgrex.start_link/1 admits a missing :database only INSIDE the pool's
    # connect callback (async): the pool starts "healthy", every retry logs
    # [error], and the census query burns the checkout queue-timeout before
    # faulting. The admission gate must treat a database-less opts list
    # (absent, nil, or []) as the unreachable class BEFORE any pool exists —
    # the same deferred verdict, no wall-clock burn, no uncontrolled [error]
    # output (the structural battery greps exactly that).
    @identity %{system_identifier: "741852963", database: "ash_replicant_test"}

    test "preflight: opts without :database defer immediately and silently" do
      log =
        capture_log(fn ->
          assert {:ok, :deferred} =
                   Coverage.preflight([], @identity, ["pub"], %{}, %{}, %{})
        end)

      refute log =~ "[error]", "the census must not log against a pool that can never connect"
    end

    test "preflight: a nil opts list (host omitted :connection) defers the same way" do
      log =
        capture_log(fn ->
          assert {:ok, :deferred} = Coverage.preflight(nil, @identity, ["pub"], %{}, %{}, %{})
        end)

      refute log =~ "[error]", "the census must not log against a pool that can never connect"
    end

    test "reconnect_check: opts without :database return :ok immediately and silently" do
      log =
        capture_log(fn ->
          assert :ok = Coverage.reconnect_check([], @identity, ["pub"], %{}, %{})
        end)

      refute log =~ "[error]", "the census must not log against a pool that can never connect"
    end
  end

  describe "evaluate/3 — the rule matrix" do
    test "a fully covered topology is :ok" do
      assert :ok = Coverage.evaluate(census(), facts(), [])
    end

    test "rule 2: a mapped table absent from the publication halts :source_table_missing" do
      assert {:error, %AshReplicant.Error{reason: :source_table_missing, shape: "public.other"}} =
               Coverage.evaluate(census(), facts([other_fact()]), [])
    end

    test "rule 3: an unignored publication table halts :source_table_unmapped" do
      assert {:error, %AshReplicant.Error{reason: :source_table_unmapped, shape: "public.extra"}} =
               Coverage.evaluate(census_with_extra(), facts(), [])
    end

    test "rule 3: an IGNORED publication table passes" do
      assert :ok =
               Coverage.evaluate(census_with_extra(), facts(), [
                 %{schema: "public", table: "extra"}
               ])
    end

    test "rule 4b: an ignore colliding with a mapped relation halts" do
      assert {:error,
              %AshReplicant.Error{
                reason: :config_invalid,
                shape: "ignore_collides_with_mapping=public.orders"
              }} =
               Coverage.evaluate(census(), facts(), [%{schema: "public", table: "orders"}])
    end

    test "rule 5: an unmapped live column halts :source_column_unmapped (names only)" do
      census =
        put_in(census(), [@table, :columns], [
          %{name: "id", type: "text"},
          %{name: "note", type: "text"},
          %{name: "external_code", type: "text"},
          %{name: "audit_note", type: "text"},
          %{name: "surprise", type: "text"}
        ])

      assert {:error,
              %AshReplicant.Error{
                reason: :source_column_unmapped,
                shape: "public.orders(surprise)"
              }} =
               Coverage.evaluate(census, facts(), [])
    end

    test "rule 6: a declared mapped column absent live halts :source_column_missing" do
      census =
        put_in(census(), [@table, :columns], [
          %{name: "id", type: "text"},
          %{name: "note", type: "text"},
          %{name: "audit_note", type: "text"}
        ])

      assert {:error,
              %AshReplicant.Error{
                reason: :source_column_missing,
                shape: "public.orders(external_code)"
              }} =
               Coverage.evaluate(census, facts(), [])
    end

    test "rule 6: a skip naming an absent column halts :source_skip_stale" do
      assert {:error,
              %AshReplicant.Error{
                reason: :source_skip_stale,
                shape: "public.orders(audit_note)"
              }} =
               Coverage.evaluate(census_no_audit(), facts(), [])
    end

    test "rule 7: a source type outside the target's allowed set halts :source_type_invalid" do
      census =
        put_in(census(), [@table, :columns], [
          %{name: "id", type: "text"},
          %{name: "note", type: "text"},
          %{name: "external_code", type: "int8"},
          %{name: "audit_note", type: "text"}
        ])

      assert {:error,
              %AshReplicant.Error{
                reason: :source_type_invalid,
                shape: "public.orders(external_code:int8)"
              }} =
               Coverage.evaluate(census, facts(), [])
    end

    test "rule 7: arrays unwrap to the element rule; unknown target types are not judged" do
      facts =
        put_in(facts(), [@table, :target_types], %{
          "id" => :string,
          "note" => {:array, :integer},
          "external_code" => SomeCustom.UnknownType,
          "audit_note" => :string
        })

      census =
        put_in(census(), [@table, :columns], [
          %{name: "id", type: "text"},
          %{name: "note", type: "_int4"},
          %{name: "external_code", type: "citext"},
          %{name: "audit_note", type: "text"}
        ])

      assert :ok = Coverage.evaluate(census, facts, [])
    end

    test "rule 10: a tenant-scoped table without FULL identity halts :source_replica_identity" do
      facts = put_in(facts(), [@table, :tenant?], true)

      assert {:error,
              %AshReplicant.Error{reason: :source_replica_identity, shape: "public.orders=d"}} =
               Coverage.evaluate(census(), facts, [])
    end

    test "rule 10: a tenant-scoped table WITH FULL identity passes" do
      facts = put_in(facts(), [@table, :tenant?], true)
      census = put_in(census(), [@table, :relreplident], "f")

      assert :ok = Coverage.evaluate(census, facts, [])
    end

    test "rule 10: an SCD2 table whose business key is NOT the source PK requires FULL" do
      facts =
        facts()
        |> put_in([@table, :scd2?], true)
        |> put_in([@table, :business_key], ["external_code"])

      assert {:error, %AshReplicant.Error{reason: :source_replica_identity}} =
               Coverage.evaluate(census(), facts, [])

      census = put_in(census(), [@table, :relreplident], "f")
      assert :ok = Coverage.evaluate(census, facts, [])
    end

    test "rule 10: an SCD2 table whose business key IS the source PK needs no FULL" do
      facts =
        facts()
        |> put_in([@table, :scd2?], true)
        |> put_in([@table, :business_key], ["id"])

      assert :ok = Coverage.evaluate(census(), facts, [])
    end
  end

  describe "assert_change!/3 — streaming column accounting" do
    test "an all-accounted change passes" do
      change = %Replicant.Change{
        op: :insert,
        schema: "public",
        table: "orders",
        columns: [
          %Replicant.Change.Column{name: "id"},
          %Replicant.Change.Column{name: "audit_note"}
        ]
      }

      assert :ok = Coverage.assert_change!(facts(), MapSet.new(), change)
    end

    test "an unaccounted column halts before any write" do
      change = %Replicant.Change{
        op: :insert,
        schema: "public",
        table: "orders",
        columns: [
          %Replicant.Change.Column{name: "id"},
          %Replicant.Change.Column{name: "surprise"}
        ]
      }

      assert_raise AshReplicant.Error, ~r/source_column_unmapped.*orders\(surprise\)/, fn ->
        Coverage.assert_change!(facts(), MapSet.new(), change)
      end
    end

    test "an unmapped table halts unless ignored" do
      change = %Replicant.Change{op: :insert, schema: "public", table: "extra", columns: []}

      assert_raise AshReplicant.Error, ~r/source_table_unmapped.*public\.extra/, fn ->
        Coverage.assert_change!(facts(), MapSet.new(), change)
      end

      assert :ok =
               Coverage.assert_change!(facts(), MapSet.new([{"public", "extra"}]), change)
    end
  end

  describe "assert_record_columns!/5 — snapshot accounting (record keys)" do
    test "an all-accounted record passes" do
      assert :ok =
               Coverage.assert_record_columns!(facts(), MapSet.new(), "public", "orders", %{
                 "id" => "1",
                 "audit_note" => "x"
               })
    end

    test "an unaccounted record key halts" do
      assert_raise AshReplicant.Error, ~r/source_column_unmapped.*orders\(surprise\)/, fn ->
        Coverage.assert_record_columns!(facts(), MapSet.new(), "public", "orders", %{
          "id" => "1",
          "surprise" => "x"
        })
      end
    end
  end

  describe "SQL builders" do
    test "the identity probe is version-conditional in ONE statement" do
      sql = Coverage.sql_identity_probe()

      assert sql =~ "server_version_num"
      assert sql =~ "pg_control_system"
      assert sql =~ "170000"
      assert sql =~ "current_database()"
    end

    test "the relreplident census mirrors pk_columns' join shape with $1 binding" do
      sql = Coverage.sql_relreplident()

      assert sql =~ "pg_publication_tables"
      assert sql =~ "ANY($1)"
      assert sql =~ "relreplident"
    end
  end

  # --- fixtures ---

  defp other_fact,
    do:
      {@other,
       %{
         resource: AshReplicant.Test.Order,
         mapped: MapSet.new(),
         skips: MapSet.new(),
         target_types: %{},
         tenant?: false,
         scd2?: false,
         business_key: []
       }}

  defp census_with_extra,
    do:
      Map.put(census(), {"public", "extra"}, %{
        columns: [%{name: "id", type: "text"}],
        relreplident: "d",
        pk: ["id"]
      })

  defp census_no_audit,
    do:
      put_in(census(), [@table, :columns], [
        %{name: "id", type: "text"},
        %{name: "note", type: "text"},
        %{name: "external_code", type: "text"}
      ])
end
