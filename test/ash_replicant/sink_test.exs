defmodule AshReplicant.SinkTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Sink.Impl
  alias AshReplicant.Test.{Checkpoint, Domain, Order}

  defmodule TestSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: Checkpoint,
      slot_name: "sink_test_slot"
  end

  setup do
    {:ok, index} = AshReplicant.Resolver.build_index([Domain])
    :persistent_term.put({AshReplicant, "sink_test_slot"}, index)
    on_exit(fn -> :persistent_term.erase({AshReplicant, "sink_test_slot"}) end)
    :ok
  end

  defp txn(lsn, changes), do: %Replicant.Transaction{commit_lsn: lsn, changes: changes}

  defp ins(id),
    do: %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "orders",
      record: %{"id" => id, "note" => "n"}
    }

  test "checkpoint/0 is nil before any transaction, then reflects the last commit" do
    assert {:ok, nil} = TestSink.checkpoint()
    assert {:ok, 100} = TestSink.handle_transaction(txn(100, [ins("1")]))
    assert {:ok, 100} = TestSink.checkpoint()
  end

  test "a transaction at or below the checkpoint is skipped — zero changes applied" do
    assert {:ok, 100} = TestSink.handle_transaction(txn(100, [ins("1")]))
    assert {:ok, 100} = TestSink.handle_transaction(txn(100, [ins("999")]))
    assert Ash.get!(Order, "999", authorize?: false, error?: false) == nil
  end

  test "effect-once: re-delivering the same transaction twice writes the row once, checkpoint advances once" do
    assert {:ok, 200} = TestSink.handle_transaction(txn(200, [ins("2")]))
    assert {:ok, 200} = TestSink.handle_transaction(txn(200, [ins("2")]))
    assert %Order{} = Ash.get!(Order, "2", authorize?: false)
    assert {:ok, 200} = TestSink.checkpoint()
  end

  test "a failing apply rolls back atomically (checkpoint unchanged) and returns a value-free error" do
    assert {:ok, 100} = TestSink.handle_transaction(txn(100, [ins("1")]))

    bad = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "orders",
      record: %{"note" => "SECRET_4111"}
    }

    assert {:error, %AshReplicant.Error{} = err} = TestSink.handle_transaction(txn(300, [bad]))

    refute inspect(err) =~ "SECRET_4111"
    refute Exception.message(err) =~ "SECRET_4111"
    assert {:ok, 100} = TestSink.checkpoint()
  end

  # MANDATE-B — a GENUINE single-pass test driven THROUGH the sink. `changes` is a
  # one-shot Stream whose start_fun raises if enumerated a second time. If
  # handle_transaction re-enumerated `changes` (e.g. an Enum.count for telemetry),
  # the 2nd pass would raise and the txn would fail. Proves the sink consumes a
  # spilled txn's lazy single-pass Enumerable exactly once.
  test "handle_transaction iterates the change stream exactly once (spilled single-pass safety)" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    once =
      Stream.resource(
        fn ->
          n = Agent.get_and_update(agent, &{&1, &1 + 1})
          if n > 0, do: raise("changes enumerated more than once"), else: :ok
        end,
        fn
          :ok -> {[ins("sp1")], :done}
          :done -> {:halt, :done}
        end,
        fn _ -> :ok end
      )

    assert {:ok, 400} = TestSink.handle_transaction(txn(400, once))
    assert %Order{} = Ash.get!(Order, "sp1", authorize?: false)
    assert Agent.get(agent, & &1) == 1
  end

  # MANDATE-C — failure observability. Apply.apply_change RAISES, so the raise
  # propagates OUT of repo.transaction (Ecto re-raises after rollback) and lands on
  # the function-level rescue — NOT the case-on-result {:error, %Error{}} branch.
  # This asserts :halted fires on that real raise path, value-free (reason atom only).
  test "a failing txn emits value-free :halted telemetry on the real raise path" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :halted]])

    bad = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "orders",
      record: %{"note" => "SECRET_4111"}
    }

    assert {:error, %AshReplicant.Error{}} = TestSink.handle_transaction(txn(500, [bad]))

    assert_received {[:ash_replicant, :sink, :halted], ^ref, _measurements, meta}
    assert meta.reason == :sink_failed
    refute inspect(meta) =~ "SECRET_4111"

    :telemetry.detach(ref)
  end

  test "an empty/absent resolver index fails closed (:config_invalid) — no silent loss, checkpoint not advanced" do
    empty_config = %{
      repo: AshReplicant.TestRepo,
      checkpoint_resource: Checkpoint,
      slot_name: "sink_test_slot",
      resolver_index: %{},
      authorize?: false
    }

    assert {:error, %AshReplicant.Error{reason: :config_invalid}} =
             Impl.handle_transaction(empty_config, txn(700, [ins("nope")]))

    # loss=0: the checkpoint did NOT advance and the row was NOT written.
    assert {:ok, nil} = Impl.checkpoint(empty_config)
    assert Ash.get!(Order, "nope", authorize?: false, error?: false) == nil
  end
end
