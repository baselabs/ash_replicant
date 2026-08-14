defmodule AshReplicant.SessionIdentityTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.Marquee
  alias AshReplicant.Test.PG
  alias Ecto.Adapters.SQL.Sandbox

  @slot "identity_order_slot"
  @observer_key {__MODULE__, :observer}

  defmodule IdentitySink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "identity_order_slot"

    defp __ash_replicant_effect__(:checkpoint, [], config) do
      send(
        :persistent_term.get({AshReplicant.SessionIdentityTest, :observer}),
        :checkpoint_read
      )

      super(:checkpoint, [], config)
    end

    defp __ash_replicant_effect__(:transaction, [transaction], config) do
      send(
        :persistent_term.get({AshReplicant.SessionIdentityTest, :observer}),
        {:transaction_delivered, transaction.commit_lsn}
      )

      super(:transaction, [transaction], config)
    end

    defp __ash_replicant_effect__(operation, arguments, config),
      do: super(operation, arguments, config)
  end

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
    :persistent_term.put(@observer_key, self())

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.teardown_schema!()
      :persistent_term.erase(@observer_key)
    end)

    :ok
  end

  test "the locked Hex package reports actual replication-session identity before checkpoint lookup" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:ash_replicant, :sink, :session_identity_accepted],
        [:replicant, :connection, :slot_active]
      ],
      fn event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry, ref, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    expected_identity = Marquee.source_identity()

    assert {:ok, _pid} =
             AshReplicant.start_link(
               sink: IdentitySink,
               connection: Marquee.conn(),
               publication: Marquee.publication(),
               source_identity: expected_identity,
               go_forward_only: true
             )

    receive do
      message ->
        assert message ==
                 {:telemetry, ref, [:ash_replicant, :sink, :session_identity_accepted], %{}}
    after
      15_000 -> flunk("session identity was not accepted")
    end

    receive do
      message -> assert message == :checkpoint_read
    after
      1_000 -> flunk("checkpoint was not read after identity acceptance")
    end

    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('identity-1', 'accepted')")
    assert_receive {:transaction_delivered, commit_lsn}, 15_000
    assert is_integer(commit_lsn) and commit_lsn > 0
    PG.wait_until(fn -> Marquee.mirror_rows() == [["identity-1", "accepted"]] end)
  end

  test "a wrong actual-session expectation halts before checkpoint lookup and stays value-free" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :session_identity_rejected],
      fn event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry, ref, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

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

        assert_receive {:telemetry, ^ref, [:replicant, :connection, :session_identity_rejected],
                        %{reason: :session_identity_rejected}},
                       15_000

        refute_receive :checkpoint_read, 500
      end)

    refute log =~ sentinel_system
    refute log =~ sentinel_database
  end
end
