defmodule AshReplicant.AppendTest do
  @moduledoc """
  The append-log delivery path (ADR-0018): operation shapes, atomic identity,
  append-once, tenancy, and classification.

  These drive `AshReplicant.Apply.apply_change/3` directly against live
  Postgres — the same entry point the sink's transaction body calls per change
  — so what is asserted is what actually lands in the host's event table, not
  a sink-level summary of it.
  """

  use AshReplicant.DataCase, async: false

  require Ash.Query

  @moduletag :integration

  alias AshReplicant.{Append, Apply}
  alias AshReplicant.Error
  alias AshReplicant.Test.{AdmittedGeneration, AppendSink}
  alias AshReplicant.Test.OrderEvent
  alias AshReplicant.Test.SecretEvent
  alias AshReplicant.Test.TenantOrderEvent
  alias Ecto.Adapters.SQL

  setup do
    start_supervised!(AshReplicant.Test.CloakVault)
    :ok
  end

  @system "7000000000000000001"
  @database "ash_replicant_test"
  @slot "append_slot"

  defp config do
    {:ok, index} = AshReplicant.Resolver.build_index([AshReplicant.Test.AppendDomain])

    %{
      resolver_index: index,
      repo: AshReplicant.TestRepo,
      authorize?: false,
      slot_name: @slot,
      source_identity: %{system_identifier: @system, database: @database}
    }
  end

  defp change(op, table, opts) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: table,
      record: Keyword.get(opts, :record),
      old_record: Keyword.get(opts, :old_record),
      commit_lsn: Keyword.fetch!(opts, :lsn),
      ordinal: Keyword.fetch!(opts, :ordinal)
    }
  end

  defp message(content, opts) do
    %Replicant.Decoder.Messages.Message{
      transactional?: Keyword.get(opts, :transactional?, false),
      lsn: Keyword.get(opts, :lsn),
      prefix: "events",
      content: content,
      ordinal: Keyword.get(opts, :ordinal)
    }
  end

  defp message_route, do: %{resource: OrderEvent, action: :append}

  defp events(resource \\ OrderEvent, opts \\ []) do
    resource
    |> Ash.Query.sort(commit_lsn: :asc, ordinal: :asc)
    |> Ash.read!(Keyword.merge([authorize?: false], opts))
  end

  describe "operation shapes are explicit and value-safe (ADR-0018 §4)" do
    test "an INSERT appends one immutable event carrying the mapped payload" do
      Apply.apply_change(
        config(),
        change(:insert, "orders", record: %{"id" => "o1", "note" => "n1"}, lsn: 10, ordinal: 0)
      )

      assert [event] = events()

      assert %OrderEvent{
               source_system_id: @system,
               source_database: @database,
               slot_name: @slot,
               commit_lsn: 10,
               ordinal: 0,
               operation: "insert",
               origin: "stream",
               snapshot_attempt: nil,
               id: "o1",
               note: "n1"
             } = event
    end

    test "an UPDATE appends the NEW record under operation \"update\"" do
      cfg = config()

      Apply.apply_change(
        cfg,
        change(:insert, "orders",
          record: %{"id" => "o1", "note" => "before"},
          lsn: 10,
          ordinal: 0
        )
      )

      Apply.apply_change(
        cfg,
        change(:update, "orders",
          record: %{"id" => "o1", "note" => "after"},
          old_record: %{"id" => "o1", "note" => "before"},
          lsn: 11,
          ordinal: 0
        )
      )

      assert [%{operation: "insert", note: "before"}, %{operation: "update", note: "after"}] =
               events()
    end

    test "a DELETE appends the OLD record under operation \"delete\" and removes nothing" do
      cfg = config()

      Apply.apply_change(
        cfg,
        change(:insert, "orders", record: %{"id" => "o1", "note" => "live"}, lsn: 10, ordinal: 0)
      )

      Apply.apply_change(
        cfg,
        change(:delete, "orders",
          old_record: %{"id" => "o1", "note" => "live"},
          lsn: 11,
          ordinal: 0
        )
      )

      # The insert event SURVIVES: an append log never modifies or removes a
      # stored event, so a delete is one more row, not a retraction.
      assert [%{operation: "insert", id: "o1"}, deleted] = events()
      assert %{operation: "delete", id: "o1", note: "live"} = deleted
    end

    test "a TRUNCATE under on_truncate :append is a STRUCTURAL event carrying no payload" do
      cfg = config()

      Apply.apply_change(
        cfg,
        change(:insert, "orders", record: %{"id" => "o1", "note" => "n"}, lsn: 10, ordinal: 0)
      )

      Apply.apply_change(cfg, change(:truncate, "orders", lsn: 11, ordinal: 0))

      assert [%{operation: "insert"}, truncate] = events()

      assert %{operation: "truncate", origin: "stream", id: nil, note: nil, body: nil} = truncate
    end

    test "a TRUNCATE under on_truncate :halt still halts fail-closed" do
      cfg = config()

      assert_raise Error, fn ->
        Apply.apply_change(
          cfg,
          change(:truncate, "tenant_orders", lsn: 11, ordinal: 0)
        )
      end
    end

    test "a SNAPSHOT row carries origin \"snapshot\" and the checkpoint-owned attempt" do
      attempt = :crypto.strong_rand_bytes(32)
      cfg = Map.put(config(), :append_snapshot_attempt, attempt)

      Apply.apply_change(
        cfg,
        change(:snapshot, "orders", record: %{"id" => "o1", "note" => "n"}, lsn: 10, ordinal: 3)
      )

      assert [
               %{operation: "snapshot", origin: "snapshot", snapshot_attempt: ^attempt, id: "o1"}
             ] = events()
    end

    test "transactional and standalone messages append explicit immutable events" do
      cfg = config()

      Append.apply_message(
        cfg,
        message(<<0, 1, 2>>, transactional?: true, lsn: 99, ordinal: 1),
        message_route(),
        100
      )

      Append.apply_message(
        cfg,
        message(<<3, 4, 5>>, lsn: 110),
        message_route(),
        nil
      )

      assert [transactional, standalone] = events()

      assert %{
               operation: "message",
               origin: "stream",
               commit_lsn: 100,
               ordinal: 1,
               message_prefix: "events",
               message_content: <<0, 1, 2>>
             } = transactional

      assert %{
               operation: "message",
               origin: "stream",
               commit_lsn: 110,
               ordinal: 0,
               message_prefix: "events",
               message_content: <<3, 4, 5>>
             } = standalone
    end

    test "a duplicate message identity appends once and never overwrites its content" do
      cfg = config()
      original = message("first", lsn: 110)

      Append.apply_message(cfg, original, message_route(), nil)
      Append.apply_message(cfg, original, message_route(), nil)
      Append.apply_message(cfg, message("tampered", lsn: 110), message_route(), nil)

      assert [%{message_content: "first"}] = events()
    end
  end

  describe "batch composition" do
    test "rows and transactional messages share one ordinal space and one trailing checkpoint" do
      generation =
        AdmittedGeneration.put!(AppendSink,
          source_identity: %{system_identifier: @system, database: @database}
        )

      on_exit(fn -> :persistent_term.erase({AshReplicant, @slot}) end)

      identity = %Replicant.SessionIdentity{
        system_identifier: @system,
        timeline_id: 1,
        current_lsn: 0,
        database: @database
      }

      assert :ok =
               AppendSink.handle_session_identity(identity, %{
                 slot_name: @slot,
                 publication: generation.publication
               })

      assert :ok = AppendSink.handle_slot_origin(650, %{slot_name: @slot, reused?: false})

      first = %Replicant.Transaction{
        commit_lsn: 700,
        changes: [
          change(:insert, "orders", record: %{"id" => "a"}, lsn: 700, ordinal: 0)
        ],
        messages: [message("between", transactional?: true, lsn: 699, ordinal: 1)]
      }

      second = %Replicant.Transaction{
        commit_lsn: 710,
        changes: [
          change(:insert, "orders", record: %{"id" => "b"}, lsn: 710, ordinal: 0)
        ],
        messages: []
      }

      assert {:ok, 710} = AppendSink.handle_batch([first, second])

      assert [
               %{operation: "insert", commit_lsn: 700, ordinal: 0, id: "a"},
               %{
                 operation: "message",
                 commit_lsn: 700,
                 ordinal: 1,
                 message_content: "between"
               },
               %{operation: "insert", commit_lsn: 710, ordinal: 0, id: "b"}
             ] = events()

      checkpoint_query =
        Ash.Query.filter(AshReplicant.Test.Checkpoint, slot_name == ^@slot)

      assert [%{commit_lsn: 710}] = Ash.read!(checkpoint_query, authorize?: false)
    end
  end

  describe "atomic identity (ADR-0018 §3)" do
    test "the appended identity is exactly source system, database, slot, LSN and ordinal" do
      Apply.apply_change(
        config(),
        change(:insert, "orders", record: %{"id" => "o1"}, lsn: 42, ordinal: 7)
      )

      assert %{rows: [[@system, @database, @slot, 42, 7]]} =
               SQL.query!(
                 AshReplicant.TestRepo,
                 "SELECT source_system_id, source_database, slot_name, commit_lsn, ordinal " <>
                   "FROM order_events",
                 []
               )
    end

    test "distinct same-transaction effects never overwrite one another" do
      cfg = config()

      for ordinal <- 0..2 do
        Apply.apply_change(
          cfg,
          change(:insert, "orders",
            record: %{"id" => "o#{ordinal}", "note" => "n#{ordinal}"},
            lsn: 10,
            ordinal: ordinal
          )
        )
      end

      assert ["o0", "o1", "o2"] = events() |> Enum.map(& &1.id)
    end

    test "a duplicate delivery appends ONCE and never overwrites the stored event" do
      cfg = config()

      original =
        change(:insert, "orders", record: %{"id" => "o1", "note" => "first"}, lsn: 10, ordinal: 0)

      Apply.apply_change(cfg, original)
      assert [%{event_id: event_id, note: "first"}] = events()

      # The same WAL position re-delivered — a lawful redo after a crash. It
      # must be a durable no-op, not a second row and not a mutation of the
      # stored one, or the log stops being immutable.
      Apply.apply_change(cfg, original)

      # ...and re-delivered carrying a DIFFERENT payload, which is what a
      # payload-overwriting conflict clause would let through silently.
      Apply.apply_change(
        cfg,
        change(:insert, "orders",
          record: %{"id" => "o1", "note" => "tampered"},
          lsn: 10,
          ordinal: 0
        )
      )

      assert [%{event_id: ^event_id, note: "first"}] = events()
    end
  end

  describe "tenancy and classification reuse the state-mirror rules (ADR-0018 §6)" do
    test "a tenant-scoped append writes under the per-row resolved tenant" do
      cfg = config()

      Apply.apply_change(
        cfg,
        change(:insert, "tenant_orders",
          record: %{"id" => "t1", "org_id" => "org_a", "note" => "a"},
          lsn: 10,
          ordinal: 0
        )
      )

      assert [%{id: "t1", org_id: "org_a"}] =
               events(TenantOrderEvent, tenant: "org_a")

      assert [] = events(TenantOrderEvent, tenant: "org_b")
    end

    test "a DELETE resolves the tenant from the admitted old record" do
      cfg = config()

      Apply.apply_change(
        cfg,
        change(:delete, "tenant_orders",
          old_record: %{"id" => "t1", "org_id" => "org_a", "note" => "a"},
          lsn: 10,
          ordinal: 0
        )
      )

      assert [%{operation: "delete", id: "t1"}] = events(TenantOrderEvent, tenant: "org_a")
    end

    test "an unresolvable tenant fails closed BEFORE any append" do
      cfg = config()

      assert_raise Error, fn ->
        Apply.apply_change(
          cfg,
          change(:insert, "tenant_orders",
            record: %{"id" => "t1", "org_id" => nil, "note" => "a"},
            lsn: 10,
            ordinal: 0
          )
        )
      end

      assert %{rows: [[0]]} =
               SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM tenant_order_events", [])
    end

    test "a sensitive payload column is stored encrypted, never as plaintext" do
      cfg = config()

      Apply.apply_change(
        cfg,
        change(:insert, "secret_orders",
          record: %{"id" => "s1", "pan" => "4111111111111111"},
          lsn: 10,
          ordinal: 0
        )
      )

      # `pan` is AshCloak's decrypt calculation over `encrypted_pan`; loading it
      # proves the ROUND TRIP, not merely that some bytes landed.
      assert [%SecretEvent{pan: "4111111111111111"}] = events(SecretEvent, load: [:pan])

      assert %{rows: [[ciphertext]]} =
               SQL.query!(
                 AshReplicant.TestRepo,
                 "SELECT encrypted_pan FROM secret_order_events",
                 []
               )

      assert is_binary(ciphertext)
      refute ciphertext =~ "4111111111111111"
    end
  end

  describe "value-free halts" do
    test "an append failure carries a structural reason, never a row value" do
      cfg = config()

      error =
        assert_raise Error, fn ->
          Apply.apply_change(
            cfg,
            change(:insert, "tenant_orders",
              record: %{"id" => "t1", "org_id" => nil, "note" => "sensitive-note-value"},
              lsn: 10,
              ordinal: 0
            )
          )
        end

      rendered = Exception.message(error)
      refute rendered =~ "sensitive-note-value"
      refute rendered =~ "t1"
      assert error.reason == :tenant_required
    end
  end

  # The structural-collision fixture: `append_origin_attribute :note` is a
  # perfectly legal declaration (`:note` is string-storage, so the verifier
  # admits it), but `note` is ALSO a mapped source column of `orders`. At
  # delivery the structural stamp and the payload would land on one attribute
  # and the event would carry neither fact honestly. The verifier cannot see
  # this — it does not know the live source columns — so the guard lives at
  # delivery and this is what drives it.
  defmodule CollidingDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.AppendTest.CollidingEvent
    end
  end

  defmodule CollidingEvent do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.AppendTest.CollidingDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "order_events"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("orders")
      append_log(true)
      append_origin_attribute(:note)
    end

    attributes do
      uuid_primary_key :event_id
      attribute :source_system_id, :string, allow_nil?: false, public?: true
      attribute :source_database, :string, allow_nil?: false, public?: true
      attribute :slot_name, :string, allow_nil?: false, public?: true
      attribute :commit_lsn, :integer, allow_nil?: false, public?: true
      attribute :ordinal, :integer, allow_nil?: false, public?: true
      attribute :operation, :string, allow_nil?: false, public?: true
      attribute :snapshot_attempt, :binary, public?: true
      attribute :id, :string, public?: true
      attribute :note, :string, public?: true
    end

    identities do
      identity :append_identity, [
        :source_system_id,
        :source_database,
        :slot_name,
        :commit_lsn,
        :ordinal
      ]
    end

    actions do
      defaults [:read]

      create :append do
        accept [
          :source_system_id,
          :source_database,
          :slot_name,
          :commit_lsn,
          :ordinal,
          :operation,
          :snapshot_attempt,
          :id,
          :note
        ]
      end
    end
  end

  describe "a structural attribute colliding with a mapped source column" do
    test "fails closed before any append rather than silently overwriting one of them" do
      {:ok, index} = AshReplicant.Resolver.build_index([AshReplicant.AppendTest.CollidingDomain])

      cfg = %{
        resolver_index: index,
        repo: AshReplicant.TestRepo,
        authorize?: false,
        slot_name: @slot,
        source_identity: %{system_identifier: @system, database: @database}
      }

      error =
        assert_raise Error, fn ->
          Apply.apply_change(
            cfg,
            change(:insert, "orders",
              record: %{"id" => "o1", "note" => "n1"},
              lsn: 10,
              ordinal: 0
            )
          )
        end

      assert error.reason == :config_invalid

      assert %{rows: [[0]]} =
               SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM order_events", [])
    end
  end
end
