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
    pid = Sandbox.start_owner!(AshReplicant.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
