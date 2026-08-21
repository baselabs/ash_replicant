defmodule AshReplicant.AppendLogTest do
  @moduledoc """
  The append-log pipeline end to end over real PostgreSQL logical replication
  (ADR-0018's required proof).

  Everything here is observed through PUBLIC boundaries: real WAL from real
  source DML, the host's own event table, and the durable checkpoint row. What
  is being proven is not that the sink believes it appended once, but that the
  substrate holds exactly one immutable event per source change — and that the
  go-forward floor and its gap check behave on an actual reconnect rather than
  a simulated one.
  """

  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 180_000

  alias AshReplicant.Test.{AppendMarquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @stream_slot AppendMarquee.stream_slot()
  @snapshot_slot AppendMarquee.snapshot_slot()
  @batch_slot AppendMarquee.batch_slot()

  setup do
    # The pipeline's own processes do real committing writes, and logical
    # replication only sees COMMITTED source rows — neither works under the
    # suite's :manual sandbox.
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    AppendMarquee.setup_schema!()
    reset_slot!(@stream_slot)
    reset_slot!(@snapshot_slot)
    reset_slot!(@batch_slot)

    on_exit(fn ->
      AshReplicant.stop_supervised(@stream_slot)
      AshReplicant.stop_supervised(@snapshot_slot)
      AshReplicant.stop_supervised(@batch_slot)
      reset_slot!(@stream_slot)
      reset_slot!(@snapshot_slot)
      reset_slot!(@batch_slot)
      AppendMarquee.teardown_schema!()
    end)

    :ok
  end

  defp reset_slot!(slot) do
    AppendMarquee.drop_slot!(slot)
    # The slot and its durable checkpoint are a PAIR (replicant fail-closes on
    # a checkpoint with no slot), and the checkpoint row is committed outside
    # the sandbox, so a prior run's row survives a slot drop.
    AppendMarquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
  end

  # `Replicant.start_link` returns once supervised, but the replication
  # connection creates/resumes the slot asynchronously; DML before the slot is
  # streaming would sit BEFORE its start point and be skipped go-forward.
  defp start_stream! do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _e, _m, _meta, _cfg -> send(test_pid, {:slot_active, ref}) end,
      nil
    )

    {:ok, _pid} =
      AshReplicant.start_link(
        sink: AppendMarquee.StreamSink,
        connection: AppendMarquee.conn(),
        slot_name: @stream_slot,
        publication: AppendMarquee.publication(),
        source_identity: AppendMarquee.source_identity(),
        go_forward_only: true
      )

    receive do
      {:slot_active, ^ref} -> :ok
    after
      15_000 -> flunk("append pipeline never reached slot_active for #{@stream_slot}")
    end

    :telemetry.detach({__MODULE__, ref})
  end

  defp start_snapshot! do
    {:ok, _pid} =
      AshReplicant.start_link(
        sink: AppendMarquee.SnapshotSink,
        connection: AppendMarquee.conn(),
        slot_name: @snapshot_slot,
        publication: AppendMarquee.publication(),
        source_identity: AppendMarquee.source_identity(),
        snapshot: true
      )
  end

  defp start_batch! do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _e, _m, _meta, _cfg -> send(test_pid, {:batch_slot_active, ref}) end,
      nil
    )

    {:ok, _pid} =
      AshReplicant.start_link(
        sink: AppendMarquee.BatchSink,
        connection: AppendMarquee.conn(),
        slot_name: @batch_slot,
        publication: AppendMarquee.publication(),
        source_identity: AppendMarquee.source_identity(),
        go_forward_only: true,
        batch_delivery: [max_transactions: 2, max_delay_ms: 10_000]
      )

    receive do
      {:batch_slot_active, ^ref} -> :ok
    after
      15_000 -> flunk("append batch pipeline never reached slot_active for #{@batch_slot}")
    end

    :telemetry.detach({__MODULE__, ref})
  end

  describe "operation shapes over live WAL (ADR-0018 §4)" do
    test "insert, update, delete and truncate each append one immutable event" do
      start_stream!()

      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1', 'a')")
      AppendMarquee.q!("UPDATE #{AppendMarquee.src()} SET note = 'b' WHERE id = '1'")
      AppendMarquee.q!("DELETE FROM #{AppendMarquee.src()} WHERE id = '1'")
      AppendMarquee.q!("TRUNCATE TABLE #{AppendMarquee.src()}")

      PG.wait_until(fn -> AppendMarquee.event_count() == 4 end)

      assert AppendMarquee.events() == [
               ["insert", "stream", "1", "a"],
               ["update", "stream", "1", "b"],
               # The DELETE records the admitted OLD record, so the deleted
               # payload survives in the log.
               ["delete", "stream", "1", "b"],
               # The TRUNCATE is structural: no payload at all.
               ["truncate", "stream", nil, nil]
             ]
    end

    test "the appended identity is the live session's system, database, slot, LSN and ordinal" do
      start_stream!()
      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1','a'),('2','b')")

      PG.wait_until(fn -> AppendMarquee.event_count() == 2 end)

      %{system_identifier: system, database: database} =
        AppendMarquee.source_identity() |> Map.new()

      assert [
               [^system, ^database, @stream_slot, lsn_a, ordinal_a],
               [^system, ^database, @stream_slot, lsn_b, ordinal_b]
             ] = AppendMarquee.identities()

      # Two changes in ONE transaction: same commit LSN, distinct ordinals —
      # distinct same-transaction effects never overwrite one another.
      assert lsn_a == lsn_b
      assert ordinal_a != ordinal_b
    end

    test "transactional and standalone logical messages append with their real WAL identity" do
      start_stream!()

      {:ok, _result} =
        AshReplicant.TestRepo.transaction(fn ->
          AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ($1, $2)", [
            "1",
            "a"
          ])

          AppendMarquee.q!("SELECT pg_logical_emit_message(true, $1, $2)", [
            "events",
            "transactional"
          ])
        end)

      AppendMarquee.q!("SELECT pg_logical_emit_message(false, $1, $2)", ["events", "standalone"])

      PG.wait_until(fn -> AppendMarquee.event_count() == 3 end)

      assert [row, transactional, standalone] = AppendMarquee.message_events()
      assert ["insert", nil, nil, txn_lsn, 0, "1"] = row

      assert ["message", "events", "transactional", ^txn_lsn, 1, nil] = transactional
      assert ["message", "events", "standalone", standalone_lsn, 0, nil] = standalone
      assert standalone_lsn > txn_lsn
    end
  end

  describe "live batch delivery" do
    test "two source transactions append in one sink batch with one trailing watermark" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:ash_replicant, :sink, :batch_applied]
        ])

      start_batch!()
      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1', 'a')")
      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('2', 'b')")

      PG.wait_until(fn -> AppendMarquee.event_count() == 2 end)

      assert_received {[:ash_replicant, :sink, :batch_applied], ^ref, measurements, metadata}
      assert measurements.change_count == 2
      assert metadata.txn_count == 2

      highest_lsn = AppendMarquee.identities() |> List.last() |> Enum.at(3)
      assert AppendMarquee.checkpoint(@batch_slot).commit_lsn == highest_lsn
      :telemetry.detach(ref)
    end
  end

  describe "effect-once over a real crash and resume (ADR-0018 §3)" do
    test "a crash after append commit but before slot ack resumes without a duplicate" do
      applied_ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, applied_ref},
        [:ash_replicant, :sink, :applied],
        fn _event, _measurements, metadata, {pid, ref} ->
          # Telemetry executes synchronously in the sink callback AFTER the
          # destination transaction commits and BEFORE handle_transaction/1
          # returns to Replicant. Holding this handler opens the exact
          # delivered-but-unacknowledged crash window.
          send(pid, {:append_committed_before_ack, ref, metadata.commit_lsn, self()})

          receive do
            {:release_append_ack, ^ref} -> :ok
          end
        end,
        {test_pid, applied_ref}
      )

      on_exit(fn ->
        :telemetry.detach({__MODULE__, applied_ref})
      end)

      start_stream!()
      [{connection, _}] = Registry.lookup(Replicant.Registry, {@stream_slot, :connection})
      connection_ref = Process.monitor(connection)

      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1', 'a')")

      assert_receive {:append_committed_before_ack, ^applied_ref, committed_lsn, assembler},
                     15_000

      assert is_pid(assembler)
      assert AppendMarquee.event_count() == 1
      assert AppendMarquee.checkpoint(@stream_slot).commit_lsn == committed_lsn

      # This is demonstrably pre-ack: the server-side slot is still behind the
      # already-committed destination watermark while the handler is held.
      assert AppendMarquee.confirmed_flush(@stream_slot) < committed_lsn

      # The callback is still blocked above, so Replicant has not received its
      # {:sink_committed, lsn} signal. Killing the connection tears down the
      # one-for-all generation while PostgreSQL still retains the older
      # confirmed_flush_lsn. On restart Replicant reads the sink's DURABLE
      # checkpoint and requests that position, so this sink-owned mode resumes
      # at the committed frontier rather than invoking the sink a second time.
      assembler_ref = Process.monitor(assembler)
      Process.exit(connection, :kill)
      assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 5_000
      assert_receive {:DOWN, ^assembler_ref, :process, ^assembler, _reason}, 5_000

      PG.wait_until(fn ->
        case Registry.lookup(Replicant.Registry, {@stream_slot, :connection}) do
          [{new_connection, _}] when new_connection != connection ->
            AppendMarquee.confirmed_flush(@stream_slot) >= committed_lsn

          _other ->
            false
        end
      end)

      assert AppendMarquee.event_count() == 1
      assert length(AppendMarquee.identities()) == 1

      :ok = AshReplicant.stop_supervised(@stream_slot)

      PG.wait_until(fn ->
        Registry.lookup(Replicant.Registry, {@stream_slot, :pipeline}) == []
      end)
    end

    test "a killed pipeline re-streams un-acked WAL and appends each event exactly once" do
      start_stream!()
      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1', 'a')")
      PG.wait_until(fn -> AppendMarquee.event_count() == 1 end)

      :ok = AshReplicant.stop_supervised(@stream_slot)

      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('2','b'),('3','c')")

      start_stream!()
      PG.wait_until(fn -> AppendMarquee.event_count() == 3 end)

      assert AppendMarquee.events() == [
               ["insert", "stream", "1", "a"],
               ["insert", "stream", "2", "b"],
               ["insert", "stream", "3", "c"]
             ]

      # The crash window's WAL is lawfully re-delivered on resume. Nothing was
      # lost and nothing doubled — the count IS the assertion.
      assert AppendMarquee.event_count() == 3
      assert length(Enum.uniq(AppendMarquee.identities())) == 3
    end

    test "the append and the checkpoint advance together" do
      start_stream!()
      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1', 'a')")
      PG.wait_until(fn -> AppendMarquee.event_count() == 1 end)

      PG.wait_until(fn ->
        checkpoint = AppendMarquee.checkpoint(@stream_slot)
        is_integer(checkpoint.commit_lsn) and checkpoint.commit_lsn > 0
      end)

      [[_sys, _db, _slot, appended_lsn, _ordinal]] = AppendMarquee.identities()
      # The watermark is never BELOW an appended event: they commit in one
      # destination transaction, so a lower watermark would mean a torn write.
      assert AppendMarquee.checkpoint(@stream_slot).commit_lsn >= appended_lsn
    end
  end

  describe "the go-forward origin floor (ADR-0018 §5)" do
    test "a NEW slot persists its consistent point as the floor" do
      start_stream!()

      PG.wait_until(fn ->
        checkpoint = AppendMarquee.checkpoint(@stream_slot)
        checkpoint != nil and is_integer(checkpoint.origin_floor)
      end)

      assert AppendMarquee.checkpoint(@stream_slot).origin_floor > 0
    end

    test "a REUSED slot's reconnect keeps the ORIGINAL floor" do
      start_stream!()

      PG.wait_until(fn ->
        checkpoint = AppendMarquee.checkpoint(@stream_slot)
        checkpoint != nil and is_integer(checkpoint.origin_floor)
      end)

      floor = AppendMarquee.checkpoint(@stream_slot).origin_floor

      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1', 'a')")
      PG.wait_until(fn -> AppendMarquee.event_count() == 1 end)

      :ok = AshReplicant.stop_supervised(@stream_slot)
      start_stream!()

      # The reconnect origin is the slot's effective START_REPLICATION origin,
      # which has ADVANCED past the floor as the stream was acked. It is a
      # resume fact, not a new floor.
      assert AppendMarquee.checkpoint(@stream_slot).origin_floor == floor
    end

    test "a RECREATED slot under an existing floor halts as a gap" do
      start_stream!()
      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1', 'a')")
      PG.wait_until(fn -> AppendMarquee.event_count() == 1 end)

      PG.wait_until(fn ->
        is_integer(AppendMarquee.checkpoint(@stream_slot).commit_lsn)
      end)

      :ok = AshReplicant.stop_supervised(@stream_slot)

      # Drop the slot and clear the watermark, but KEEP the floor and the
      # appended events: a real operator state after a slot is lost and the
      # checkpoint reset by hand. The next connect creates a FRESH slot, so the
      # WAL between the log's frontier and the new consistent point is gone.
      # Replicant's own `:data_gap` gate keys on a non-null checkpoint, so
      # clearing it is what lets this reach the sink's floor check at all.
      AppendMarquee.drop_slot!(@stream_slot)

      AppendMarquee.q!(
        "UPDATE ash_replicant_checkpoints SET commit_lsn = NULL WHERE slot_name = $1",
        [@stream_slot]
      )

      AppendMarquee.q!("DELETE FROM #{AppendMarquee.events_table()}")

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:ash_replicant, :checkpoint, :conflict],
        fn _e, _m, meta, _cfg -> send(test_pid, {:conflict, ref, meta.reason}) end,
        nil
      )

      {:ok, _pid} =
        AshReplicant.start_link(
          sink: AppendMarquee.StreamSink,
          connection: AppendMarquee.conn(),
          slot_name: @stream_slot,
          publication: AppendMarquee.publication(),
          source_identity: AppendMarquee.source_identity(),
          go_forward_only: true
        )

      assert_receive {:conflict, ^ref, :append_origin_gap}, 20_000
      :telemetry.detach({__MODULE__, ref})

      # Fail CLOSED: the floor is untouched and nothing streamed over the hole.
      assert AppendMarquee.checkpoint(@stream_slot).commit_lsn == nil
      assert AppendMarquee.event_count() == 0
    end

    test "an out-of-band advance of a REUSED slot halts before streaming" do
      start_stream!()
      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1', 'a')")
      PG.wait_until(fn -> AppendMarquee.event_count() == 1 end)

      checkpoint = AppendMarquee.checkpoint(@stream_slot).commit_lsn
      assert is_integer(checkpoint)

      :ok = AshReplicant.stop_supervised(@stream_slot)

      PG.wait_until(fn ->
        Registry.lookup(Replicant.Registry, {@stream_slot, :pipeline}) == []
      end)

      # Generate real WAL outside the publication, then advance the retained
      # slot over it exactly as an operator or competing consumer could while
      # this pipeline is down.
      AppendMarquee.q!(
        "INSERT INTO #{AppendMarquee.noise_table()} (note) " <>
          "SELECT 'noise' FROM generate_series(1, 200)"
      )

      assert %{rows: [[advanced]]} = AppendMarquee.advance_slot_to_current_wal!(@stream_slot)
      assert Replicant.lsn_from_string(advanced) > checkpoint

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:ash_replicant, :checkpoint, :conflict],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:out_of_band_gap, ref, metadata.reason})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      {:ok, _pid} =
        AshReplicant.start_link(
          sink: AppendMarquee.StreamSink,
          connection: AppendMarquee.conn(),
          slot_name: @stream_slot,
          publication: AppendMarquee.publication(),
          source_identity: AppendMarquee.source_identity(),
          go_forward_only: true
        )

      assert_receive {:out_of_band_gap, ^ref, :append_origin_gap}, 20_000
      assert AppendMarquee.event_count() == 1
      assert AppendMarquee.checkpoint(@stream_slot).commit_lsn == checkpoint
    end
  end

  describe "snapshot backfill as the initial state (ADR-0018 §4, §5)" do
    test "backfill rows append with the snapshot origin and one checkpoint-owned attempt" do
      AppendMarquee.q!(
        "INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1','a'),('2','b'),('3','c')"
      )

      start_snapshot!()

      PG.wait_until(fn -> AppendMarquee.event_count() == 3 end)

      assert AppendMarquee.events() == [
               ["snapshot", "snapshot", "1", "a"],
               ["snapshot", "snapshot", "2", "b"],
               ["snapshot", "snapshot", "3", "c"]
             ]

      # ONE attempt across the whole backfill, and it is real bytes — the
      # checkpoint-owned attempt id, not a per-row invention.
      assert [[attempt]] = AppendMarquee.snapshot_attempts()
      assert is_binary(attempt)
      assert byte_size(attempt) > 0
    end

    test "stream changes after the handoff append with the stream origin" do
      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('1','a')")

      start_snapshot!()
      PG.wait_until(fn -> AppendMarquee.event_count() == 1 end)

      AppendMarquee.q!("INSERT INTO #{AppendMarquee.src()} (id, note) VALUES ('2','b')")
      PG.wait_until(fn -> AppendMarquee.event_count() == 2 end)

      assert AppendMarquee.events() == [
               ["snapshot", "snapshot", "1", "a"],
               ["insert", "stream", "2", "b"]
             ]

      # A snapshot-intent sink takes its floor from the backfill's consistent
      # point, so it never writes the go-forward origin floor.
      assert AppendMarquee.checkpoint(@snapshot_slot).origin_floor == nil
    end
  end
end
