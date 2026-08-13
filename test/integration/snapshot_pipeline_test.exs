defmodule AshReplicant.SnapshotPipelineTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 120_000

  import ExUnit.CaptureLog

  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @snapshot_slot "snapshot_pipeline_slot"
  @retry_slot "snapshot_retry_slot"
  @retry_key {__MODULE__, :fail_second_batch}
  @retry_observer {__MODULE__, :retry_observer}

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

    @impl Replicant.Sink
    def handle_snapshot(changes, %{first_for_table?: false} = context) do
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
        super(changes, context)
      end
    end

    def handle_snapshot(changes, context), do: super(changes, context)
  end

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()

    for slot <- [@snapshot_slot, @retry_slot] do
      Marquee.drop_slot!(slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
    end

    setup_audit!()
    :persistent_term.put(@retry_key, false)
    :persistent_term.put(@retry_observer, self())

    on_exit(fn ->
      for slot <- [@snapshot_slot, @retry_slot] do
        AshReplicant.stop_supervised(slot)
        Marquee.drop_slot!(slot)
        Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
      end

      :persistent_term.erase(@retry_key)
      :persistent_term.erase(@retry_observer)
      Marquee.q!("DROP TRIGGER IF EXISTS repl_snapshot_audit_trigger ON #{Marquee.mirror()}")
      Marquee.q!("DROP TABLE IF EXISTS repl_snapshot_audit")
      Marquee.q!("DROP FUNCTION IF EXISTS repl_snapshot_audit_write()")
    end)

    :ok
  end

  test "v1 snapshot converges, hands off its checkpoint, and resumes ordinary streaming" do
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
    counts = audit_counts()
    assert counts["25"] == 2
    assert Map.delete(counts, "25") |> Map.values() |> Enum.all?(&(&1 == 1))
  end

  test "an incomplete v1 snapshot halts until operator reset and retry exposes every repeated effect" do
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

      assert_receive :snapshot_failure_injected, 15_000
      assert_receive :snapshot_incomplete, 15_000

      PG.wait_until(fn ->
        Registry.lookup(Replicant.Registry, {@retry_slot, :pipeline}) == []
      end)

      assert length(Marquee.mirror_rows()) == 1000

      :ok = AshReplicant.stop_supervised(@retry_slot)
      Marquee.drop_slot!(@retry_slot)
      start_snapshot!(@retry_slot, RetrySnapshotSink)
      PG.wait_until(fn -> length(Marquee.mirror_rows()) == 1100 end, 800)

      counts = audit_counts()
      assert map_size(counts) == 1100
      assert Enum.count(counts, fn {_id, count} -> count == 2 end) == 1000
      assert Enum.count(counts, fn {_id, count} -> count == 1 end) == 100
    end)
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

  defp setup_audit! do
    Marquee.q!("DROP TABLE IF EXISTS repl_snapshot_audit")
    Marquee.q!("CREATE TABLE repl_snapshot_audit (id text not null, op text not null)")
    Marquee.q!("DROP FUNCTION IF EXISTS repl_snapshot_audit_write()")

    Marquee.q!("""
    CREATE FUNCTION repl_snapshot_audit_write() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO repl_snapshot_audit (id, op) VALUES (NEW.id, TG_OP);
      RETURN NEW;
    END
    $$
    """)

    Marquee.q!("""
    CREATE TRIGGER repl_snapshot_audit_trigger
    AFTER INSERT OR UPDATE ON #{Marquee.mirror()}
    FOR EACH ROW EXECUTE FUNCTION repl_snapshot_audit_write()
    """)
  end

  defp audit_counts do
    Marquee.q!("SELECT id, count(*) FROM repl_snapshot_audit GROUP BY id").rows
    |> Map.new(fn [id, count] -> {id, count} end)
  end
end
