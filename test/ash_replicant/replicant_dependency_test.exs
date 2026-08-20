defmodule AshReplicant.ReplicantDependencyTest do
  use ExUnit.Case, async: true

  alias Replicant.Snapshotter.Incremental

  defmodule SlotOriginSink do
    @behaviour Replicant.Sink

    def handle_slot_origin(origin, context) do
      send(context.test_pid, {:slot_origin, origin, Map.delete(context, :test_pid)})
      :ok
    end
  end

  defmodule RejectingSlotOriginSink do
    @behaviour Replicant.Sink

    def handle_slot_origin(_origin, _context), do: {:error, {:gap, "must-not-leak"}}
  end

  test "the resolved Hex dependency exposes the coordinated major contract" do
    assert Code.ensure_loaded?(Replicant.SessionIdentity)
    assert Code.ensure_loaded?(Replicant.Sink)
    assert Code.ensure_loaded?(Replicant.Telemetry)
    assert function_exported?(Replicant.Sink, :accept_session_identity, 3)
    assert function_exported?(Replicant.Sink, :supports_batch?, 1)
    assert function_exported?(Replicant.Sink, :supports_messages?, 1)
    assert function_exported?(Replicant.Sink, :supports_incremental_snapshot?, 1)
    assert function_exported?(Replicant.Sink, :supports_slot_origin?, 1)
    assert function_exported?(Replicant.Sink, :notify_slot_origin, 3)

    version = Application.spec(:replicant, :vsn) |> List.to_string()
    assert Version.match?(version, ">= 1.2.1 and < 2.0.0-0")

    if version == "1.2.1" do
      assert Code.ensure_loaded?(Incremental)
      assert function_exported?(Incremental, :keyed_retry_decision, 3)
    end
  end

  test "the fetched slot-origin contract is typed and fail-closed" do
    context = %{slot_name: "ash_replicant_dependency", reused?: true, test_pid: self()}

    assert Replicant.Sink.supports_slot_origin?(SlotOriginSink)
    refute Replicant.Sink.supports_slot_origin?(__MODULE__)
    assert :ok = Replicant.Sink.notify_slot_origin(SlotOriginSink, 0x16E3778, context)

    assert_receive {:slot_origin, 0x16E3778,
                    %{slot_name: "ash_replicant_dependency", reused?: true}}

    assert {:error, :slot_origin_rejected} =
             Replicant.Sink.notify_slot_origin(RejectingSlotOriginSink, 0x16E3778, context)
  end

  test "the fetched telemetry contract rejects wrong shapes without rendering values" do
    secret = "replicant-telemetry-secret"

    error =
      assert_raise ArgumentError, fn ->
        Replicant.Telemetry.event(
          [:replicant, :ash_replicant_dependency_contract],
          %{},
          %{commit_lsn: secret}
        )
      end

    message = Exception.message(error)
    assert message =~ "got type: binary"
    refute message =~ secret

    assert_raise ArgumentError, fn ->
      Replicant.Telemetry.event(
        [:replicant, :ash_replicant_dependency_contract],
        %{change_count: -1},
        %{}
      )
    end
  end

  test "the fetched keyed snapshot contract exhausts contention without charging reconnects" do
    version = Application.spec(:replicant, :vsn) |> List.to_string()

    if version != "1.2.1" do
      assert Version.match?(version, "> 1.2.1 and < 2.0.0-0")
    else
      assert_keyed_contention_contract()
    end
  end

  defp assert_keyed_contention_contract do
    table = ~s|"public"."orders"|

    assert {:retry, %{^table => 2}} =
             :erlang.apply(Incremental, :keyed_retry_decision, [%{}, table, :table_discarded])

    assert {:retry, %{^table => 3}} =
             :erlang.apply(Incremental, :keyed_retry_decision, [
               %{table => 2},
               table,
               :table_discarded
             ])

    assert :halt =
             :erlang.apply(Incremental, :keyed_retry_decision, [
               %{table => 3},
               table,
               :table_discarded
             ])

    attempts = %{table => 2}

    assert {:retry, ^attempts} =
             :erlang.apply(Incremental, :keyed_retry_decision, [attempts, table, :window_reset])
  end
end
