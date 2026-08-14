defmodule AshReplicant.SnapshotPipelineTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 120_000

  import ExUnit.CaptureLog

  alias AshReplicant.Test.{DestinationObserver, Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @snapshot_slot "snapshot_pipeline_slot"
  @retry_slot "snapshot_retry_slot"
  @sequence_slot "snapshot_sequence_slot"
  @retry_key {__MODULE__, :fail_second_batch}
  @retry_observer {__MODULE__, :retry_observer}
  @sequence_observer {__MODULE__, :sequence_observer}
  @sequence_trace {__MODULE__, :sequence_trace}

  defmodule SnapshotSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snapshot_pipeline_slot"
  end

  defmodule RetrySnapshotSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snapshot_retry_slot"

    defp __ash_replicant_effect__(
           :snapshot,
           [changes, %{first_for_table?: false} = context],
           config
         ) do
      if :persistent_term.get(
           {AshReplicant.SnapshotPipelineTest, :fail_second_batch},
           false
         ) do
        :persistent_term.put({AshReplicant.SnapshotPipelineTest, :fail_second_batch}, false)

        send(
          :persistent_term.get({AshReplicant.SnapshotPipelineTest, :retry_observer}),
          :snapshot_failure_injected
        )

        {:error, :injected_snapshot_failure}
      else
        super(:snapshot, [changes, context], config)
      end
    end

    defp __ash_replicant_effect__(operation, arguments, config),
      do: super(operation, arguments, config)
  end

  defmodule SequencedSnapshotSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snapshot_sequence_slot"

    defp __ash_replicant_effect__(
           :snapshot,
           [changes, %{first_for_table?: true, snapshot_lsn: snapshot_lsn} = context],
           config
         ) do
      observer = :persistent_term.get({AshReplicant.SnapshotPipelineTest, :sequence_observer})
      send(observer, {:snapshot_paused, self(), snapshot_lsn})

      receive do
        :continue_snapshot -> super(:snapshot, [changes, context], config)
      after
        15_000 -> raise "snapshot sequencing release not received"
      end
    end

    defp __ash_replicant_effect__(:snapshot_complete, [snapshot_lsn] = arguments, config) do
      result = super(:snapshot_complete, arguments, config)
      trace(:snapshot_complete)
      observer = :persistent_term.get({AshReplicant.SnapshotPipelineTest, :sequence_observer})
      send(observer, {:handoff_paused, self(), snapshot_lsn})

      receive do
        :continue_handoff -> result
      after
        15_000 -> raise "snapshot handoff release not received"
      end
    end

    defp __ash_replicant_effect__(:transaction, arguments, config) do
      trace(:transaction)
      super(:transaction, arguments, config)
    end

    defp __ash_replicant_effect__(operation, arguments, config),
      do: super(operation, arguments, config)

    defp trace(event) do
      {AshReplicant.SnapshotPipelineTest, :sequence_trace}
      |> :persistent_term.get()
      |> Agent.update(&(&1 ++ [event]))
    end
  end

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()
    run_id = "snapshot-#{System.unique_integer([:positive])}"
    DestinationObserver.setup!(run_id, observer_triggers())
    assert DestinationObserver.unconstrained?()

    for slot <- [@snapshot_slot, @retry_slot, @sequence_slot] do
      Marquee.drop_slot!(slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
    end

    :persistent_term.put(@retry_key, false)
    :persistent_term.put(@retry_observer, self())
    :persistent_term.put(@sequence_observer, self())
    {:ok, trace} = Agent.start_link(fn -> [] end)
    :persistent_term.put(@sequence_trace, trace)

    on_exit(fn ->
      for slot <- [@snapshot_slot, @retry_slot, @sequence_slot] do
        AshReplicant.stop_supervised(slot)
        Marquee.drop_slot!(slot)
        Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
      end

      :persistent_term.erase(@retry_key)
      :persistent_term.erase(@retry_observer)
      :persistent_term.erase(@sequence_observer)
      :persistent_term.erase(@sequence_trace)
      DestinationObserver.teardown!(observer_triggers())
      Marquee.teardown_schema!()
    end)

    {:ok, run_id: run_id, trace: trace}
  end

  test "v1 snapshot converges, hands off its checkpoint, and resumes ordinary streaming", %{
    run_id: run_id
  } do
    Marquee.q!("""
    INSERT INTO #{Marquee.src()} (id, note)
    SELECT g::text, 'seed-' || g::text FROM generate_series(1, 25) g
    """)

    ref = attach_snapshot_complete(@snapshot_slot)
    active_ref = attach_slot_active(@snapshot_slot)
    start_snapshot!(@snapshot_slot, SnapshotSink)

    assert_receive {:snapshot_complete, ^ref, snapshot_lsn, 25}, 15_000
    assert_receive {:slot_active, ^active_ref}, 15_000
    assert is_integer(snapshot_lsn) and snapshot_lsn > 0
    PG.wait_until(fn -> length(Marquee.mirror_rows()) == 25 end)

    assert [[^snapshot_lsn]] =
             Marquee.q!(
               "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
               [@snapshot_slot]
             ).rows

    Marquee.q!("UPDATE #{Marquee.src()} SET note = 'streamed' WHERE id = '25'")
    PG.wait_until(fn -> ["25", "streamed"] in Marquee.mirror_rows() end)

    :ok = AshReplicant.stop_supervised(@snapshot_slot)
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('26', 'after-restart')")
    restart_ref = attach_slot_active(@snapshot_slot)
    start_snapshot!(@snapshot_slot, SnapshotSink)
    assert_receive {:slot_active, ^restart_ref}, 15_000
    PG.wait_until(fn -> ["26", "after-restart"] in Marquee.mirror_rows() end)

    assert length(Marquee.mirror_rows()) == 26
    PG.wait_until(fn -> observer_checkpoint_count(run_id) == 3 end)
    assert DestinationObserver.effect_count(run_id, "mapped", "INSERT") == 26
    assert DestinationObserver.effect_count(run_id, "mapped", "UPDATE") == 1
    assert DestinationObserver.effect_count(run_id, "auxiliary", "INSERT") == 27
  end

  test "an incomplete v1 snapshot halts until operator reset and retry exposes every repeated effect",
       %{run_id: run_id} do
    Marquee.q!("""
    INSERT INTO #{Marquee.src()} (id, note)
    SELECT g::text, 'seed-' || g::text FROM generate_series(1, 1100) g
    """)

    test_pid = self()

    :telemetry.attach(
      {__MODULE__, :incomplete},
      [:replicant, :snapshot, :failed],
      fn _event, _measurements, metadata, _config ->
        if metadata[:reason] == :snapshot_incomplete,
          do: send(test_pid, :snapshot_incomplete)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, :incomplete}) end)

    capture_log(fn ->
      :persistent_term.put(@retry_key, true)
      start_snapshot!(@retry_slot, RetrySnapshotSink)

      assert_receive :snapshot_failure_injected, 60_000
      assert_receive :snapshot_incomplete, 60_000

      PG.wait_until(fn ->
        Registry.lookup(Replicant.Registry, {@retry_slot, :pipeline}) == []
      end)

      assert length(Marquee.mirror_rows()) == 1000

      :ok = AshReplicant.stop_supervised(@retry_slot)
      Marquee.drop_slot!(@retry_slot)
      start_snapshot!(@retry_slot, RetrySnapshotSink)
      PG.wait_until(fn -> length(Marquee.mirror_rows()) == 1100 end, 800)

      PG.wait_until(fn -> observer_checkpoint_count(run_id) == 1 end)
      assert DestinationObserver.effect_count(run_id, "mapped", "INSERT") == 2100
      assert DestinationObserver.effect_count(run_id, "mapped", "DELETE") == 1000
      assert DestinationObserver.effect_count(run_id, "auxiliary", "INSERT") == 2100
    end)
  end

  test "the exported snapshot point hands off before a later source write reaches the stream",
       %{run_id: run_id, trace: trace} do
    Marquee.q!("""
    INSERT INTO #{Marquee.src()} (id, note)
    SELECT g::text, 'seed-' || g::text FROM generate_series(1, 25) g
    """)

    start_snapshot!(@sequence_slot, SequencedSnapshotSink)
    assert_receive {:snapshot_paused, snapshot_pid, snapshot_lsn}, 15_000
    assert is_integer(snapshot_lsn) and snapshot_lsn > 0

    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('26', 'after-export')")
    assert Marquee.mirror_rows() == []

    send(snapshot_pid, :continue_snapshot)
    assert_receive {:handoff_paused, handoff_pid, ^snapshot_lsn}, 15_000

    assert length(Marquee.mirror_rows()) == 25
    refute ["26", "after-export"] in Marquee.mirror_rows()
    assert Agent.get(trace, & &1) == [:snapshot_complete]

    send(handoff_pid, :continue_handoff)
    PG.wait_until(fn -> ["26", "after-export"] in Marquee.mirror_rows() end)

    assert [:snapshot_complete, :transaction | _rest] = Agent.get(trace, & &1)
    assert length(Marquee.mirror_rows()) == 26
    PG.wait_until(fn -> observer_checkpoint_count(run_id) == 2 end)
    assert DestinationObserver.effect_count(run_id, "mapped", "INSERT") == 26
    assert DestinationObserver.effect_count(run_id, "auxiliary", "INSERT") == 26
  end

  defp start_snapshot!(slot, sink) do
    assert {:ok, _pid} =
             AshReplicant.start_link(
               sink: sink,
               connection: Marquee.conn(),
               publication: Marquee.publication(),
               source_identity: Marquee.source_identity(),
               snapshot: true
             )

    assert :persistent_term.get({AshReplicant, slot}, :none) != :none
  end

  defp attach_snapshot_complete(slot) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :snapshot, :completed],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {
          :snapshot_complete,
          ref,
          metadata.commit_lsn,
          metadata.change_count
        })
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    assert slot == @snapshot_slot
    ref
  end

  defp attach_slot_active(slot) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {:slot_active, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    assert slot == @snapshot_slot
    ref
  end

  defp observer_triggers do
    [
      %{table: Marquee.mirror(), participant: "mapped", operations: [:insert, :update, :delete]},
      %{table: Marquee.auxiliary(), participant: "auxiliary", operations: [:insert]},
      %{
        table: "ash_replicant_checkpoints",
        participant: "checkpoint",
        operations: [:insert, :update],
        commit_lsn_column: "commit_lsn"
      }
    ]
  end

  defp observer_checkpoint_count(run_id) do
    DestinationObserver.effect_count(run_id, "checkpoint", "INSERT") +
      DestinationObserver.effect_count(run_id, "checkpoint", "UPDATE")
  end
end
