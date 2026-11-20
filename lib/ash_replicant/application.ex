defmodule AshReplicant.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AshReplicant.Owners},
      AshReplicant.Lease,
      {DynamicSupervisor, name: AshReplicant.PipelineGuards, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AshReplicant.Supervisor)
  end

  @impl true
  def prep_stop(state) do
    # Close activation before draining the slots that could still be creating
    # owners. The registry and census deadlines remain alive throughout drain.
    slots = AshReplicant.Lease.close()
    Enum.each(registered_owners(), &Process.exit(&1, :shutdown))

    for slot <- slots do
      AshReplicant.Lease.with(slot, :exclusive, fn -> :ok end)
    end

    guards =
      for {_id, pid, _type, _modules} <-
            DynamicSupervisor.which_children(AshReplicant.PipelineGuards) do
        {pid, Process.monitor(pid)}
      end

    Enum.each(registered_owners(), &AshReplicant.PipelineOwner.stop/1)

    for {pid, monitor} <- guards do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      end
    end

    state
  end

  defp registered_owners,
    do: Registry.select(AshReplicant.Owners, [{{:"$1", :_, :_}, [], [:"$1"]}])
end
