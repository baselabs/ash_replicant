defmodule AshReplicant.StructuralFormatterTest do
  @moduledoc """
  The value-free battery receipt: a FAILED line must NAME the failing test,
  locate the failing assertion by the first project frame of its stacktrace,
  and say what kind of failure it was. Module and name alone cannot say which
  assert of a multi-assert marquee tripped. The line stays structural:
  authored names, a file:line and a failure class, never row data.

  The failures here are the `{kind, reason, stacktrace}` tuples ExUnit
  reports, captured from real raises and exits rather than written by hand.
  The formatter once read a map shape ExUnit never produces, and every real
  failure printed "(no repo frame)" while hand-written fixtures passed.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.StructuralFormatter

  describe "failed_line/1" do
    test "names module and test, appends the first project frame and the class" do
      {failure, line} = capture_raise()

      assert StructuralFormatter.failed_line(failed(failure)) ==
               "FAILED: Elixir.AshReplicant.StructuralFormatterTest :: test captured " <>
                 "(test/ash_replicant/structural_formatter_test.exs:#{line}; " <>
                 "error ExUnit.AssertionError)"
    end

    test "an exception's values never reach the line" do
      secret = "postgres://operator:do-not-print@example.invalid/source"

      failure =
        try do
          raise ArgumentError, secret
        rescue
          error -> {:error, error, __STACKTRACE__}
        end

      line = StructuralFormatter.failed_line(failed(failure))

      refute line =~ secret
      assert line =~ "; error ArgumentError)"
    end

    test "a linked exit with no project frame names its absence and its class" do
      # ExUnit reports a test killed by a linked process as {{:EXIT, pid},
      # reason, []}. The exit reason is a runtime value and stays out.
      failure = {{:EXIT, self()}, {:shutdown, "do-not-print"}, []}

      line = StructuralFormatter.failed_line(failed(failure))

      assert line ==
               "FAILED: Elixir.AshReplicant.StructuralFormatterTest :: test captured " <>
                 "(no repo frame; linked exit)"
    end

    test "a timeout names ExUnit's timeout error" do
      failure = {:error, %ExUnit.TimeoutError{timeout: 60_000, type: "test"}, []}

      assert StructuralFormatter.failed_line(failed(failure)) =~
               "(no repo frame; error ExUnit.TimeoutError)"
    end

    test "skips dependency and OTP frames, keeps the first repo frame" do
      failure =
        {:error, %RuntimeError{message: "x"},
         [
           {:erl_eval, :do_apply, 6, [file: ~c"erl_eval.erl", line: 1]},
           {AshReplicant.Impl, :handle_snapshot, 2,
            [file: ~c"lib/ash_replicant/sink/impl.ex", line: 465]},
           {SomeDep.Helper, :run, 1, [file: ~c"deps/some_dep/lib/helper.ex", line: 9]}
         ]}

      assert StructuralFormatter.failed_line(failed(failure)) ==
               "FAILED: Elixir.AshReplicant.StructuralFormatterTest :: test captured " <>
                 "(lib/ash_replicant/sink/impl.ex:465; error RuntimeError)"
    end

    test "the site and class come from the first failure that has a repo frame" do
      {located, line} = capture_raise()
      thrown = {:throw, :value, [{:erl_eval, :do_apply, 6, [file: ~c"erl_eval.erl", line: 1]}]}

      assert StructuralFormatter.failed_line(failed([thrown, located])) =~
               "(test/ash_replicant/structural_formatter_test.exs:#{line}; " <>
                 "error ExUnit.AssertionError)"
    end
  end

  defp failed(failures) do
    %ExUnit.Test{
      module: __MODULE__,
      name: :"test captured",
      state: {:failed, List.wrap(failures)}
    }
  end

  defp capture_raise do
    line = __ENV__.line + 3

    try do
      assert 1 + 1 == 3
    rescue
      error -> {{:error, error, __STACKTRACE__}, line}
    end
  end
end
