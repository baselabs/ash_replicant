defmodule AshReplicant.SinkTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Sink.Impl
  alias AshReplicant.Test.{AdmittedGeneration, Checkpoint, Order}

  defmodule TestSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: Checkpoint,
      slot_name: "sink_test_slot"
  end

  setup do
    AdmittedGeneration.put!(TestSink)

    on_exit(fn ->
      :persistent_term.erase({AshReplicant, "sink_test_slot"})
    end)

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

  test "removed or unknown sink options fail compilation instead of silently dropping" do
    # `apply_ledger` was removed this slice; a host upgrading across it must get a
    # compile-time failure, not a silently-gone ledger.
    assert_raise ArgumentError, ~r/apply_ledger/, fn ->
      Code.compile_string("""
      defmodule AshReplicant.Test.LegacyLedgerOptionSink do
        use AshReplicant.Sink,
          repo: AshReplicant.TestRepo,
          domains: [AshReplicant.Test.Domain],
          checkpoint_resource: AshReplicant.Test.Checkpoint,
          slot_name: "legacy_ledger_option_slot",
          apply_ledger: :removed_table
      end
      """)
    end

    assert_raise ArgumentError, ~r/:typo_option/, fn ->
      Code.compile_string("""
      defmodule AshReplicant.Test.TypoOptionSink do
        use AshReplicant.Sink,
          repo: AshReplicant.TestRepo,
          domains: [AshReplicant.Test.Domain],
          checkpoint_resource: AshReplicant.Test.Checkpoint,
          slot_name: "typo_option_slot",
          typo_option: true
      end
      """)
    end
  end

  test "a callback defined BEFORE use cannot bypass the finality guard" do
    # @on_definition only fires for definitions AFTER the attribute is set — an
    # earlier-defined clause would win dispatch and skip the generation guard,
    # activation lock, and dynamic-repo pin. The attribute is registered first
    # inside __using__, so this must fail compilation.
    assert_raise CompileError, ~r/handle_transaction\/1 is final/, fn ->
      Code.compile_string("""
      defmodule AshReplicant.Test.PreUseCallbackSink do
        def handle_transaction(txn) do
          {:ok, txn.commit_lsn}
        end

        use AshReplicant.Sink,
          repo: AshReplicant.TestRepo,
          domains: [AshReplicant.Test.Domain],
          checkpoint_resource: AshReplicant.Test.Checkpoint,
          slot_name: "pre_use_callback_slot"
      end
      """)
    end
  end

  test "a transaction at or below the checkpoint is skipped — zero changes applied" do
    assert {:ok, 100} = TestSink.handle_transaction(txn(100, [ins("1")]))
    assert {:ok, 100} = TestSink.handle_transaction(txn(100, [ins("999")]))
    assert Ash.get!(Order, "999", authorize?: false, error?: false) == nil
  end

  test "an internal context override is rejected before any mapped effect" do
    generation = :persistent_term.get({AshReplicant, "sink_test_slot"})

    config =
      generation.sink_config
      |> Map.merge(%{
        sink: generation.sink,
        resolver_index: generation.resolver_index,
        destination_manifest: generation.manifest,
        source_identity: generation.source_identity,
        publication: generation.publication,
        generation: generation.reference,
        dynamic_repo: generation.dynamic_repo,
        authorize?: false,
        data_layer_context: %{repo: AshReplicant.Test.DestinationFixtures.ForeignRepo}
      })

    assert {:error, %AshReplicant.Error{reason: :config_invalid}} =
             Impl.handle_transaction(config, txn(150, [ins("foreign-context")]))

    assert Ash.get!(Order, "foreign-context", authorize?: false, error?: false) == nil
    assert {:ok, nil} = TestSink.checkpoint()
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
    assert meta.error_class == :invalid
    refute inspect(meta) =~ "SECRET_4111"

    :telemetry.detach(ref)
  end

  # Spec §Telemetry: the :applied event carries change_count + duration measurements
  # and a value-free commit_lsn. change_count is counted DURING the single pass
  # (Enum.reduce), never a re-enumeration.
  test ":applied telemetry carries change_count + duration measurements and commit_lsn" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :applied]])

    assert {:ok, 210} = TestSink.handle_transaction(txn(210, [ins("a1"), ins("a2")]))

    assert_received {[:ash_replicant, :sink, :applied], ^ref, measurements, meta}
    assert measurements.change_count == 2
    assert is_integer(measurements.duration)
    assert meta.commit_lsn == 210

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
