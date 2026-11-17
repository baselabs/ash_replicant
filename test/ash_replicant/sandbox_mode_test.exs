defmodule AshReplicant.SandboxModeTest do
  @moduledoc """
  The TestRepo sandbox mode belongs to the whole pool, and ExUnit runs modules
  in a seeded random order, so a test that switches it without restoring it
  changes every module that happens to run later. Two integration modules did
  exactly that, and StatusLifecycleTest failed only on the seeds that ordered
  it after one of them. `AshReplicant.Test.PG.auto_sandbox!/0` pairs the
  switch with its restore; this test keeps it the only place a test switches.
  """

  use ExUnit.Case, async: true

  # The suite bootstrap migrates under :auto and leaves :manual before any
  # test; this file names the call it looks for.
  @allowed [
    "test/test_helper.exs",
    "test/support/pg.ex",
    "test/ash_replicant/sandbox_mode_test.exs"
  ]

  test "only the paired helper switches the TestRepo sandbox mode" do
    switching =
      "test/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.reject(&(&1 in @allowed))
      |> Enum.filter(&(&1 |> File.read!() |> String.contains?("Sandbox.mode(")))

    assert switching == []
  end
end
