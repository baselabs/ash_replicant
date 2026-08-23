defmodule AshReplicant.Test.FaultRecovery.Order do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.FaultRecovery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "fault_recovery_mirror_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("fault_recovery_src_orders")
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :create do
      primary? true
      accept [:id, :note]
    end
  end
end

defmodule AshReplicant.Test.FaultRecovery.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.FaultRecovery.Order
  end
end

defmodule AshReplicant.Test.FaultRecovery.Sink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.FaultRecovery.Domain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "fault_recovery_slot"
end

defmodule AshReplicant.FaultRecoveryTest do
  @moduledoc """
  Issue #14 / ADR-0014 + ADR-0019: the control-plane crash and reconnect
  matrix, live. Three legs, each with a paired red-capability mutation
  (receipts in the F01 design note, a local lifecycle artifact):

    * source disconnect mid-stream — the walsender dies while the pipeline
      PROCESS stays up; postgrex reconnects in-process (the reconnect's own
      `:slot_active` is asserted, and the killer flunks if it matched no
      backend) and the WAL committed during the outage streams through.
      Exactly-once is proven by per-statement observer counts on BOTH
      operations — a re-apply of an existing row is an upsert conflict
      (UPDATE), invisible to an INSERT-only count. There is no
      re-deliver-then-skip window to assert here: the reconnect resume
      origin is `max(durable checkpoint, confirmed_flush)` and the
      checkpoint commits WITH the rows, so it never lags a completed
      delivery — the watermark skip's own red-capable proof is the
      direct-LSN suite in `checkpoint_binding_test.exs`;
    * owner death + generation replacement — killing the live owner fails
      the next delivery's admission closed, the pipeline halts itself, the
      surfaced state is the tombstone cause, and an explicit re-activation
      reaps the dead generation and resumes with no duplication or loss;
    * a persistent checkpoint READ fault injected mid-run (the checkpoint
      table renamed away under the live pipeline) — the connect-position
      read is fail-open by design (spec §14.15), so safety rests on the
      delivery admission's locked re-read failing closed: no effect
      proceeds, the watermark is untouched, and repair + explicit restart
      recovers exactly-once.

  Every fault here is a real substrate fault (backend kill, process kill,
  DDL rename) — no prod-code injection seam exists or is added.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshReplicant.Test.{DestinationObserver, Marquee, PG}
  alias AshReplicant.Test.FaultRecovery.Sink
  alias Ecto.Adapters.SQL.Sandbox

  @slot "fault_recovery_slot"
  @publication "repl_fault_recovery_pub"
  @src "fault_recovery_src_orders"
  @mirror "fault_recovery_mirror_orders"
  @checkpoint_table "ash_replicant_checkpoints"
  @checkpoint_faulted "ash_replicant_checkpoints_faulted"

  # Fast enough to observe :healthy within a test's lifetime; the budget is
  # high so a loaded host's census fault can never halt this leg spuriously.
  @fast_census [
    interval_ms: 200,
    jitter_ratio: 0.0,
    timeout_ms: 5_000,
    max_consecutive_faults: 10
  ]

  setup do
    # The pipeline's processes do real committing writes through the shared
    # repo (the suite's :manual Sandbox has no owner for them) — :auto for
    # the module, restored after. Registered FIRST so it runs LAST (LIFO):
    # the cleanup queries below still execute while mode is :auto.
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    run_id = "fault-recovery-#{System.unique_integer([:positive])}"

    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM #{@checkpoint_table} WHERE slot_name = $1", [@slot])

    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("CREATE TABLE #{@src} (id text primary key, note text)")
    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    Marquee.q!("DROP TABLE IF EXISTS #{@mirror}")
    Marquee.q!("CREATE TABLE #{@mirror} (id text primary key, note text)")
    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    DestinationObserver.setup!(run_id, observer_triggers())
    assert DestinationObserver.unconstrained?()

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      # The read-fault leg renames the checkpoint table; restore it
      # defensively so a hard kill inside that window cannot poison every
      # later suite consumer of the shared table.
      restore_checkpoint_table()
      Marquee.q!("DELETE FROM #{@checkpoint_table} WHERE slot_name = $1", [@slot])
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS #{@mirror}")
      DestinationObserver.teardown!(observer_triggers())
    end)

    {:ok, run_id: run_id}
  end

  # The walsender kill deliberately lets the replication connection die
  # under the live pipeline — Replicant.Connection logs its protocol-level
  # [error] "is reconnecting" line as expected behavior (the
  # checkpoint_binding_test precedent), but that line matches the
  # structural battery's no-error grep. Capture it (shown only on failure).
  @tag capture_log: true
  test "source disconnect mid-stream reconnects in-process and continues exactly-once",
       %{run_id: run_id} do
    ref = attach_delivery_events()
    assert {:ok, owner} = start()
    assert_receive {:delivery, ^ref, :slot_active}, 15_000
    await_bound()

    # Row 1 lands and is durably checkpointed. The walsender is killed from
    # INSIDE the first :applied handler — after the destination transaction
    # commits but before the callback returns, so the ack cannot have gone
    # out. Note what this makes observable: because the checkpoint commits
    # WITH the rows, the reconnect's resume origin (max(durable checkpoint,
    # confirmed_flush)) never lags a completed delivery — there is no
    # re-deliver-then-skip window to assert here. The watermark skip's own
    # red-capable proof is the direct-LSN test at
    # test/integration/checkpoint_binding_test.exs ("equal and lower LSN
    # re-delivery skip"); this leg proves the CONTINUATION.
    attach_disconnect_killer()
    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('1', 'a')")
    assert_receive {:delivery, ^ref, {:applied, first_lsn}}, 15_000
    assert mirror_rows() == [["1", "a"]]

    # Rows committed while the source connection is down.
    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('2', 'b'), ('3', 'c')")

    # The pipeline process never died (no supervisor restart, no
    # re-activation): postgrex reconnects IN-PROCESS — the reconnect emits
    # its own :slot_active — and the WAL committed during the outage
    # streams through. Rows 2 and 3 are ONE source transaction (one INSERT
    # statement) — one applied event, change_count 2.
    assert_receive {:delivery, ^ref, :slot_active}, 15_000
    assert_receive {:delivery, ^ref, {:applied, _second_lsn}}, 15_000

    PG.wait_until(fn -> length(mirror_rows()) == 3 end, 600)
    assert mirror_rows() == [["1", "a"], ["2", "b"], ["3", "c"]]

    # Exactly-once, observed per statement and BOTH operations: one mirror
    # INSERT per row and ZERO UPDATEs — a re-apply of an existing row is an
    # upsert conflict, which fires the observer's UPDATE trigger and would
    # stay invisible to an INSERT-only count.
    assert DestinationObserver.effect_count(run_id, "mapped", "INSERT") == 3
    assert DestinationObserver.effect_count(run_id, "mapped", "UPDATE") == 0

    # The disconnect never touched the lifecycle: same live owner, the
    # watermark advanced monotonically, and the slot never halted.
    assert Process.alive?(owner)
    assert watermark() >= first_lsn
    assert AshReplicant.status(Sink) in [:catching_up, :healthy]

    assert :ok = AshReplicant.stop_supervised(@slot)
  end

  test "owner death fails the next delivery closed, halts, and re-activation resumes without dup or loss",
       %{run_id: run_id} do
    ref = attach_delivery_events()
    assert {:ok, owner} = start(@fast_census)
    assert_receive {:delivery, ^ref, :slot_active}, 15_000
    await_bound()

    # Marker row first: admission is proven flowing before the fault lands,
    # so the post-kill absence of effects is not trivially true.
    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('m', 'marker')")
    PG.wait_until(fn -> mirror_rows() == [["m", "marker"]] end, 600)

    # The owner dies untrapped. A delivery is then ATTEMPTED (row p): its
    # admission must fail closed, which halts the pipeline itself.
    Process.exit(owner, :kill)
    refute Process.alive?(owner)

    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('p', 'post-kill')")

    wait_pipeline_down()
    PG.wait_until(fn -> mirror_rows() == [["m", "marker"]] end, 600)

    # The failed admission funneled through the callback boundary: the
    # tombstone carries the scrubbed reason (:config_invalid, class halt).
    assert {:halted, :config_invalid} = AshReplicant.status(Sink)

    # Generation replacement: the dead-owner entry does not wedge the slot.
    # Re-activation reaps it (and any orphan pipeline) and resumes from the
    # durable watermark — the un-acked row p streams under the NEW owner.
    assert {:ok, second_owner} = start(@fast_census)
    assert second_owner != owner
    assert_receive {:delivery, ^ref, :slot_active}, 15_000
    PG.wait_until(fn -> mirror_rows() == [["m", "marker"], ["p", "post-kill"]] end, 600)

    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('q', 'resumed')")
    PG.wait_until(fn -> length(mirror_rows()) == 3 end, 600)
    assert mirror_rows() == [["m", "marker"], ["p", "post-kill"], ["q", "resumed"]]

    # No duplication across the death/replacement arc: exactly one mirror
    # INSERT per source row (a re-apply would be an upsert UPDATE), and the
    # watermark advanced past every LSN.
    assert DestinationObserver.effect_count(run_id, "mapped", "INSERT") == 3
    assert DestinationObserver.effect_count(run_id, "mapped", "UPDATE") == 0
    assert is_integer(watermark()) and watermark() > 0

    # The replacement generation reaches HEALTHY under its own census.
    PG.wait_until(fn -> AshReplicant.status(Sink) == :healthy end, 600)

    assert :ok = AshReplicant.stop_supervised(@slot)
  end

  test "a persistent checkpoint read fault mid-run halts with no effect and recovers after repair",
       %{run_id: run_id} do
    ref = attach_delivery_events()
    assert {:ok, _owner} = start()
    assert_receive {:delivery, ^ref, :slot_active}, 15_000
    await_bound()

    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('1', 'a')")
    PG.wait_until(fn -> mirror_rows() == [["1", "a"]] end, 600)
    watermark_before = watermark()
    assert is_integer(watermark_before)

    # The read fault: the checkpoint table is renamed away UNDER the live
    # pipeline. The connect-position read is fail-open by design (spec
    # §14.15) — safety must come from the delivery admission's locked
    # re-read, which now faults.
    Marquee.q!("ALTER TABLE #{@checkpoint_table} RENAME TO #{@checkpoint_faulted}")

    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('2', 'b')")
    wait_pipeline_down()

    # No effect proceeded and nothing was treated as a fresh checkpoint.
    PG.wait_until(fn -> mirror_rows() == [["1", "a"]] end, 600)
    assert DestinationObserver.effect_count(run_id, "mapped", "INSERT") == 1

    # Repair the substrate: the watermark is byte-identical to pre-fault
    # (the faulting delivery rolled back completely), and the surfaced
    # state is the scrubbed read-fault cause (:sink_failed, class halt).
    Marquee.q!("ALTER TABLE #{@checkpoint_faulted} RENAME TO #{@checkpoint_table}")
    assert watermark() == watermark_before
    assert {:halted, :sink_failed} = AshReplicant.status(Sink)

    # Explicit restart resumes exactly-once: the un-acked row 2 streams,
    # row 1 is not re-applied, and the watermark advances.
    assert {:ok, _owner2} = start()
    assert_receive {:delivery, ^ref, :slot_active}, 15_000
    PG.wait_until(fn -> mirror_rows() == [["1", "a"], ["2", "b"]] end, 600)

    assert DestinationObserver.effect_count(run_id, "mapped", "INSERT") == 2
    assert DestinationObserver.effect_count(run_id, "mapped", "UPDATE") == 0
    assert watermark() > watermark_before

    assert :ok = AshReplicant.stop_supervised(@slot)
  end

  # --- fixtures / helpers ---

  defp observer_triggers do
    [
      %{table: @mirror, participant: "mapped", operations: [:insert, :update, :delete]},
      %{
        table: @checkpoint_table,
        participant: "checkpoint",
        operations: [:insert, :update],
        commit_lsn_column: "commit_lsn"
      }
    ]
  end

  defp start(census \\ []) do
    {:ok, _pid} =
      AshReplicant.start_link(
        sink: Sink,
        connection: Marquee.conn(),
        publication: @publication,
        source_identity: Marquee.source_identity(),
        go_forward_only: true,
        census: census
      )
  end

  defp attach_delivery_events do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:replicant, :connection, :slot_active],
        [:ash_replicant, :sink, :applied],
        [:ash_replicant, :sink, :skipped]
      ],
      fn event, _measurements, metadata, _config ->
        case event do
          [:replicant, :connection, :slot_active] ->
            send(test_pid, {:delivery, ref, :slot_active})

          [:ash_replicant, :sink, :applied] ->
            send(test_pid, {:delivery, ref, {:applied, metadata.commit_lsn}})

          [:ash_replicant, :sink, :skipped] ->
            send(test_pid, {:delivery, ref, {:skipped, metadata.commit_lsn}})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  # Kill the slot's walsender from inside the FIRST :applied handler —
  # synchronously, before the callback returns — so the transaction's ack
  # cannot have advanced confirmed_flush past it. The once-flag keeps later
  # (post-reconnect) applications from re-killing.
  defp attach_disconnect_killer do
    key = {__MODULE__, :killed, @slot}
    :persistent_term.put(key, false)

    :telemetry.attach(
      {__MODULE__, :disconnect_killer},
      [:ash_replicant, :sink, :applied],
      fn _event, _measurements, _metadata, _config ->
        unless :persistent_term.get(key, true) do
          :persistent_term.put(key, true)
          kill_walsender()
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach({__MODULE__, :disconnect_killer})
      :persistent_term.erase(key)
    end)
  end

  # The forced-reconnect shape (test/integration/checkpoint_binding_test.exs):
  # terminate the slot's walsender backend — the pipeline's Connection
  # process survives and postgrex reconnects in-process. Flunks when the
  # join matches no backend: a silent no-op kill would leave the leg's
  # reconnect assertions vacuously green.
  defp kill_walsender do
    rows =
      Marquee.q!(
        "SELECT r.pid FROM pg_stat_replication r JOIN pg_replication_slots s ON s.active_pid = r.pid WHERE s.slot_name = $1",
        [@slot]
      ).rows

    unless rows != [] do
      ExUnit.Assertions.flunk("kill_walsender matched no backend for #{@slot}")
    end

    for [pid] <- rows do
      Marquee.q!("SELECT pg_terminate_backend($1)", [pid])
    end

    :ok
  end

  defp await_bound do
    PG.wait_until(fn ->
      [[count]] =
        Marquee.q!("SELECT count(*) FROM #{@checkpoint_table} WHERE slot_name = $1", [@slot]).rows

      count == 1
    end)
  end

  defp wait_pipeline_down do
    PG.wait_until(fn -> Registry.lookup(Replicant.Registry, {@slot, :pipeline}) == [] end, 600)
  end

  defp mirror_rows,
    do: Marquee.q!("SELECT id, note FROM #{@mirror} ORDER BY id").rows

  defp watermark do
    case Marquee.q!("SELECT commit_lsn FROM #{@checkpoint_table} WHERE slot_name = $1", [
           @slot
         ]).rows do
      [[lsn]] -> lsn
      [] -> :absent
    end
  end

  defp restore_checkpoint_table do
    # Idempotent reverse rename: absent-or-already-restored is the no-op (a
    # missing _faulted, or any other catalog state, must never wedge the
    # shared teardown).
    Marquee.q!("ALTER TABLE #{@checkpoint_faulted} RENAME TO #{@checkpoint_table}")
  rescue
    Postgrex.Error -> :ok
  end
end
