defmodule AshReplicant.DoctorTaskTest do
  @moduledoc """
  The two operator commands: option parsing, the shared canonical report behind
  both output formats, and the real shell exit codes. The commands read only —
  they resolve the SAME start options the generated pipeline supervises with, so
  an operator never hand-copies a second configuration.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshReplicant.Doctor.Report
  alias Mix.Tasks.AshReplicant.Doctor, as: DoctorTask
  alias Mix.Tasks.AshReplicant.Preflight, as: PreflightTask

  defmodule TaskSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "task_diagnosis_slot"
  end

  defmodule ConfiguredPipeline do
    use AshReplicant.Pipeline, otp_app: :ash_replicant, sink: TaskSink
  end

  defmodule BarePipeline do
    use AshReplicant.Pipeline, otp_app: :ash_replicant, sink: TaskSink
  end

  @publication "task_sentinel_publication"
  @source_database "task_sentinel_db"

  setup do
    previous_pgdatabase = System.get_env("PGDATABASE")
    System.delete_env("PGDATABASE")

    Application.put_env(:ash_replicant, ConfiguredPipeline,
      # No resolvable `:database`: the probe classifies unreachable before a
      # pool exists, so the command stays silent and needs no substrate.
      connection: [hostname: "task-sentinel-host", username: "task_sentinel_role"],
      publication: @publication,
      source_identity: [system_identifier: "8888888888888888888", database: @source_database]
    )

    on_exit(fn ->
      Application.delete_env(:ash_replicant, ConfiguredPipeline)

      if previous_pgdatabase,
        do: System.put_env("PGDATABASE", previous_pgdatabase),
        else: System.delete_env("PGDATABASE")
    end)

    :ok
  end

  defp argv(extra \\ []), do: ["--pipeline", inspect(ConfiguredPipeline)] ++ extra

  describe "both commands resolve the pipeline's own start options" do
    test "preflight reports the preflight check set" do
      report = PreflightTask.report(argv())

      assert %Report{mode: :preflight} = report
      assert Enum.map(report.checks, & &1.name) == AshReplicant.Doctor.check_names(:preflight)
    end

    test "doctor reports the superset" do
      report = DoctorTask.report(argv())

      assert %Report{mode: :doctor} = report
      assert Enum.map(report.checks, & &1.name) == AshReplicant.Doctor.check_names(:doctor)
    end
  end

  describe "an undiagnosable invocation is exit 3" do
    test "a missing --pipeline names the missing flag, not a health verdict" do
      report = DoctorTask.report([])

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :pipeline_required}] = report.checks
    end

    test "a module that is not a generated pipeline is refused" do
      report = DoctorTask.report(["--pipeline", "Enum"])

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :pipeline_required}] = report.checks
    end

    test "an unloaded imposter is rejected without loading or invoking it" do
      imposter = AshReplicant.Test.UnadmittedPipeline
      load_count_key = {imposter, :load_count}
      start_options_key = {imposter, :start_options_called}
      load_count = :persistent_term.get(load_count_key, 0)

      :persistent_term.erase(start_options_key)
      :code.purge(imposter)
      :code.delete(imposter)
      refute Code.loaded?(imposter)

      on_exit(fn ->
        Code.ensure_loaded(imposter)
        :persistent_term.erase(start_options_key)
      end)

      report = DoctorTask.report(["--pipeline", inspect(imposter)])

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :pipeline_required}] = report.checks
      refute Code.loaded?(imposter)
      assert :persistent_term.get(load_count_key, 0) == load_count
      refute :persistent_term.get(start_options_key, false)
    end

    test "an unloaded generated pipeline is admitted from its BEAM marker" do
      pipeline = AshReplicant.Test.AdmittedPipeline

      :code.purge(pipeline)
      :code.delete(pipeline)
      refute Code.loaded?(pipeline)

      report = DoctorTask.report(["--pipeline", inspect(pipeline)])

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :pipeline_not_configured}] = report.checks
      assert Code.loaded?(pipeline)
    end

    test "an unconfigured pipeline is refused as unconfigured, not as unhealthy" do
      report = DoctorTask.report(["--pipeline", inspect(BarePipeline)])

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :pipeline_not_configured}] = report.checks
    end

    test "an unknown flag is refused" do
      report = DoctorTask.report(argv(["--wat", "1"]))

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :invalid_options}] = report.checks
    end
  end

  describe "both output formats render the same canonical report" do
    test "the default rendering is the operator text" do
      output = capture_io(fn -> catch_exit(PreflightTask.run(argv())) end)

      assert output =~ "ash_replicant preflight"
      assert output =~ "source_reachable"
      assert output =~ "exit_code=1"
    end

    test "--format json renders the machine map" do
      output = capture_io(fn -> catch_exit(PreflightTask.run(argv(["--format", "json"]))) end)

      assert {:ok, decoded} = Jason.decode(output)
      assert decoded["mode"] == "preflight"
      assert decoded["exit_code"] == 1

      names = Enum.map(decoded["checks"], & &1["name"])
      assert names == Enum.map(AshReplicant.Doctor.check_names(:preflight), &to_string/1)
    end

    test "the two formats agree on every check's status and reason" do
      report = PreflightTask.report(argv())
      json = capture_io(fn -> catch_exit(PreflightTask.run(argv(["--format", "json"]))) end)
      text = capture_io(fn -> catch_exit(PreflightTask.run(argv())) end)

      decoded = Jason.decode!(json)

      for check <- report.checks do
        entry = Enum.find(decoded["checks"], &(&1["name"] == to_string(check.name)))

        assert entry["status"] == to_string(check.status)
        assert entry["reason"] == to_string(check.reason)
        assert text =~ "#{check.name} status=#{check.status} reason=#{check.reason}"
      end
    end
  end

  describe "exit codes reach the shell" do
    test "a failing diagnosis exits 1" do
      capture_io(fn ->
        assert catch_exit(PreflightTask.run(argv())) == {:shutdown, 1}
      end)
    end

    test "an undiagnosable invocation exits 3, not 1" do
      capture_io(fn ->
        assert catch_exit(DoctorTask.run([])) == {:shutdown, 3}
      end)
    end

    test "an all-passing report exits 0 without shutting down" do
      report = Report.new(:preflight, [])

      assert report.exit_code == 0
      capture_io(fn -> assert DoctorTask.finish(report, "text") == :ok end)
    end

    test "a warning-only report exits 2" do
      warned = %AshReplicant.Doctor.Check{
        name: :slot_retention,
        domain: :slot,
        status: :warn,
        reason: :retention_at_risk
      }

      report = Report.new(:doctor, [warned])

      capture_io(fn ->
        assert catch_exit(DoctorTask.finish(report, "text")) == {:shutdown, 2}
      end)
    end
  end

  describe "the commands leak nothing" do
    test "no operator-supplied value reaches either format" do
      text = capture_io(fn -> catch_exit(DoctorTask.run(argv())) end)
      json = capture_io(fn -> catch_exit(DoctorTask.run(argv(["--format", "json"]))) end)

      for sentinel <- [
            "task-sentinel-host",
            "task_sentinel_role",
            @publication,
            "8888888888888888888",
            @source_database,
            "task_diagnosis_slot"
          ] do
        refute text =~ sentinel
        refute json =~ sentinel
      end
    end
  end
end
