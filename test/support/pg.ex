defmodule AshReplicant.Test.PG do
  @moduledoc "Live-PG16 gating, the committing-sandbox switch, and a condition poller for the integration marquee."

  @doc "True iff the live substrate URL is set (gates `:integration` tests)."
  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env("ASH_REPLICANT_TEST_URL") not in [nil, ""]

  @doc """
  Run the calling test against real, committing pooled connections: switch
  the TestRepo sandbox to `:auto` and restore the suite's `:manual` when the
  test exits. The pipeline's own processes write through the shared repo, and
  logical replication only sees committed source rows; neither works under
  `:manual`.

  The mode belongs to the whole pool, not the test, and ExUnit runs modules
  in a seeded random order. A switch without its restore therefore changes
  every module that happens to run later. StatusLifecycleTest's durable-leg
  test failed that way whenever a seed put it after a module that left
  `:auto` behind. This is the one place the switch happens, so the two cannot
  be separated.

  Call it before registering cleanups that query TestRepo: ExUnit runs
  `on_exit` callbacks last-registered first, so the restore runs after them.
  """
  @spec auto_sandbox!() :: :ok
  def auto_sandbox! do
    :ok = Ecto.Adapters.SQL.Sandbox.mode(AshReplicant.TestRepo, :auto)

    ExUnit.Callbacks.on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(AshReplicant.TestRepo, :manual)
    end)

    :ok
  end

  @doc "Poll `fun` every 25ms up to `tries` times, else flunk."
  @spec wait_until((-> boolean()), pos_integer()) :: :ok
  def wait_until(fun, tries \\ 400) do
    cond do
      fun.() ->
        :ok

      tries <= 0 ->
        ExUnit.Assertions.flunk("wait_until: condition never became true")

      true ->
        Process.sleep(25)
        wait_until(fun, tries - 1)
    end
  end
end
