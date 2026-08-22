defmodule Mix.Tasks.AshReplicant.Diagnosis do
  @moduledoc false
  # The shared body of `mix ash_replicant.preflight` and
  # `mix ash_replicant.doctor`. Both commands resolve the SAME start options the
  # generated pipeline supervises with, run the same read-only diagnosis, and
  # render the one canonical report — so the two commands cannot drift, and
  # neither can drift from the pipeline it diagnoses.

  alias AshReplicant.Doctor
  alias AshReplicant.Doctor.Report

  @switches [pipeline: :string, format: :string]

  @formats ~w(text json)

  @doc "Build the report for an argv, without rendering or exiting."
  @spec report(Report.mode(), [String.t()]) :: Report.t()
  def report(mode, argv) do
    case options(argv) do
      {:ok, pipeline, _format} -> diagnose(mode, pipeline)
      {:error, reason} -> Report.invalid(reason)
    end
  end

  @doc "The requested output format, defaulting to the operator text."
  @spec format([String.t()]) :: String.t()
  def format(argv) do
    case options(argv) do
      {:ok, _pipeline, format} -> format
      {:error, _reason} -> "text"
    end
  end

  @doc "Run one command after starting only its PostgreSQL client runtime."
  @spec execute(Report.mode(), [String.t()]) :: :ok | no_return()
  def execute(mode, argv) do
    report =
      case Application.ensure_all_started(:postgrex) do
        {:ok, _applications} -> report(mode, argv)
        {:error, _reason} -> Report.invalid(:runtime_dependencies_unavailable)
      end

    finish(report, format(argv))
  end

  @doc """
  Render the report and hand its exit code to the shell. A passing report
  returns `:ok`; anything else exits with the report's code so a monitoring
  caller can branch on it.
  """
  @spec finish(Report.t(), String.t()) :: :ok | no_return()
  def finish(%Report{} = report, format) do
    if report.exit_code == 0 do
      render(report, format)
      :ok
    else
      render(report, format)
      exit({:shutdown, report.exit_code})
    end
  end

  defp render(report, "json"), do: report |> Report.to_map() |> Jason.encode!() |> IO.puts()
  defp render(report, _text), do: report |> Report.to_text() |> IO.write()

  defp options(argv) do
    {parsed, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      invalid != [] or rest != [] -> {:error, :invalid_options}
      Keyword.get(parsed, :format, "text") not in @formats -> {:error, :invalid_options}
      true -> admit_pipeline(parsed)
    end
  end

  defp admit_pipeline(parsed) do
    format = Keyword.get(parsed, :format, "text")

    case Keyword.get(parsed, :pipeline) do
      name when is_binary(name) and name != "" ->
        {:ok, resolve_module(name), format}

      _missing ->
        {:error, :pipeline_required}
    end
  end

  defp resolve_module(name) do
    name |> String.trim_leading("Elixir.") |> String.split(".") |> Module.concat()
  end

  # A generated `AshReplicant.Pipeline` exposes its own admitted start options —
  # sink included — so the command never asks the operator to restate
  # configuration the application already carries.
  defp diagnose(mode, pipeline) do
    # `resolve_module/1` always yields an atom, so the only real question is
    # whether that atom is a loadable module exposing the generated pipeline's
    # own start options.
    if Code.ensure_loaded?(pipeline) and function_exported?(pipeline, :start_options, 0) do
      start_options(mode, pipeline)
    else
      Report.invalid(:pipeline_required)
    end
  end

  defp start_options(mode, pipeline) do
    case pipeline.start_options() do
      {:ok, options} -> Doctor.run(mode, options)
      :not_configured -> Report.invalid(:pipeline_not_configured)
    end
  rescue
    # A present-but-incomplete configuration RAISES by design
    # (`AshReplicant.Pipeline`), naming keys and never values. The command turns
    # that into its own structural refusal rather than re-raising an exception
    # whose message it did not compose.
    _error -> Report.invalid(:pipeline_config_invalid)
  catch
    _kind, _reason -> Report.invalid(:pipeline_config_invalid)
  end
end

defmodule Mix.Tasks.AshReplicant.Doctor do
  @shortdoc "Diagnose a deployed AshReplicant pipeline, read-only"

  @moduledoc """
  #{@shortdoc}

      mix ash_replicant.doctor --pipeline MyApp.Replicant.Pipeline [--format json]

  Everything `mix ash_replicant.preflight` covers, plus the durable state a
  deployed pipeline has: checkpoint state (an envelope that will not decode
  fails closed), contract drift through the same set-monotone classifier
  activation binds with, and runtime readiness.

  Runtime readiness is NODE-LOCAL. This command runs in its own OS process and
  therefore always reports the generation absent; call `AshReplicant.doctor/1`
  from inside the running application for the real answer.

  ## It performs no writes

  Every source statement passes a fail-closed read-only admission, the probe
  connection is opened `default_transaction_read_only=on`, and the checkpoint is
  read through its own `:read` action with no lock. The command never starts a
  repo, a pipeline, or a service.

  ## Output

  Both formats render the ONE canonical result, so a human and a machine reader
  cannot be told different things. Reasons come from a closed vocabulary and no
  connection option, publication name, source identity, slot name, watermark, or
  row value ever appears.

  ## Exit codes

    * `0` — every check passed.
    * `1` — at least one check failed.
    * `2` — warnings only.
    * `3` — the invocation could not be diagnosed (missing or unconfigured
      `--pipeline`, unknown flag). Distinct from `1` so a monitoring caller can
      tell an unhealthy deployment from a bad invocation.
  """

  use Mix.Task

  alias Mix.Tasks.AshReplicant.Diagnosis

  @doc false
  @spec report([String.t()]) :: AshReplicant.Doctor.Report.t()
  def report(argv), do: Diagnosis.report(:doctor, argv)

  @doc false
  defdelegate finish(report, format), to: Diagnosis

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    Diagnosis.execute(:doctor, argv)
  end
end
