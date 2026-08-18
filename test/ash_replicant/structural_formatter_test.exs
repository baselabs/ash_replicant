defmodule AshReplicant.StructuralFormatterTest do
  @moduledoc """
  The value-free battery receipt: a FAILED line must NAME the failing test and
  locate the failing ASSERTION by the first project frame of its stacktrace —
  module+name alone cannot say which assert of a multi-assert marquee tripped,
  which is exactly the diagnostic the intermittent-red investigations needed.
  The line stays structural: authored names plus a file:line, never row data.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.StructuralFormatter

  describe "failed_line/1" do
    test "names module and test and appends the first project frame" do
      failure = %{
        reason: :assertion,
        trace: [
          {ExUnit.Assertions, :assert, 2,
           [file: ~c"lib/ex_unit/lib/ex_unit/assertions.ex", line: 71]},
          {AshReplicant.SnapshotPipelineTest, :"-test an incomplete.../1-fun-0-", 1,
           [file: ~c"test/integration/snapshot_pipeline_test.exs", line: 175]}
        ]
      }

      event = %ExUnit.Test{
        module: AshReplicant.SnapshotPipelineTest,
        name: :"test an incomplete v1 snapshot halts until operator reset",
        state: {:failed, [failure]}
      }

      assert StructuralFormatter.failed_line(event) ==
               "FAILED: Elixir.AshReplicant.SnapshotPipelineTest :: " <>
                 "test an incomplete v1 snapshot halts until operator reset " <>
                 "(test/integration/snapshot_pipeline_test.exs:175)"
    end

    test "a stacktrace with no project frame still names the test, with no site" do
      failure = %{
        reason: :assertion,
        trace: [
          {ExUnit.Assertions, :assert, 2, [file: ~c"lib/ex_unit/assertions.ex", line: 71]}
        ]
      }

      event = %ExUnit.Test{
        module: AshReplicant.StartLinkTest,
        name: :"test no project frames",
        state: {:failed, [failure]}
      }

      assert StructuralFormatter.failed_line(event) ==
               "FAILED: Elixir.AshReplicant.StartLinkTest :: test no project frames"
    end

    test "skips earlier project frames from dependencies, keeps the first repo frame" do
      failure = %{
        reason: :assertion,
        trace: [
          {:erl_eval, :do_apply, 6, [file: ~c"erl_eval.erl", line: 1]},
          {AshReplicant.Impl, :handle_snapshot, 2,
           [file: ~c"lib/ash_replicant/sink/impl.ex", line: 465]},
          {SomeDep.Helper, :run, 1, [file: ~c"deps/some_dep/lib/helper.ex", line: 9]}
        ]
      }

      event = %ExUnit.Test{
        module: AshReplicant.SinkTest,
        name: :"test dep frames are skipped",
        state: {:failed, [failure]}
      }

      assert StructuralFormatter.failed_line(event) ==
               "FAILED: Elixir.AshReplicant.SinkTest :: test dep frames are skipped " <>
                 "(lib/ash_replicant/sink/impl.ex:465)"
    end
  end
end
