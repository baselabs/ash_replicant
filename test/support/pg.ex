defmodule AshReplicant.Test.PG do
  @moduledoc "Live-PG16 gating + a condition poller for the integration marquee."

  @doc "True iff the live substrate URL is set (gates `:integration` tests)."
  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env("ASH_REPLICANT_TEST_URL") not in [nil, ""]

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
