defmodule AshReplicant.DataCase do
  @moduledoc "ExUnit case for tests that touch AshReplicant.TestRepo."
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias AshReplicant.TestRepo
      import Ecto.Adapters.SQL.Sandbox, only: [checkout: 1]
    end
  end

  setup tags do
    if tags[:no_sandbox] do
      :ok = Sandbox.mode(AshReplicant.TestRepo, :auto)
      on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)
    else
      pid = Sandbox.start_owner!(AshReplicant.TestRepo, shared: not tags[:async])
      on_exit(fn -> Sandbox.stop_owner(pid) end)
    end

    :ok
  end
end
