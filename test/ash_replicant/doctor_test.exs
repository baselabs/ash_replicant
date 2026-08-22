defmodule AshReplicant.DoctorTest do
  @moduledoc """
  The canonical typed result behind `mix ash_replicant.preflight` /
  `mix ash_replicant.doctor`: one `%Check{}` vocabulary, the derived overall
  status and exit code, the value-free detail allowlist, and the requirement that
  every class the slice must DISTINGUISH — missing privileges, unknown checkpoint
  state, replica identity, retention horizon, contract drift, version mismatch —
  carries its own reason atom. Pure; no database.
  """
  use ExUnit.Case, async: true

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Doctor
  alias AshReplicant.Doctor.{Check, Report}
  alias AshReplicant.Error

  defp pass(name), do: %Check{name: name, domain: :source, status: :pass, reason: :ok}
  defp warn(name), do: %Check{name: name, domain: :source, status: :warn, reason: :something}
  defp fail(name), do: %Check{name: name, domain: :source, status: :fail, reason: :broken}

  describe "Report status and exit codes" do
    test "all passing is status :pass and exit 0" do
      report = Report.new(:preflight, [pass(:a), pass(:b)])

      assert report.status == :pass
      assert report.exit_code == 0
    end

    test "any failure is status :fail and exit 1, even beside warnings" do
      report = Report.new(:doctor, [pass(:a), warn(:b), fail(:c)])

      assert report.status == :fail
      assert report.exit_code == 1
    end

    test "warnings without a failure are status :warn and exit 2" do
      report = Report.new(:doctor, [pass(:a), warn(:b)])

      assert report.status == :warn
      assert report.exit_code == 2
    end

    test "a skipped check does not change a passing verdict" do
      skipped = %Check{name: :c, domain: :checkpoint, status: :skipped, reason: :not_applicable}
      report = Report.new(:preflight, [pass(:a), skipped])

      assert report.status == :pass
      assert report.exit_code == 0
    end

    test "an unusable invocation is exit 3, distinct from an unhealthy deployment" do
      report = Report.invalid(:sink_required)

      assert report.status == :invalid
      assert report.exit_code == 3
      assert [%Check{name: :invocation, status: :fail, reason: :sink_required}] = report.checks
    end
  end

  describe "machine and human output share the canonical result" do
    test "every check reaches both renderings with the same name, status and reason" do
      checks = [
        %Check{
          name: :source_privileges,
          domain: :source,
          status: :fail,
          reason: :privilege_replication_missing
        },
        %Check{name: :slot_retention, domain: :slot, status: :warn, reason: :retention_at_risk},
        %Check{name: :contract_drift, domain: :contract, status: :pass, reason: :contract_equal}
      ]

      report = Report.new(:doctor, checks)
      machine = Report.to_map(report)
      text = Report.to_text(report)

      assert machine.mode == :doctor
      assert machine.status == :fail
      assert machine.exit_code == 1
      assert length(machine.checks) == 3

      for check <- checks do
        entry = Enum.find(machine.checks, &(&1.name == check.name))

        assert entry.status == check.status
        assert entry.reason == check.reason
        assert entry.domain == check.domain

        assert text =~ to_string(check.name)
        assert text =~ to_string(check.status)
        assert text =~ to_string(check.reason)
      end
    end

    test "the machine rendering is JSON-encodable" do
      report = Report.new(:preflight, [pass(:a), warn(:b)])

      assert {:ok, json} = report |> Report.to_map() |> Jason.encode()
      assert json =~ "\"exit_code\":2"
    end
  end

  describe "value-free detail" do
    test "a catalog-identifier shape is admitted as detail" do
      error =
        Error.exception(
          reason: :source_replica_identity,
          resource: nil,
          op: :preflight,
          shape: "public.orders=d"
        )

      check = Doctor.check_replica_identity({:error, error})

      assert check.status == :fail
      assert check.reason == :source_replica_identity
      assert check.detail == "public.orders=d"
    end

    test "an identity-class shape is DROPPED — it embeds the source database name" do
      error =
        Error.exception(
          reason: :source_identity_mismatch,
          resource: nil,
          op: :preflight,
          shape: "probe_database=customer_secrets_prod"
        )

      check = Doctor.check_source_identity({:error, error})

      assert check.status == :fail
      assert check.reason == :source_identity_mismatch
      assert check.detail == nil

      refute Report.to_text(Report.new(:preflight, [check])) =~ "customer_secrets_prod"
    end

    test "an unrecognised reason yields no detail — the allowlist is fail-closed" do
      error =
        Error.exception(
          reason: :sink_failed,
          resource: nil,
          op: :preflight,
          shape: "some-unclassified-string"
        )

      assert Doctor.check_coverage({:error, error}).detail == nil
    end
  end

  describe "missing privileges are their own class" do
    test "a role without REPLICATION fails with its own reason" do
      check = Doctor.check_privileges(%{superuser?: false, replication?: false, tables: []})

      assert check.status == :fail
      assert check.reason == :privilege_replication_missing
    end

    test "a superuser satisfies replication capability" do
      check = Doctor.check_privileges(%{superuser?: true, replication?: false, tables: []})

      assert check.status == :pass
    end

    test "a published table the role cannot SELECT is a distinct privilege reason" do
      check =
        Doctor.check_privileges(%{
          superuser?: false,
          replication?: true,
          tables: [{"public", "orders", false}, {"public", "items", true}]
        })

      assert check.status == :fail
      assert check.reason == :privilege_select_missing
      assert check.detail == "public.orders"
    end

    test "missing privileges never collapse into unreachable" do
      privileges = Doctor.check_privileges(%{superuser?: false, replication?: false, tables: []})
      unreachable = Doctor.check_source_reachable({:error, :unreachable})

      assert unreachable.status == :fail
      assert unreachable.reason == :source_unreachable
      refute unreachable.reason == privileges.reason
    end
  end

  describe "replica identity is distinguished from the rest of coverage" do
    test "a coverage violation and a replica-identity violation are separate checks" do
      coverage_error =
        Error.exception(
          reason: :source_column_unmapped,
          resource: nil,
          op: :preflight,
          shape: "public.orders(note)"
        )

      rif_error =
        Error.exception(
          reason: :source_replica_identity,
          resource: nil,
          op: :preflight,
          shape: "public.orders=d"
        )

      coverage = Doctor.check_coverage({:error, coverage_error})
      rif = Doctor.check_replica_identity({:error, rif_error})

      assert coverage.name == :source_coverage
      assert rif.name == :source_replica_identity
      assert coverage.reason != rif.reason
    end

    test "a replica-identity verdict reported through coverage does not double-count" do
      rif_error =
        Error.exception(
          reason: :source_replica_identity,
          resource: nil,
          op: :preflight,
          shape: "public.orders=d"
        )

      assert Doctor.check_coverage({:error, rif_error}).status == :pass
    end
  end

  describe "retention horizon states are distinguished" do
    test "reserved WAL passes" do
      assert Doctor.check_retention(slot(wal_status: "reserved"), nil).status == :pass
    end

    test "extended retention passes with its own reason" do
      check = Doctor.check_retention(slot(wal_status: "extended"), nil)

      assert check.status == :pass
      assert check.reason == :retention_extended
    end

    test "unreserved WAL is the alert BEFORE recovery becomes impossible" do
      check = Doctor.check_retention(slot(wal_status: "unreserved"), nil)

      assert check.status == :warn
      assert check.reason == :retention_at_risk
    end

    test "lost WAL fails — recovery is already impossible" do
      check = Doctor.check_retention(slot(wal_status: "lost"), nil)

      assert check.status == :fail
      assert check.reason == :retention_lost
    end

    test "an exhausted safe_wal_size is at risk even while still reserved" do
      check = Doctor.check_retention(slot(wal_status: "reserved", exhausted: true), nil)

      assert check.status == :warn
      assert check.reason == :retention_at_risk
    end

    test "an unreadable wal_status is unknown, not silently healthy" do
      check = Doctor.check_retention(slot(wal_status: nil), nil)

      assert check.status == :warn
      assert check.reason == :retention_unknown
    end

    test "a durable watermark whose slot is GONE is lost retention" do
      check = Doctor.check_retention(nil, 4_294_967_296)

      assert check.status == :fail
      assert check.reason == :retention_lost
    end

    test "an absent slot with no durable watermark has nothing to lose yet" do
      check = Doctor.check_retention(nil, nil)

      assert check.status == :warn
      assert check.reason == :retention_unknown
    end
  end

  describe "slot presence and shape" do
    test "an absent slot warns without failing — the first connect creates it" do
      check = Doctor.check_slot(nil)

      assert check.status == :warn
      assert check.reason == :slot_absent
    end

    test "a physical slot cannot carry logical decoding" do
      check = Doctor.check_slot(slot(slot_type: "physical"))

      assert check.status == :fail
      assert check.reason == :slot_type_invalid
    end

    test "a foreign output plugin fails" do
      check = Doctor.check_slot(slot(plugin: "wal2json"))

      assert check.status == :fail
      assert check.reason == :slot_plugin_invalid
    end

    test "an idle logical slot passes and says so" do
      check = Doctor.check_slot(slot(active: false))

      assert check.status == :pass
      assert check.reason == :slot_inactive
    end
  end

  describe "unknown checkpoint state is its own class" do
    test "an absent checkpoint row is a fresh deployment, not a fault" do
      check = Doctor.check_checkpoint(nil, keys())

      assert check.status == :pass
      assert check.reason == :checkpoint_absent
    end

    test "a bound row with no watermark reports initialized" do
      check = Doctor.check_checkpoint(checkpoint(), keys())

      assert check.status == :pass
      assert check.reason == :checkpoint_initialized
    end

    test "a bound row with a watermark reports bound" do
      check = Doctor.check_checkpoint(checkpoint(commit_lsn: 42), keys())

      assert check.status == :pass
      assert check.reason == :checkpoint_bound
    end

    test "an undecodable snapshot envelope FAILS as unknown state" do
      check = Doctor.check_checkpoint(checkpoint(snapshot_state: <<0, 1, 2, 3>>), keys())

      assert check.status == :fail
      assert check.reason == :checkpoint_state_unknown
    end

    test "unknown state is distinct from contract drift" do
      unknown = Doctor.check_checkpoint(checkpoint(snapshot_state: <<9, 9>>), keys())
      drift = Doctor.check_contract(checkpoint(publication_contract: "x"), current_contract())

      assert unknown.reason != drift.reason
    end
  end

  describe "contract drift is distinguished from an unbound contract" do
    test "no stored contract is unbound, not drift" do
      check = Doctor.check_contract(checkpoint(), current_contract())

      assert check.status == :pass
      assert check.reason == :contract_unbound
    end

    test "an identical stored contract passes" do
      contract = current_contract()

      row =
        checkpoint(
          publication_contract: contract.encoded,
          publication_fingerprint: contract.fingerprint
        )

      check = Doctor.check_contract(row, contract)

      assert check.status == :pass
      assert check.reason == :contract_equal
    end

    test "an unreadable stored contract fails as invalid, never as equal" do
      row = checkpoint(publication_contract: <<1, 2, 3>>, publication_fingerprint: <<4, 5>>)

      check = Doctor.check_contract(row, current_contract())

      assert check.status == :fail
      assert check.reason == :stored_contract_invalid
    end

    test "an incompatible stored contract fails with the classifier's own reason" do
      current = current_contract()
      stored_manifest = %{current.manifest | publication: ["a_different_publication"]}
      encoded = Identity.encode(stored_manifest)

      row =
        checkpoint(
          publication_contract: encoded,
          publication_fingerprint: Identity.fingerprint(encoded)
        )

      check = Doctor.check_contract(row, current)

      assert check.status == :fail
      assert check.reason == :publication
    end

    test "set-monotone growth warns rather than fails — activation admits it" do
      current = current_contract()

      stored_manifest = %{
        current.manifest
        | relations: [],
          ignores: []
      }

      encoded = Identity.encode(stored_manifest)

      row =
        checkpoint(
          publication_contract: encoded,
          publication_fingerprint: Identity.fingerprint(encoded)
        )

      check = Doctor.check_contract(row, current)

      assert check.status == :warn
      assert check.reason == :relations_added
    end
  end

  describe "version mismatches are distinguished on both axes" do
    test "a dependency outside this package's requirement fails" do
      check = Doctor.check_dependency_requirements(%{replicant: "1.0.0", ash: "3.31.3"})

      assert check.status == :fail
      assert check.reason == :dependency_version_mismatch
      assert check.detail == "replicant"
    end

    test "an unloaded dependency fails with its own reason" do
      check = Doctor.check_dependency_requirements(%{replicant: nil, ash: "3.31.3"})

      assert check.status == :fail
      assert check.reason == :dependency_missing
    end

    test "loaded versions inside the requirements pass" do
      check = Doctor.check_dependency_requirements(%{replicant: "1.2.3", ash: "3.31.3"})

      assert check.status == :pass
    end

    test "the runtime requirement literals match mix.exs" do
      mix = File.read!("mix.exs")

      assert mix =~ ~s(@replicant_requirement "#{Doctor.replicant_requirement()}")
      assert mix =~ ~s(@ash_requirement "#{Doctor.ash_requirement()}")
    end

    test "a source below the supported floor fails" do
      check = Doctor.check_source_release(140_000)

      assert check.status == :fail
      assert check.reason == :source_release_unsupported
    end

    test "a source above the tested ceiling warns rather than fails" do
      check = Doctor.check_source_release(190_000)

      assert check.status == :warn
      assert check.reason == :source_release_untested
    end

    test "a supported source passes" do
      assert Doctor.check_source_release(180_004).status == :pass
    end

    test "the two version axes never share a reason" do
      dependency = Doctor.check_dependency_requirements(%{replicant: "1.0.0", ash: "3.31.3"})
      source = Doctor.check_source_release(140_000)

      assert dependency.reason != source.reason
      assert dependency.name != source.name
    end
  end

  describe "the two modes cover the acceptance classes" do
    test "preflight is the pre-delivery subset and never needs a checkpoint" do
      names = Doctor.check_names(:preflight)

      assert :source_privileges in names
      assert :source_replica_identity in names
      assert :slot_retention in names
      assert :dependency_requirements in names
      refute :checkpoint_state in names
      refute :contract_drift in names
    end

    test "doctor is a strict superset that adds the durable-state classes" do
      preflight = Doctor.check_names(:preflight)
      doctor = Doctor.check_names(:doctor)

      assert Enum.all?(preflight, &(&1 in doctor))
      assert :checkpoint_state in doctor
      assert :contract_drift in doctor
      assert :runtime_generation in doctor
    end

    test "every named class of the slice is present in the doctor report" do
      names = Doctor.check_names(:doctor)

      for required <- [
            :source_privileges,
            :checkpoint_state,
            :source_replica_identity,
            :slot_retention,
            :contract_drift,
            :dependency_requirements,
            :source_release
          ] do
        assert required in names
      end
    end
  end

  defp slot(overrides) do
    Enum.into(overrides, %{
      slot_type: "logical",
      plugin: "pgoutput",
      active: true,
      wal_status: "reserved",
      exhausted: false
    })
  end

  defp checkpoint(overrides \\ []) do
    Enum.into(overrides, %{
      commit_lsn: nil,
      snapshot_state: nil,
      publication_contract: nil,
      publication_fingerprint: nil
    })
  end

  defp keys, do: [{1, "test-snapshot-provenance-key-v1"}]

  defp current_contract do
    manifest = %{
      contract_version: 1,
      publication: ["shop_pub"],
      relations: [
        %{
          schema: "public",
          table: "orders",
          resource: AshReplicant.Doctor,
          columns: [%{source: "id", target: :id, sensitive: false}],
          skips: [],
          types: %{id: :string},
          tenant: nil
        }
      ],
      ignores: []
    }

    encoded = Identity.encode(manifest)

    %{manifest: manifest, encoded: encoded, fingerprint: Identity.fingerprint(encoded)}
  end
end
