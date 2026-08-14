defmodule AshReplicant.SnapshotPipelineTest do
  @moduledoc """
  The v1 snapshot pipeline, observed through PUBLIC boundaries only: Replicant/
  AshReplicant telemetry, a test-owned database trigger (the mid-snapshot failure
  injection), the DestinationObserver write ledger, and durable mirror/checkpoint
  state. No production interception surface.

  The sequencing test needs no lock: `[:replicant, :snapshot, :started]` fires
  from the snapshotter only AFTER the slot's exported snapshot (the consistent
  point) exists, so a source write from that moment on is invisible to the
  snapshot read and must arrive via the stream — deterministically. The
  handoff-instant mirror state is captured INSIDE the
  `[:ash_replicant, :snapshot, :complete]` handler: the handler runs in the
  snapshotter before `handle_snapshot_complete/1` returns, so streaming cannot
  have started and the read is race-free.
  """

  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 120_000

  import ExUnit.CaptureLog

  alias AshReplicant.Test.{DestinationObserver, Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @snapshot_slot "snapshot_pipeline_slot"
  @retry_slot "snapshot_retry_slot"
  @sequence_slot "snapshot_sequence_slot"
  @fail_second_batch_trigger "repl_fail_snapshot_second_batch"
  @fail_second_batch_function "repl_fail_snapshot_second_batch_fn"

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
  end

  defmodule SequencedSnapshotSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snapshot_sequence_slot"
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

    on_exit(fn ->
      for slot <- [@snapshot_slot, @retry_slot, @sequence_slot] do
        AshReplicant.stop_supervised(slot)
        Marquee.drop_slot!(slot)
        Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
      end

      drop_second_batch_failure!()
      DestinationObserver.teardown!(observer_triggers())
      Marquee.teardown_schema!()
    end)

    {:ok, run_id: run_id}
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
      # Fail EXACTLY the second batch, content-independently: the snapshotter
      # delivers 1000-row batches, so the first mirror insert that can see >= 1000
      # committed mapped-INSERT ledger rows (batch 1, durably applied) is
      # necessarily in a later batch. The raised error aborts the sink's write
      # transaction, the snapshotter rolls its read transaction back, and the
      # reconnect halts on the incomplete slot.
      install_second_batch_failure!(run_id)

      start_snapshot!(@retry_slot, RetrySnapshotSink)

      assert_receive :snapshot_incomplete, 60_000

      PG.wait_until(fn ->
        Registry.lookup(Replicant.Registry, {@retry_slot, :pipeline}) == []
      end)

      # Batch 1 is durably applied; the failed batch left no rows.
      assert length(Marquee.mirror_rows()) == 1000

      # Operator reset: remove the injected failure, then re-run from scratch.
      drop_second_batch_failure!()
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
       %{run_id: run_id} do
    Marquee.q!("""
    INSERT INTO #{Marquee.src()} (id, note)
    SELECT g::text, 'seed-' || g::text FROM generate_series(1, 25) g
    """)

    started_ref = attach_snapshot_started()
    handoff_ref = attach_handoff_capture()
    applied_ref = attach_stream_applied()

    start_snapshot!(@sequence_slot, SequencedSnapshotSink)

    # The export barrier: :started fires after the consistent point exists, so a
    # write from here on is committed AFTER the export — invisible to the
    # snapshot read, and necessarily in the WAL past the consistent point.
    assert_receive {:snapshot_started, ^started_ref}, 15_000
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('26', 'after-export')")

    assert_receive {:handoff, ^handoff_ref, snapshot_lsn, handoff_rows}, 15_000
    assert is_integer(snapshot_lsn) and snapshot_lsn > 0

    # Handoff-instant state: EXACTLY the 25 exported rows — the post-export write
    # is neither in the snapshot nor streamed yet.
    assert length(handoff_rows) == 25
    refute ["26", "after-export"] in handoff_rows

    # The durable handoff: the checkpoint sits at the snapshot's consistent point.
    assert [[^snapshot_lsn]] =
             Marquee.q!(
               "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
               [@sequence_slot]
             ).rows

    # The post-export write arrives via the STREAM, causally after the handoff,
    # at a commit LSN past the consistent point.
    assert_receive {:stream_applied, ^applied_ref, applied_lsn}, 15_000
    assert is_integer(applied_lsn) and applied_lsn > snapshot_lsn

    PG.wait_until(fn -> length(Marquee.mirror_rows()) == 26 end)
    assert ["26", "after-export"] in Marquee.mirror_rows()

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

  defp attach_snapshot_started do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :snapshot, :started],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {:snapshot_started, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  # Captures the mirror EXACTLY at the handoff instant: the handler runs inside
  # `handle_snapshot_complete/1`'s success path (after the checkpoint transaction
  # committed, before the callback returns), so streaming cannot have started and
  # an in-handler read is race-free.
  defp attach_handoff_capture do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ash_replicant, :snapshot, :complete],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:handoff, ref, metadata.commit_lsn, Marquee.mirror_rows()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp attach_stream_applied do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ash_replicant, :sink, :applied],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:stream_applied, ref, metadata.commit_lsn})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp install_second_batch_failure!(run_id) do
    Marquee.q!("""
    CREATE FUNCTION #{@fail_second_batch_function}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF (SELECT count(*) FROM #{DestinationObserver.table()}
          WHERE run_id = '#{run_id}' AND participant = 'mapped' AND operation = 'INSERT') >= 1000 THEN
        RAISE EXCEPTION 'injected snapshot batch failure';
      END IF;
      RETURN NEW;
    END
    $$
    """)

    Marquee.q!(
      "CREATE TRIGGER #{@fail_second_batch_trigger} BEFORE INSERT ON #{Marquee.mirror()} FOR EACH ROW EXECUTE FUNCTION #{@fail_second_batch_function}()"
    )

    :ok
  end

  defp drop_second_batch_failure! do
    Marquee.q!("DROP TRIGGER IF EXISTS #{@fail_second_batch_trigger} ON #{Marquee.mirror()}")
    Marquee.q!("DROP FUNCTION IF EXISTS #{@fail_second_batch_function}()")
    :ok
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
