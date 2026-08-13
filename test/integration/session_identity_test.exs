defmodule AshReplicant.SessionIdentityTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.Marquee
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

    @impl Replicant.Sink
    def handle_session_identity(identity, context) do
      send(:persistent_term.get({AshReplicant.SessionIdentityTest, :observer}), {
        :session_identity,
        identity,
        context
      })

      super(identity, context)
    end

    @impl Replicant.Sink
    def checkpoint do
      send(
        :persistent_term.get({AshReplicant.SessionIdentityTest, :observer}),
        :checkpoint_read
      )

      super()
    end
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
      :persistent_term.erase(@observer_key)
    end)

    :ok
  end

  test "the locked Hex package reports actual replication-session identity before checkpoint lookup" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _metadata, _config -> send(test_pid, {:slot_active, ref}) end,
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

    assert_receive {:session_identity, identity, context}, 15_000

    assert %Replicant.SessionIdentity{
             system_identifier: system_identifier,
             timeline_id: timeline_id,
             current_lsn: current_lsn,
             database: database
           } = identity

    assert system_identifier == expected_identity[:system_identifier]
    assert database == expected_identity[:database]
    assert is_integer(timeline_id) and timeline_id >= 0
    assert is_integer(current_lsn) and current_lsn >= 0
    assert context == %{slot_name: @slot, publication: [Marquee.publication()]}

    assert_receive :checkpoint_read, 1_000
    assert_receive {:slot_active, ^ref}, 15_000
  end
end
