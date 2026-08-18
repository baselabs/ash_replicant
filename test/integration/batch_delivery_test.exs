defmodule AshReplicant.BatchMarqueeSink do
  @moduledoc false
  # C2's own marquee sink: the SCD1 mirror + message routing surface of the
  # C1 fixtures under a DEDICATED slot, so the batch tiers never share
  # durable state (checkpoint row, replication slot) with the C1 files.
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.Marquee.Domain, AshReplicant.Test.Messages.Domain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "batch_marquee_slot",
    message_routes: [
      {"outbox", AshReplicant.Test.Messages.Outbox, :record},
      {"peer", AshReplicant.Test.Messages.PeerOutbox, :record}
    ],
    ignored_message_prefixes: ["noise"]
end

defmodule AshReplicant.BatchTenantOrder do
  @moduledoc false
  # C2's own tenant fixture (the B4 shape): per-row tenant resolution under
  # `strategy :attribute`, so a mixed-tenant batch proves the per-record
  # apply path inside ONE batch envelope.
  use Ash.Resource,
    domain: AshReplicant.BatchTenantDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "batch_tenant_mirror_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("batch_tenant_orders")
    tenant_attribute(:org_id)
  end

  # Required by ValidateMultitenancy (Critical Rule 2): the per-row tenant
  # the sink passes as `tenant:` is honored by Ash only under declared
  # multitenancy.
  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :org_id, :string, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.BatchTenantDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.BatchTenantOrder
  end
end

defmodule AshReplicant.BatchTenantSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.BatchTenantDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "batch_tenant_slot"
end

defmodule AshReplicant.BatchOnceChanges do
  @moduledoc false
  # A single-pass Enumerable standing in for a spilled transaction's lazy
  # Reader: re-enumeration raises (the spill file is gone after one pass).
  # The batch body must consume it exactly once — a materializing call
  # (`Enum.count`/`length`-via-protocol, a second `Enum.reduce`) trips the
  # spent flag and this fixture goes red.
  defstruct [:key, :changes]

  def new(changes) do
    key = {__MODULE__, :spent, System.unique_integer([:positive])}
    :persistent_term.put(key, false)
    %__MODULE__{key: key, changes: changes}
  end

  def spent?(%__MODULE__{key: key}), do: :persistent_term.get(key, true)
end

defimpl Enumerable, for: AshReplicant.BatchOnceChanges do
  def count(_once), do: {:error, __MODULE__}
  def member?(_once, _value), do: {:error, __MODULE__}
  def slice(_once), do: {:error, __MODULE__}

  def reduce(%{key: key} = once, acc, fun) do
    if :persistent_term.get(key, false) do
      raise "single-pass batch stream re-enumerated"
    end

    :persistent_term.put(key, true)
    reduce_list(once.changes, acc, fun)
  end

  defp reduce_list(_items, {:halt, acc}, _fun), do: {:halted, acc}

  defp reduce_list([], {:cont, acc}, _fun), do: {:done, acc}

  defp reduce_list([head | tail], {command, acc}, fun) do
    case command do
      :cont -> reduce_list(tail, fun.(head, acc), fun)
      :suspend -> {:suspended, acc, &reduce_list(tail, &1, fun)}
    end
  end
end

defmodule AshReplicant.BatchDeliveryTest do
  @moduledoc """
  C2 direct-drive tier: `handle_batch/1` exercised through the generated
  sink's callback against the live destination (sandbox-owned), with the
  generation admitted directly — every acceptance cell that does not need
  the wire. The pipeline tier (`BatchPipelineTest`, below) proves the live
  batched stream.
  """

  use AshReplicant.DataCase, async: false
  @moduletag :integration

  alias AshReplicant.BatchMarqueeSink
  alias AshReplicant.BatchOnceChanges
  alias AshReplicant.BatchTenantSink
  alias AshReplicant.Test.{AdmittedGeneration, DestinationObserver, Marquee, Messages}
  alias Ecto.Adapters.SQL

  @slot "batch_marquee_slot"
  @scd2_slot "marquee_scd2_slot"

  setup do
    Marquee.setup_schema!()
    Messages.setup_schema!()

    generation = AdmittedGeneration.put!(BatchMarqueeSink)

    identity = %Replicant.SessionIdentity{
      system_identifier: generation.source_identity.system_identifier,
      timeline_id: 1,
      current_lsn: 0,
      database: generation.source_identity.database
    }

    BatchMarqueeSink.handle_session_identity(identity, %{
      slot_name: @slot,
      publication: generation.publication
    })

    run_id = "c2-direct-#{System.unique_integer([:positive])}"

    DestinationObserver.setup!(run_id, observer_triggers())

    on_exit(fn ->
      :persistent_term.erase({AshReplicant, @slot})

      AshReplicant.TestRepo.query!(
        "DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [@slot]
      )
    end)

    {:ok, generation: generation, run_id: run_id}
  end

  defp observer_triggers do
    [
      %{table: Marquee.mirror(), participant: "mapped", operations: [:insert]},
      %{table: Messages.outbox(), participant: "message_local", operations: [:insert]},
      %{
        table: "ash_replicant_checkpoints",
        participant: "checkpoint",
        operations: [:insert, :update],
        commit_lsn_column: "commit_lsn"
      }
    ]
  end

  defp msg(prefix, content, lsn, opts \\ []) do
    %Replicant.Decoder.Messages.Message{
      transactional?: Keyword.get(opts, :transactional?, false),
      lsn: lsn,
      prefix: prefix,
      content: content,
      ordinal: Keyword.get(opts, :ordinal)
    }
  end

  defp txn(lsn, changes, messages \\ []) do
    %Replicant.Transaction{commit_lsn: lsn, changes: changes, messages: messages}
  end

  defp ins(id, ordinal, lsn),
    do: %Replicant.Change{
      op: :insert,
      schema: "public",
      table: Marquee.src(),
      record: %{"id" => id, "note" => "n"},
      commit_lsn: lsn,
      ordinal: ordinal
    }

  defp upd(id, note, ordinal, lsn),
    do: %Replicant.Change{
      op: :update,
      schema: "public",
      table: Marquee.src(),
      record: %{"id" => id, "note" => note},
      old_record: %{"id" => id},
      commit_lsn: lsn,
      ordinal: ordinal
    }

  defp outbox_contents,
    do: Messages.rows(Messages.outbox()) |> Enum.map(&Enum.at(&1, 0))

  defp checkpoint_lsn(slot \\ @slot) do
    [[lsn]] =
      SQL.query!(
        AshReplicant.TestRepo,
        "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [slot]
      ).rows

    lsn
  end

  describe "one destination transaction, ascending, with the message interleave" do
    test "ascending transactions and all messages apply in ONE transaction with a single trailing watermark",
         %{
           run_id: run_id
         } do
      first =
        txn(700, [ins("a", 0, 700), ins("b", 2, 700)], [
          msg("outbox", "between", 701, ordinal: 1, transactional?: true)
        ])

      second = txn(710, [ins("c", 0, 710)])

      assert {:ok, 710} = BatchMarqueeSink.handle_batch([first, second])

      assert outbox_contents() == ["between"]
      assert Marquee.mirror_rows() == [["a", "n"], ["b", "n"], ["c", "n"]]

      # ONE checkpoint write, physically LAST — after every row and message
      # effect of the whole batch.
      participants = Enum.map(DestinationObserver.rows(run_id), & &1.participant)

      assert participants == ["mapped", "message_local", "mapped", "mapped", "checkpoint"]
      assert checkpoint_lsn() == 710
    end

    test "a row's lifecycle across batched transactions keeps source order" do
      first = txn(700, [ins("x", 0, 700)])
      second = txn(710, [upd("x", "second-value", 0, 710)])

      assert {:ok, 710} = BatchMarqueeSink.handle_batch([first, second])
      assert Marquee.mirror_rows() == [["x", "second-value"]]
    end

    test "telemetry counts one pass" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:ash_replicant, :sink, :batch_applied],
          [:ash_replicant, :sink, :applied]
        ])

      first =
        txn(700, [ins("a", 0, 700)], [msg("outbox", "m1", 701, ordinal: 1, transactional?: true)])

      second = txn(710, [ins("b", 0, 710), ins("c", 1, 710)])

      assert {:ok, 710} = BatchMarqueeSink.handle_batch([first, second])

      assert_received {[:ash_replicant, :sink, :batch_applied], ^ref, measurements, meta}
      assert measurements.change_count == 4
      assert is_integer(measurements.duration) and measurements.duration >= 0
      assert meta.commit_lsn == 710
      assert meta.txn_count == 2

      refute_received {[:ash_replicant, :sink, :applied], ^ref, _, _},
                      "batch delivery must not also fire the per-transaction applied event"

      :telemetry.detach(ref)
    end
  end

  describe "the watermark skip" do
    test "re-delivering the committed batch is a whole-batch skip with zero new effects", %{
      run_id: run_id
    } do
      ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :skipped]])

      batch = [txn(700, [ins("a", 0, 700)]), txn(710, [ins("b", 0, 710)])]

      assert {:ok, 710} = BatchMarqueeSink.handle_batch(batch)
      rows_after_apply = DestinationObserver.rows(run_id)

      assert {:ok, 710} = BatchMarqueeSink.handle_batch(batch)

      assert DestinationObserver.rows(run_id) == rows_after_apply,
             "the re-delivered batch must leave zero new physical effects"

      assert_received {[:ash_replicant, :sink, :skipped], ^ref, _measurements, meta}
      assert meta.commit_lsn == 710
      assert meta.txn_count == 2
      :telemetry.detach(ref)

      assert Marquee.mirror_rows() == [["a", "n"], ["b", "n"]]
      assert checkpoint_lsn() == 710
    end

    test "only frontiers at/below the checkpoint skip — later transactions in the same batch apply" do
      assert {:ok, 700} = BatchMarqueeSink.handle_batch([txn(700, [ins("seed", 0, 700)])])

      stale = txn(690, [ins("old", 0, 690)])
      fresh = txn(710, [ins("new", 0, 710)])

      assert {:ok, 710} = BatchMarqueeSink.handle_batch([stale, fresh])

      assert Marquee.mirror_rows() == [["new", "n"], ["seed", "n"]]
      assert checkpoint_lsn() == 710
    end
  end

  describe "fault containment" do
    test "a mid-batch failing change rolls back every transaction's effects and advances nothing",
         %{
           run_id: run_id
         } do
      good =
        txn(700, [ins("a", 0, 700)], [
          msg("outbox", "rolled-back", 701, ordinal: 1, transactional?: true)
        ])

      bad_change = %Replicant.Change{
        op: :insert,
        schema: "public",
        table: Marquee.src(),
        record: %{"note" => "SECRET_4111"},
        commit_lsn: 710,
        ordinal: 0
      }

      bad = txn(710, [ins("b", 1, 710), bad_change])

      rows_before = DestinationObserver.rows(run_id)

      assert {:error, %AshReplicant.Error{} = error} =
               BatchMarqueeSink.handle_batch([good, bad])

      # Value-free: the poisoned row value never renders.
      refute inspect(error) =~ "SECRET_4111"
      refute Exception.message(error) =~ "SECRET_4111"

      assert DestinationObserver.rows(run_id) == rows_before,
             "a mid-batch fault must leave zero net partial effects"

      assert outbox_contents() == []
      assert Marquee.mirror_rows() == []

      assert [[nil]] =
               SQL.query!(
                 AshReplicant.TestRepo,
                 "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
                 [@slot]
               ).rows
    end

    test "an unmapped transactional-message prefix halts the whole batch fail-closed" do
      poisoned =
        txn(700, [ins("a", 0, 700)], [
          msg("evil", "x", 701, ordinal: 1, transactional?: true)
        ])

      assert {:error, %AshReplicant.Error{reason: :message_prefix_unmapped}} =
               BatchMarqueeSink.handle_batch([poisoned, txn(710, [ins("b", 0, 710)])])

      assert outbox_contents() == []
      assert Marquee.mirror_rows() == []
    end
  end

  describe "lazy spilled streams" do
    test "a single-pass changes stream is enumerated exactly once and never materialized" do
      changes = BatchOnceChanges.new([ins("a", 0, 700), ins("b", 1, 700)])

      assert {:ok, 700} = BatchMarqueeSink.handle_batch([txn(700, changes)])

      assert Marquee.mirror_rows() == [["a", "n"], ["b", "n"]]
      assert BatchOnceChanges.spent?(changes)
    end
  end

  describe "defensive shape" do
    test "an empty batch is a no-op returning no frontier (the framework never sends one)" do
      assert {:ok, nil} = BatchMarqueeSink.handle_batch([])
      assert Marquee.mirror_rows() == []
      assert checkpoint_lsn() == nil
    end
  end

  describe "mixed destinations" do
    test "an SCD2 batch opens and closes version windows across transactions with one trailing watermark" do
      Marquee.setup_scd2_schema!()

      generation = AdmittedGeneration.put!(Marquee.Scd2Sink)

      identity = %Replicant.SessionIdentity{
        system_identifier: generation.source_identity.system_identifier,
        timeline_id: 1,
        current_lsn: 0,
        database: generation.source_identity.database
      }

      Marquee.Scd2Sink.handle_session_identity(identity, %{
        slot_name: @scd2_slot,
        publication: generation.publication
      })

      on_exit(fn ->
        :persistent_term.erase({AshReplicant, @scd2_slot})

        AshReplicant.TestRepo.query!(
          "DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1",
          [@scd2_slot]
        )
      end)

      scd2_ins = fn id, amount, ordinal, lsn ->
        %Replicant.Change{
          op: :insert,
          schema: "public",
          table: Marquee.scd2_src(),
          record: %{"order_id" => id, "amount" => amount},
          commit_lsn: lsn,
          ordinal: ordinal
        }
      end

      scd2_upd = fn id, amount, ordinal, lsn ->
        %Replicant.Change{
          op: :update,
          schema: "public",
          table: Marquee.scd2_src(),
          record: %{"order_id" => id, "amount" => amount},
          old_record: %{"order_id" => id},
          commit_lsn: lsn,
          ordinal: ordinal
        }
      end

      assert {:ok, 200} =
               Marquee.Scd2Sink.handle_batch([
                 txn(100, [scd2_ins.("o1", "10", 0, 100)]),
                 txn(200, [scd2_upd.("o1", "20", 0, 200)])
               ])

      [v1, v2] = Marquee.scd2_versions("o1")

      assert v1.from < v1.to
      assert v1.to == v2.from
      assert v1.amount == "10"
      assert v2.amount == "20"
      assert is_nil(v2.to)
      assert v2.current

      assert checkpoint_lsn(@scd2_slot) == 200
    end

    test "a mixed-tenant batch applies per-record under each row's resolved tenant" do
      Marquee.q!("DROP TABLE IF EXISTS batch_tenant_mirror_orders")

      Marquee.q!(
        "CREATE TABLE batch_tenant_mirror_orders (id text primary key, org_id text, note text)"
      )

      on_exit(fn ->
        :persistent_term.erase({AshReplicant, "batch_tenant_slot"})
        Marquee.q!("DROP TABLE IF EXISTS batch_tenant_mirror_orders")

        AshReplicant.TestRepo.query!(
          "DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1",
          ["batch_tenant_slot"]
        )
      end)

      generation = AdmittedGeneration.put!(BatchTenantSink)

      identity = %Replicant.SessionIdentity{
        system_identifier: generation.source_identity.system_identifier,
        timeline_id: 1,
        current_lsn: 0,
        database: generation.source_identity.database
      }

      BatchTenantSink.handle_session_identity(identity, %{
        slot_name: "batch_tenant_slot",
        publication: generation.publication
      })

      tenant_ins = fn id, org, ordinal, lsn ->
        %Replicant.Change{
          op: :insert,
          schema: "public",
          table: "batch_tenant_orders",
          record: %{"id" => id, "org_id" => org, "note" => "n"},
          commit_lsn: lsn,
          ordinal: ordinal
        }
      end

      assert {:ok, 710} =
               BatchTenantSink.handle_batch([
                 txn(700, [tenant_ins.("a", "org-one", 0, 700)]),
                 txn(710, [tenant_ins.("b", "org-two", 0, 710)])
               ])

      assert Marquee.q!("SELECT id, org_id FROM batch_tenant_mirror_orders ORDER BY id").rows ==
               [["a", "org-one"], ["b", "org-two"]]

      assert checkpoint_lsn("batch_tenant_slot") == 710
    end
  end
end

defmodule AshReplicant.BatchPipelineTest do
  @moduledoc """
  C2 pipeline tier: the live logical-replication stream under
  `batch_delivery` — the count-cap flush boundary, the adapter's one-pass
  telemetry, the §8.4 standalone-message flush-before-delivery composition,
  and a live mid-batch fault leaving zero net effects and a frozen watermark.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.BatchMarqueeSink
  alias AshReplicant.Test.{DestinationObserver, Marquee, Messages, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "batch_marquee_slot"

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()
    Messages.setup_schema!()

    run_id = "c2-pipeline-#{System.unique_integer([:positive])}"
    DestinationObserver.setup!(run_id, observer_triggers())

    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.q!("ALTER TABLE #{Marquee.mirror()} DROP CONSTRAINT IF EXISTS tmp_poison")
      DestinationObserver.teardown!(observer_triggers())
      Messages.reset_peer!()
    end)

    {:ok, run_id: run_id}
  end

  defp observer_triggers do
    [
      %{table: Marquee.mirror(), participant: "mapped", operations: [:insert]},
      %{table: Messages.outbox(), participant: "message_local", operations: [:insert]},
      %{
        table: "ash_replicant_checkpoints",
        participant: "checkpoint",
        operations: [:insert, :update],
        commit_lsn_column: "commit_lsn"
      }
    ]
  end

  defp start!(batch_delivery) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _meta, _config -> send(test_pid, {:slot_active, ref}) end,
      nil
    )

    {:ok, _pid} =
      AshReplicant.start_link(
        sink: BatchMarqueeSink,
        connection: Marquee.conn(),
        publication: Marquee.publication(),
        source_identity: Marquee.source_identity(),
        go_forward_only: true,
        batch_delivery: batch_delivery
      )

    receive do
      {:slot_active, ^ref} -> :ok
    after
      15_000 -> flunk("pipeline never reached slot_active for #{@slot}")
    end

    :telemetry.detach({__MODULE__, ref})
  end

  defp emit_row(id, note) do
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ($1, $2)", [id, note])
  end

  defp mirror_notes,
    do: Marquee.q!("SELECT note FROM #{Marquee.mirror()} ORDER BY id").rows |> List.flatten()

  defp checkpoint_value do
    [[lsn]] =
      Marquee.q!("SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1", [
        @slot
      ]).rows

    lsn
  end

  test "the count-cap boundary flushes batches of the configured size with one-pass telemetry" do
    batch_ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:replicant, :sink, :batch_committed],
        [:ash_replicant, :sink, :batch_applied]
      ])

    start!(max_transactions: 2, max_delay_ms: 10_000)

    for i <- 1..4, do: emit_row("k#{i}", "v#{i}")

    PG.wait_until(fn -> length(mirror_notes()) == 4 end, 2_000)

    # Two count-cap flushes of two transactions each — never a per-transaction
    # delivery — and the adapter's event counts ONE pass per flush.
    assert_received {[:replicant, :sink, :batch_committed], ^batch_ref, _, framework_meta_a}
    assert framework_meta_a.change_count == 2
    assert framework_meta_a.reason == :max_transactions

    assert_received {[:ash_replicant, :sink, :batch_applied], ^batch_ref, measurements, meta}
    assert measurements.change_count == 2
    assert meta.txn_count == 2

    assert_received {[:replicant, :sink, :batch_committed], ^batch_ref, _, framework_meta_b}
    assert framework_meta_b.change_count == 2

    assert_received {[:ash_replicant, :sink, :batch_applied], ^batch_ref, _, adapter_meta_b}
    assert adapter_meta_b.txn_count == 2

    refute_received {[:replicant, :sink, :batch_committed], ^batch_ref, _, _}
    refute_received {[:ash_replicant, :sink, :batch_applied], ^batch_ref, _, _}
    :telemetry.detach(batch_ref)

    assert mirror_notes() == ["v1", "v2", "v3", "v4"]
    assert is_integer(checkpoint_value()) and checkpoint_value() > 0
  end

  test "a standalone message arriving mid-batch flushes the batch before it delivers (§8.4)" do
    events =
      :telemetry_test.attach_event_handlers(self(), [
        [:ash_replicant, :sink, :batch_applied],
        [:ash_replicant, :message, :applied]
      ])

    start!(max_transactions: 100, max_delay_ms: 60_000)

    emit_row("held", "held-value")

    Marquee.q!("SELECT pg_logical_emit_message(false, 'outbox', 'mid-batch')")

    PG.wait_until(
      fn ->
        Enum.map(Messages.rows(Messages.outbox()), &Enum.at(&1, 0)) == ["mid-batch"]
      end,
      2_000
    )

    # The batch flush precedes the standalone message's delivery — the
    # §8.4 durability-before-ack boundary (transport-owned; the composition
    # is what C2 proves).
    assert_received {[:ash_replicant, :sink, :batch_applied], ^events, _, batch_meta}
    assert batch_meta.txn_count == 1

    assert_received {[:ash_replicant, :message, :applied], ^events, _, message_meta}
    assert message_meta.transactional == false

    :telemetry.detach(events)

    assert mirror_notes() == ["held-value"]
  end

  test "a live mid-batch write fault halts fail-closed with zero net effects and a frozen watermark" do
    halt_ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :halted]])

    Marquee.q!(
      "ALTER TABLE #{Marquee.mirror()} ADD CONSTRAINT tmp_poison CHECK (note <> 'POISON')"
    )

    start!(max_transactions: 2, max_delay_ms: 10_000)

    emit_row("good", "good-value")

    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('poisoned', 'POISON')")

    PG.wait_until(
      fn ->
        receive do
          {[:ash_replicant, :sink, :halted], ^halt_ref, _, _} -> true
        after
          0 -> false
        end
      end,
      2_000
    )

    :telemetry.detach(halt_ref)

    # The whole batch — including its healthy transaction — rolled back, and
    # the watermark never advanced past the bind.
    PG.wait_until(fn -> mirror_notes() == [] end, 400)

    assert [[nil]] =
             Marquee.q!(
               "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
               [@slot]
             ).rows
  end
end
