defmodule Mix.Tasks.AshReplicant.Preflight do
  @shortdoc "Check whether an AshReplicant pipeline may start, read-only"

  @moduledoc """
  #{@shortdoc}

      mix ash_replicant.preflight --pipeline MyApp.Replicant.Pipeline [--format json]

  Answers *may this pipeline start?* without starting it and without writing
  anything: dependency requirements, sink configuration, destination admission,
  source reachability, PostgreSQL release, the connecting role's privileges,
  source identity, strict source coverage, replica identity, slot shape, and the
  retention horizon.

  It never reads a checkpoint, so it is correct BEFORE the first activation —
  run it against a fresh install. Use `mix ash_replicant.doctor` once the
  pipeline is deployed, for the durable-state classes as well.

  ## It performs no writes

  Every source statement passes a fail-closed read-only admission, and the probe
  connection is opened `default_transaction_read_only=on`. The command never
  starts a repo, a pipeline, or a service.

  ## Output

  Both formats render the ONE canonical result. Reasons come from a closed
  vocabulary and no connection option, publication name, source identity, slot
  name, or row value ever appears. Anything the command could not judge — an
  unreachable source, an unavailable destination — is reported `:skipped` with
  the reason it could not be judged, never passed.

  ## Exit codes

    * `0` — every check passed.
    * `1` — at least one check failed.
    * `2` — warnings only.
    * `3` — the invocation could not be diagnosed (missing or unconfigured
      `--pipeline`, unknown flag).
  """

  use Mix.Task

  alias Mix.Tasks.AshReplicant.Diagnosis

  @doc false
  @spec report([String.t()]) :: AshReplicant.Doctor.Report.t()
  def report(argv), do: Diagnosis.report(:preflight, argv)

  @doc false
  defdelegate finish(report, format), to: Diagnosis

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    argv
    |> report()
    |> Diagnosis.finish(Diagnosis.format(argv))
  end
end
