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
    IO.puts("FAILED: #{test.module} :: #{test.name}")
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
