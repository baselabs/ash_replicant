defmodule AshReplicant.DoctorRunTest do
  @moduledoc """
  The end-to-end shape of a diagnosis run: option admission (and its own exit
  code), the ordered check set per mode, honest `:skipped` results when a leg
  could not be judged, and the value-free guarantee over BOTH renderings with
  secret-shaped sentinels in every operator-supplied field.

  No database: the source connection carries no resolvable `:database`, which is
  the same admission `AshReplicant.Coverage` uses to classify an unreachable
  source BEFORE a pool exists — silent, and no wall-clock burn.
  """
  use ExUnit.Case, async: false

  alias AshReplicant.Doctor
  alias AshReplicant.Doctor.Report
  alias AshReplicant.Test.AdmittedGeneration

  defmodule DiagnosisSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "diagnosis_slot"
  end

  # Secret-shaped sentinels in every operator-supplied field. None may reach
  # either rendering.
  @hostname "sentinel-host.internal"
  @username "sentinel_role"
  @password "sentinel-password"
  @publication "sentinel_publication"
  @system_identifier "9999999999999999999"
  @source_database "sentinel_source_db"

  @sentinels [
    @hostname,
    @username,
    @password,
    @publication,
    @system_identifier,
    @source_database,
    "diagnosis_slot"
  ]

  setup do
    previous = System.get_env("PGDATABASE")
    System.delete_env("PGDATABASE")
    :persistent_term.erase({AshReplicant, "diagnosis_slot"})

    on_exit(fn ->
      :persistent_term.erase({AshReplicant, "diagnosis_slot"})

      if previous,
        do: System.put_env("PGDATABASE", previous),
        else: System.delete_env("PGDATABASE")
    end)

    :ok
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        sink: DiagnosisSink,
        # No `:database` key: postgrex's own resolution yields nil, so the probe
        # classifies unreachable without starting a pool.
        connection: [hostname: @hostname, username: @username, password: @password],
        publication: @publication,
        source_identity: [system_identifier: @system_identifier, database: @source_database]
      ],
      extra
    )
  end

  describe "option admission is exit 3, never a health verdict" do
    test "a missing sink cannot be diagnosed" do
      report = Doctor.run(:preflight, Keyword.delete(opts(), :sink))

      assert report.exit_code == 3
      assert report.status == :invalid
      assert [%{name: :invocation, reason: :sink_required}] = report.checks
    end

    test "a module that is not a sink cannot be diagnosed" do
      report = Doctor.run(:preflight, opts(sink: Enum))

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :sink_required}] = report.checks
    end

    test "a missing source identity cannot be diagnosed" do
      report = Doctor.run(:preflight, Keyword.delete(opts(), :source_identity))

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :source_identity_required}] = report.checks
    end

    test "a missing publication cannot be diagnosed" do
      report = Doctor.run(:doctor, Keyword.delete(opts(), :publication))

      assert report.exit_code == 3
      assert [%{name: :invocation, reason: :config_invalid}] = report.checks
    end
  end

  describe "the report covers exactly the mode's checks, in order" do
    test "preflight reports its own check set" do
      report = Doctor.run(:preflight, opts())

      assert Enum.map(report.checks, & &1.name) == Doctor.check_names(:preflight)
      assert report.mode == :preflight
    end

    test "doctor reports the superset" do
      report = Doctor.run(:doctor, opts())

      assert Enum.map(report.checks, & &1.name) == Doctor.check_names(:doctor)
      assert report.mode == :doctor
    end
  end

  describe "an unreachable source fails closed and never guesses" do
    test "reachability fails and exit is 1" do
      report = Doctor.run(:preflight, opts())

      assert check(report, :source_reachable).status == :fail
      assert check(report, :source_reachable).reason == :source_unreachable
      assert report.exit_code == 1
    end

    test "every source-derived check is SKIPPED rather than passed" do
      report = Doctor.run(:preflight, opts())

      for name <- [
            :source_release,
            :source_privileges,
            :source_identity,
            :source_coverage,
            :source_replica_identity,
            :slot_presence,
            :slot_retention
          ] do
        assert check(report, name).status == :skipped
        assert check(report, name).reason == :source_unreachable
      end
    end

    test "the destination-side checks are still judged — they need no source" do
      report = Doctor.run(:preflight, opts())

      assert check(report, :sink_configuration).status == :pass
      assert check(report, :dependency_requirements).status == :pass
    end
  end

  describe "an unavailable destination is skipped, never inferred" do
    test "checkpoint and contract are skipped when the destination is unavailable" do
      unavailable_repo = spawn(fn -> :ok end)
      monitor = Process.monitor(unavailable_repo)
      assert_receive {:DOWN, ^monitor, :process, ^unavailable_repo, _reason}

      # The live suite starts the named TestRepo globally. Pin this test
      # process to a dead dynamic identity so the destination is unavailable
      # in BOTH the no-database and combined live-suite environments.
      AshReplicant.TestRepo.put_dynamic_repo(unavailable_repo)

      report = Doctor.run(:doctor, opts())

      assert check(report, :checkpoint_state).status == :skipped
      assert check(report, :checkpoint_state).reason == :destination_unavailable
      assert check(report, :contract_drift).status == :skipped
    end

    test "runtime readiness reports absent, and says it is node-local" do
      report = Doctor.run(:doctor, opts())

      assert check(report, :runtime_generation).status == :warn
      assert check(report, :runtime_generation).reason == :generation_absent
    end

    test "the in-process public doctor reports a live generation" do
      AdmittedGeneration.put!(DiagnosisSink)

      report = AshReplicant.doctor(opts())

      assert check(report, :runtime_generation).status == :pass
      assert check(report, :runtime_generation).reason == :generation_live
    end

    test "the in-process public doctor fails a generation whose owner died" do
      owner = spawn(fn -> :ok end)
      monitor = Process.monitor(owner)

      # Either exit flavor proves the owner is gone: `:normal` when the
      # monitor won the race, `:noproc` when the spawned fun exited first
      # (the latest-dependency cell's timing surfaces the latter).
      assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}

      AdmittedGeneration.put!(DiagnosisSink, owner: owner)

      report = AshReplicant.doctor(opts())

      assert check(report, :runtime_generation).status == :fail
      assert check(report, :runtime_generation).reason == :generation_owner_dead
    end
  end

  describe "value-free across BOTH renderings" do
    test "no operator-supplied value reaches the operator text" do
      text = :doctor |> Doctor.run(opts()) |> Report.to_text()

      for sentinel <- @sentinels do
        refute text =~ sentinel
      end
    end

    test "no operator-supplied value reaches the machine rendering" do
      encoded =
        :doctor
        |> Doctor.run(opts())
        |> Report.to_map()
        |> Jason.encode!()

      for sentinel <- @sentinels do
        refute encoded =~ sentinel
      end
    end

    test "an undiagnosable invocation leaks nothing either" do
      text =
        :preflight
        |> Doctor.run(opts(sink: Enum))
        |> Report.to_text()

      for sentinel <- @sentinels do
        refute text =~ sentinel
      end
    end
  end

  describe "the public API delegates to the same run" do
    test "preflight/1 and doctor/1 return the canonical report" do
      assert %Report{mode: :preflight} = AshReplicant.preflight(opts())
      assert %Report{mode: :doctor} = AshReplicant.doctor(opts())
    end

    test "the public functions agree with Doctor.run/2 on the verdict" do
      assert AshReplicant.preflight(opts()).exit_code == Doctor.run(:preflight, opts()).exit_code
    end
  end

  defp check(report, name), do: Enum.find(report.checks, &(&1.name == name))
end
