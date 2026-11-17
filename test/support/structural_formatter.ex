defmodule AshReplicant.StructuralFormatter do
  @moduledoc false
  use GenServer

  @initial %{passed: 0, failed: 0, skipped: 0, excluded: 0, invalid: 0}

  @impl true
  def init(_options), do: {:ok, @initial}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: nil}}, counts) do
    {:noreply, increment(counts, :passed)}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _}}}, counts) do
    {:noreply, increment(counts, :excluded)}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:skipped, _}}}, counts) do
    {:noreply, increment(counts, :skipped)}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:invalid, _}}}, counts) do
    {:noreply, increment(counts, :invalid)}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, _}} = test}, counts) do
    # Test NAMES are authored structural metadata (never row data) — print
    # them so a failing test is identifiable in the value-free battery
    # output; counts alone made intermittent CI failures unattributable.
    # Plain line, no ANSI: the runner anchors on "^FAILED: ".
    IO.puts(failed_line(test))
    {:noreply, increment(counts, :failed)}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{state: {:failed, _}} = mod}, counts) do
    IO.puts("FAILED: #{mod.name} (module)")
    {:noreply, increment(counts, :failed)}
  end

  def handle_cast({:suite_finished, _times}, counts) do
    IO.puts(format_result(counts))
    {:noreply, counts}
  end

  def handle_cast(_event, counts), do: {:noreply, counts}

  @doc """
  The value-free FAILED receipt: authored module + test name, the first
  stack frame from THIS repo's own code, and the failure's class. Module +
  name alone cannot say WHICH assert of a multi-assert marquee tripped. A
  file:line is authored structure, never a row value; dependency and OTP
  frames are skipped. Repo frames are identified by the app's module
  namespace, not by path prefixes: dependency sources also live under
  `lib/`-shaped paths (e.g. ExUnit's own assertions frame).

  The class is the failure kind (`error`, `exit`, `throw`, or `linked exit`
  when a linked process took the test down) plus the exception module when
  the reason is an exception. Both are authored structure; the reason's own
  values are never printed.

  ExUnit reports each failure as a `{kind, reason, stacktrace}` tuple. The
  site and class come from the first failure that carries a repo frame, else
  from the first failure.
  """
  @app_namespace "AshReplicant"

  @spec failed_line(ExUnit.Test.t()) :: String.t()
  def failed_line(%ExUnit.Test{module: module, name: name, state: {:failed, failures}}) do
    base = "FAILED: #{module} :: #{name}"
    failures = List.wrap(failures)

    located =
      Enum.find_value(failures, fn failure ->
        with {file, line} <- project_frame(failure), do: {"#{file}:#{line}", failure}
      end)

    {site, failure} = located || {"no repo frame", List.first(failures)}

    case failure_class(failure) do
      nil -> base <> " (#{site})"
      class -> base <> " (#{site}; #{class})"
    end
  end

  defp project_frame({_kind, _reason, trace}) when is_list(trace) do
    Enum.find_value(trace, &repo_frame/1)
  end

  defp project_frame(_other), do: nil

  defp failure_class({kind, reason, _trace}) do
    case {kind_name(kind), exception_name(reason)} do
      {nil, _exception} -> nil
      {kind, nil} -> kind
      {kind, exception} -> "#{kind} #{exception}"
    end
  end

  defp failure_class(_other), do: nil

  defp kind_name(kind) when kind in [:error, :exit, :throw], do: Atom.to_string(kind)
  defp kind_name({:EXIT, _pid}), do: "linked exit"
  defp kind_name(_other), do: nil

  defp exception_name(%{__exception__: true, __struct__: module}), do: inspect(module)
  defp exception_name(_reason), do: nil

  defp repo_frame({module, _fun, _arity, file_info})
       when is_atom(module) and is_list(file_info) do
    with true <- module_namespaced?(module),
         {:ok, raw} <- Keyword.fetch(file_info, :file),
         {:ok, line} when is_integer(line) <- Keyword.fetch(file_info, :line),
         {:ok, file} when is_binary(file) <- normalize_file(raw) do
      {file, line}
    else
      _ -> nil
    end
  end

  defp repo_frame(_other), do: nil

  defp module_namespaced?(module) do
    # inspect/1 renders Elixir modules without the "Elixir." prefix that
    # Atom.to_string/1 keeps; Erlang modules stay as bare names.
    module |> inspect() |> String.starts_with?(@app_namespace <> ".")
  end

  # Erlang stacktrace files are charlists; synthesized events may carry binaries.
  defp normalize_file(file) when is_list(file), do: {:ok, List.to_string(file)}
  defp normalize_file(file) when is_binary(file), do: {:ok, file}
  defp normalize_file(_other), do: :error

  defp increment(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp format_result(counts) do
    details =
      [
        {:passed, "passed"},
        {:failed, "failed"},
        {:skipped, "skipped"},
        {:excluded, "excluded"},
        {:invalid, "invalid"}
      ]
      |> Enum.flat_map(fn {key, label} ->
        case Map.fetch!(counts, key) do
          0 -> []
          count -> ["#{count} #{label}"]
        end
      end)

    "Result: " <> Enum.join(details, ", ")
  end
end
