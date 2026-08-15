defmodule AshReplicant.SessionIdentityTest do
  @moduledoc """
  Session-identity ordering, observed through PUBLIC boundaries only: Ecto query
  telemetry (table source, never row values), AshReplicant/Replicant telemetry,
  and durable checkpoint/mirror state. No production interception surface.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "identity_order_slot"

  defmodule IdentitySink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "identity_order_slot"
  end

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.teardown_schema!()
    end)

    :ok
  end

  test "the locked Hex package reports actual replication-session identity before checkpoint lookup" do
    identity_ref = attach_identity_events()
    access_ref = attach_checkpoint_access()
    applied_ref = attach_applied()

    expected_identity = Marquee.source_identity()

    assert {:ok, _pid} =
             AshReplicant.start_link(
               sink: IdentitySink,
               connection: Marquee.conn(),
               publication: Marquee.publication(),
               source_identity: expected_identity,
               go_forward_only: true
             )

    # The identity verdict must be the FIRST reported event: the checkpoint
    # observer is UNGATED, so any checkpoint-table access before the verdict
    # (the fail-open bug class) would land in this mailbox ahead of the verdict
    # and fail this assert.
    receive do
      message ->
        assert message ==
                 {:telemetry, identity_ref, [:ash_replicant, :sink, :session_identity_accepted],
                  %{}}
    after
      15_000 -> flunk("session identity was not accepted")
    end

    assert_receive {:checkpoint_accessed, ^access_ref}, 5_000

    assert_receive {:telemetry, ^identity_ref, [:replicant, :connection, :slot_active], %{}},
                   15_000

    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('identity-1', 'accepted')")

    assert_receive {:transaction_applied, ^applied_ref, commit_lsn, 1}, 15_000
    assert is_integer(commit_lsn) and commit_lsn > 0

    PG.wait_until(fn -> Marquee.mirror_rows() == [["identity-1", "accepted"]] end)
  end

  test "a wrong actual-session expectation halts before checkpoint lookup and stays value-free" do
    identity_ref = attach_identity_events()
    access_ref = attach_checkpoint_access()

    sentinel_system = "sentinel-wrong-system"
    sentinel_database = "sentinel-wrong-database"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # B3 strengthened the gate: a wrong pinned identity is caught by the
        # activation preflight's own identity probe BEFORE the pipeline starts
        # (the probe connection reports the live identity; the configured
        # sentinel mismatches) — {:error, :source_identity_mismatch}, fail
        # closed, value-free. The pre-B2 connect-time rejection path remains
        # for sources unreachable at activation (deferred verdict).
        assert {:error, %AshReplicant.Error{reason: reason}} =
                 AshReplicant.start_link(
                   sink: IdentitySink,
                   connection: Marquee.conn(),
                   publication: Marquee.publication(),
                   source_identity: [
                     system_identifier: sentinel_system,
                     database: sentinel_database
                   ],
                   go_forward_only: true
                 )

        assert reason in [:source_identity_mismatch, :preflight_failed]

        # UNGATED observer: any checkpoint read or write at ANY time — before
        # the verdict (the fail-open bug class) or after the halt — fails this
        # refute. A clean mismatched-identity activation touches the checkpoint
        # table zero times.
        refute_receive {:checkpoint_accessed, ^access_ref}, 500
      end)

    refute log =~ sentinel_system
    refute log =~ sentinel_database
  end

  # The pipeline's identity verdict, both polarities, plus the streaming-ready
  # signal.
  defp attach_identity_events do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:ash_replicant, :sink, :session_identity_accepted],
        [:replicant, :connection, :session_identity_rejected],
        [:replicant, :connection, :slot_active]
      ],
      fn event, _m, meta, _c ->
        send(test_pid, {:telemetry, ref, event, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  # Checkpoint-table access (read OR write) through Ecto query telemetry — the
  # metadata carries only the table source, never a row value. Deliberately
  # UNGATED: pre-verdict access is exactly the fail-open ordering bug this file
  # guards, so it must be observable, not filtered. No legitimate pre-verdict
  # checkpoint access exists in the covered configuration (go_forward_only:
  # true short-circuits Replicant's guard read; the connection reads the
  # checkpoint only after the identity check).
  defp attach_checkpoint_access do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ash_replicant, :test_repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "ash_replicant_checkpoints" do
          send(test_pid, {:checkpoint_accessed, ref})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp attach_applied do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ash_replicant, :sink, :applied],
      fn _event, measurements, metadata, _config ->
        send(
          test_pid,
          {:transaction_applied, ref, metadata[:commit_lsn], measurements[:change_count]}
        )
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end
end
