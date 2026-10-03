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

      # A no-sandbox test may hold ONE long auto-mode checkout — the
      # consumer-upgrade test drives a locked migration transaction that
      # runs minutes under load. The ownership sanity clock defaults to
      # 120s, BELOW these tests' own ceilings, and its expiry both kills
      # the connection and fires the [error] line the value-free battery
      # gate counts (observed twice: the starved full suite and a normal
      # battery run, 2026-10-02). Bind the ownership window to the test's
      # own timeout so the sanity check outlives the work it guards; the
      # checkout is `sandbox: false` so committed state stays visible to
      # other connections — the reason these tests run no-sandbox at all.
      :ok =
        Sandbox.checkout(AshReplicant.TestRepo,
          sandbox: false,
          ownership_timeout: tags[:timeout] || 120_000
        )

      on_exit(fn ->
        :ok = Sandbox.checkin(AshReplicant.TestRepo)
        Sandbox.mode(AshReplicant.TestRepo, :manual)
      end)
    else
      pid = Sandbox.start_owner!(AshReplicant.TestRepo, shared: not tags[:async])
      on_exit(fn -> Sandbox.stop_owner(pid) end)
    end

    :ok
  end
end
