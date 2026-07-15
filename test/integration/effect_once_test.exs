defmodule AshReplicant.EffectOnceTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.Marquee
  alias AshReplicant.Test.PG
  alias Ecto.Adapters.SQL.Sandbox

  @slot "marquee_slot"

  setup do
    # The pipeline's Connection/AssemblerServer run in their OWN processes and do
    # real `config.repo` writes; logical replication also needs COMMITTED source
    # rows. Neither works under the suite's :manual Sandbox (no owner for those
    # processes, and sandbox writes never commit). Run this module against real
    # committing pooled connections (:auto), restoring :manual afterward. This
    # on_exit is registered FIRST so it runs LAST (LIFO): the cleanup queries below
    # still execute while mode is :auto.
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()

    # `drop_slot!` retries while the walsender still holds the slot: Postgres
    # releases a replication slot ASYNCHRONOUSLY after the client socket closes, so
    # a drop immediately after a stop can raise 55006 (object_in_use).
    Marquee.drop_slot!(@slot)

    # The slot and its durable checkpoint are a PAIR: replicant fail-closes with
    # `:data_gap` when the slot is absent but a checkpoint > 0 exists (potential
    # silent loss). `ash_replicant_checkpoints` is committed OUTSIDE the sandbox and
    # keyed by slot_name, so a prior run's row survives the slot drop. Clear it here
    # to reset to a genuine first run. Only at setup/teardown — NEVER mid-test, so
    # the crash-resume slot+checkpoint stay consistent for dedup.
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    # MANDATE A: mirror the defensive tmp_block drop into setup too — a hard kill
    # during the atomic test's fault window (constraint added, not yet dropped)
    # would otherwise leave it lingering and poison every checkpoint upsert next run.
    Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT IF EXISTS tmp_block")

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)

      Marquee.drop_slot!(@slot)

      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

      # MANDATE A: the atomic-rollback test adds a CHECK constraint to the SHARED
      # ash_replicant_checkpoints table. Drop it defensively here so a mid-test
      # crash can never poison every subsequent checkpoint upsert (idempotent).
      Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT IF EXISTS tmp_block")
    end)

    :ok
  end

  # `Replicant.start_link` returns once the pipeline is supervised, but the
  # replication connection creates/resumes the slot asynchronously. Inserting
  # before the slot is streaming would place the row's WAL BEFORE the slot's
  # start point, and `go_forward_only: true` would skip it (silent loss). Block on
  # the `:slot_active` event (fires on both fresh `:create_slot` AND stream-resume)
  # so the INSERT is always captured — the readiness pattern replicant's own
  # integration marquee uses.
  defp start! do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _meta, _cfg -> send(test_pid, {:slot_active, ref}) end,
      nil
    )

    {:ok, _pid} =
      AshReplicant.start_link(
        sink: Marquee.Sink,
        connection: Marquee.conn(),
        slot_name: @slot,
        publication: Marquee.publication(),
        go_forward_only: true
      )

    receive do
      {:slot_active, ^ref} -> :ok
    after
      15_000 -> flunk("pipeline never reached slot_active for #{@slot}")
    end

    :telemetry.detach({__MODULE__, ref})
  end

  test "end-to-end: a source INSERT lands in the Ash mirror exactly once" do
    start!()
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('1', 'a')")
    PG.wait_until(fn -> Marquee.mirror_rows() == [["1", "a"]] end)

    counts = Marquee.applied_counts()
    assert map_size(counts) > 0
    assert Enum.all?(Map.values(counts), &(&1 == 1))
  end

  test "crash-and-resume: killing the pipeline mid-stream loses nothing and duplicates nothing" do
    start!()
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('1', 'a')")
    PG.wait_until(fn -> Marquee.mirror_rows() == [["1", "a"]] end)

    :ok = AshReplicant.stop_supervised(@slot)
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('2', 'b'), ('3', 'c')")

    start!()
    PG.wait_until(fn -> length(Marquee.mirror_rows()) == 3 end)
    assert Marquee.mirror_rows() == [["1", "a"], ["2", "b"], ["3", "c"]]

    counts = Marquee.applied_counts()
    assert map_size(counts) > 0
    assert Enum.all?(Map.values(counts), &(&1 == 1))
  end

  test "atomic rollback: a checkpoint-write fault rolls back the whole transaction, then dedups on resume" do
    start!()
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('1', 'a')")
    PG.wait_until(fn -> Marquee.mirror_rows() == [["1", "a"]] end)

    Marquee.q!(
      "ALTER TABLE ash_replicant_checkpoints ADD CONSTRAINT tmp_block CHECK (commit_lsn < 0) NOT VALID"
    )

    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('2', 'b')")
    Process.sleep(500)
    assert Marquee.mirror_rows() == [["1", "a"]]

    Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT tmp_block")
    AshReplicant.stop_supervised(@slot)
    start!()
    PG.wait_until(fn -> length(Marquee.mirror_rows()) == 2 end)
    assert Marquee.mirror_rows() == [["1", "a"], ["2", "b"]]

    counts = Marquee.applied_counts()
    assert map_size(counts) > 0
    assert Enum.all?(Map.values(counts), &(&1 == 1))
  end
end
