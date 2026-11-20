defmodule AshReplicant.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AshReplicant.Lease,
      {DynamicSupervisor, name: AshReplicant.PipelineGuards, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AshReplicant.Supervisor)
  end
end
