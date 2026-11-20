defmodule AshReplicant.Test.LeaseEvents do
  @moduledoc false

  # Observe the registry's actual queue acknowledgement through OTP's system
  # debug seam. Receiving it proves stop has reached the contested lease;
  # no elapsed-time guess or production-only testing hook is involved.
  def attach do
    :ok = :sys.install(AshReplicant.Lease, {&__MODULE__.event/3, self()})

    ExUnit.Callbacks.on_exit(fn ->
      :sys.remove(AshReplicant.Lease, &__MODULE__.event/3)
    end)
  end

  def event(observer, {:out, {:queued, _ticket}, {pid, _tag}, _state}, _server) do
    send(observer, {:lease_queued, pid})
    observer
  end

  def event(observer, _event, _server), do: observer
end
