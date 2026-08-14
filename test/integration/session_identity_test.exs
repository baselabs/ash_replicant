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
  # Opens only when the pipeline has REPORTED its identity verdict — every
  # checkpoint-table access BEFORE the verdict (the fail-open bug class) is
  # therefore invisible-by-design only in the sense that it cannot open the gate;
  # the first-message assert below fails if the verdict is not first.
  @identity_verdict_key {__MODULE__, :identity_verdict}

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
    :persistent_term.erase(@identity_verdict_key)

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.teardown_schema!()
      :persistent_term.erase(@identity_verdict_key)
    end)

    :ok
  end

  test "the locked Hex package reports actual replication-session identity before checkpoint lookup" do
    identity_ref = attach_identity_events(@identity_verdict_key)
    access_ref = attach_checkpoint_access(@identity_verdict_key)
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

    # The identity verdict must be the FIRST reported event: any earlier
    # checkpoint-table access would have opened the gate and put its message
    # in the mailbox ahead of this one.
    receive do
      message ->
        assert message ==
                 {:telemetry, identity_ref, [:ash_replicant, :sink, :session_identity_accepted],
                  %{}}
    after
      15_000 -> flunk("session identity was not accepted")
    end

    assert_receive {:checkpoint_accessed, ^access_ref}, 1_000

    assert_receive {:telemetry, ^identity_ref, [:replicant, :connection, :slot_active], %{}},
                   15_000

    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('identity-1', 'accepted')")

    assert_receive {:transaction_applied, ^applied_ref, commit_lsn, 1}, 15_000
    assert is_integer(commit_lsn) and commit_lsn > 0

    PG.wait_until(fn -> Marquee.mirror_rows() == [["identity-1", "accepted"]] end)
  end

  test "a wrong actual-session expectation halts before checkpoint lookup and stays value-free" do
    identity_ref = attach_identity_events(@identity_verdict_key)
    access_ref = attach_checkpoint_access(@identity_verdict_key)

    sentinel_system = "sentinel-wrong-system"
    sentinel_database = "sentinel-wrong-database"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _pid} =
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

        assert_receive {:telemetry, ^identity_ref,
                        [:replicant, :connection, :session_identity_rejected],
                        %{reason: :session_identity_rejected}},
                       15_000

        # The gate opened at the rejection verdict, so this refute is live: any
        # checkpoint read or write from here on (read OR upsert) is the fail-open
        # bug class. A clean halt touches the checkpoint table zero times.
        refute_receive {:checkpoint_accessed, ^access_ref}, 500
      end)

    refute log =~ sentinel_system
    refute log =~ sentinel_database
  end

  # The pipeline's identity verdict, both polarities, plus the streaming-ready
  # signal. The verdict opens the checkpoint-access gate.
  defp attach_identity_events(verdict_key) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:ash_replicant, :sink, :session_identity_accepted],
        [:replicant, :connection, :session_identity_rejected],
        [:replicant, :connection, :slot_active]
      ],
      fn
        [:ash_replicant, :sink, :session_identity_accepted] = event, _m, meta, _c ->
          verdict(verdict_key)
          send(test_pid, {:telemetry, ref, event, meta})

        [:replicant, :connection, :session_identity_rejected] = event, _m, meta, _c ->
          verdict(verdict_key)
          send(test_pid, {:telemetry, ref, event, meta})

        event, _m, meta, _c ->
          send(test_pid, {:telemetry, ref, event, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp verdict(verdict_key), do: :persistent_term.put(verdict_key, true)

  # Checkpoint-table access (read OR write) through Ecto query telemetry — the
  # metadata carries only the table source, never a row value. Gated on the
  # identity verdict so pre-verdict activation noise cannot satisfy the assert.
  defp attach_checkpoint_access(verdict_key) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:ash_replicant, :test_repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "ash_replicant_checkpoints" and
             :persistent_term.get(verdict_key, false) do
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
