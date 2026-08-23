defmodule AshReplicant.TelemetryExamplesTest do
  @moduledoc """
  O03 acceptance: the OpenTelemetry and metrics examples shipped in
  `AshReplicant.Telemetry`'s moduledoc are EXECUTABLE — each fenced elixir
  block is extracted verbatim from the module source (the README-tie pattern),
  evaluated, and driven once through the real public event surface. An example
  that cannot run is documentation drift, not an example.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Telemetry

  @source_path "lib/ash_replicant/telemetry.ex"

  defp moduledoc_source do
    source = File.read!(@source_path)

    doc =
      Regex.run(~r/@moduledoc """\n(.*?)\n  """/s, source)
      |> case do
        [_match, doc] -> doc
        nil -> flunk("the telemetry moduledoc heredoc was not found in #{@source_path}")
      end

    doc
  end

  defp elixir_blocks(doc) do
    ~r/```elixir\n(.*?)```/s
    |> Regex.scan(doc)
    |> Enum.map(fn [_match, block] -> block end)
  end

  describe "the moduledoc example blocks exist and are evaluable" do
    test "exactly two example blocks ship (metrics + OpenTelemetry bridge)" do
      blocks = elixir_blocks(moduledoc_source())

      assert length(blocks) == 2,
             "expected the metrics and OTel example blocks, got #{length(blocks)}"
    end
  end

  describe "the metrics example attaches to the emitted inventory and counts" do
    test "the block evaluates, attaches, and observes a driven event" do
      [metrics_block, _otel_block] = elixir_blocks(moduledoc_source())

      Code.eval_string(metrics_block, [], file: "telemetry_moduledoc_metrics_example.exs")

      before = MyApp.ReplicantMetrics.deliveries()

      assert :ok =
               Telemetry.event([:ash_replicant, :sink, :applied], %{count: 1}, %{commit_lsn: 1})

      assert MyApp.ReplicantMetrics.deliveries() == before + 1
    after
      if function_exported?(MyApp.ReplicantMetrics, :detach, 0),
        do: MyApp.ReplicantMetrics.detach()
    end
  end

  describe "the OpenTelemetry bridge example maps every emitted event" do
    test "the block evaluates and the mapping table is exactly the emitted inventory" do
      [_metrics_block, otel_block] = elixir_blocks(moduledoc_source())

      Code.eval_string(otel_block, [], file: "telemetry_moduledoc_otel_example.exs")

      # fetch!/1 raises on an unmapped event: iterating the emitted inventory
      # through the mapping proves the bridge covers EVERY event name the
      # library can emit — a new emission without a mapping reds here.
      for event <- Telemetry.emitted_event_names() do
        assert is_atom(MyApp.ReplicantOTel.span_name(event)),
               "the OTel example has no span mapping for #{inspect(event)}"
      end

      MyApp.ReplicantOTel.attach()

      assert :ok =
               Telemetry.event([:ash_replicant, :census, :passed], %{duration: 1}, %{
                 slot_name: "slot"
               })

      assert MyApp.ReplicantOTel.span_name([:ash_replicant, :census, :passed]) != nil
    after
      if function_exported?(MyApp.ReplicantOTel, :detach, 0), do: MyApp.ReplicantOTel.detach()
    end
  end
end
