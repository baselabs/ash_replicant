defmodule AshReplicant.HorizonRiskTest do
  @moduledoc """
  O03 D2: the WAL-side horizon legs — slot-fact risk classification (the
  census's at-risk push and lost drift), the activation resume gate (a halt
  whose duration crossed the retention floor while the slot still retains WAL
  refuses rather than silently re-executing expired-claim messages), and the
  one extended slot probe statement (rule 11: never a second SQL copy).
  """

  use ExUnit.Case, async: true

  alias AshReplicant.{Doctor.Probe, Horizon, Telemetry}

  @now ~U[2026-08-23 12:00:00Z]

  describe "the slot-fact classifier" do
    test "reserved/extended is :ok" do
      assert {:ok, :ok} = Horizon.classify_slot_risk(%{wal_status: "reserved", exhausted: false})
      assert {:ok, :ok} = Horizon.classify_slot_risk(%{wal_status: "extended", exhausted: false})
    end

    test "unreserved or exhausted is at-risk with a structural kind" do
      assert {:ok, {:at_risk, :wal_unreserved}} =
               Horizon.classify_slot_risk(%{wal_status: "unreserved", exhausted: false})

      assert {:ok, {:at_risk, :wal_exhausted}} =
               Horizon.classify_slot_risk(%{wal_status: "extended", exhausted: true})
    end

    test "lost is a drift halt — recovery is already impossible" do
      assert {:error, :source_wal_lost} = Horizon.classify_slot_risk(%{wal_status: "lost"})
    end

    test "no slot row / unknown status defers to unknown" do
      assert {:ok, :unknown} = Horizon.classify_slot_risk(nil)
      assert {:ok, :unknown} = Horizon.classify_slot_risk(%{wal_status: "weird"})
    end
  end

  describe "the activation resume gate" do
    test "a halt past the retention floor with WAL retained refuses" do
      assert {:error, :retention_horizon_crossed} =
               Horizon.classify_resume(
                 DateTime.add(@now, -3_601),
                 @now,
                 3_600,
                 %{wal_status: "extended", exhausted: false}
               )
    end

    test "a halt within the retention floor proceeds" do
      assert :ok =
               Horizon.classify_resume(
                 DateTime.add(@now, -3_599),
                 @now,
                 3_600,
                 %{wal_status: "extended", exhausted: false}
               )
    end

    test "a lost slot defers to the stream's own failure, no duplicate gate" do
      assert :ok =
               Horizon.classify_resume(
                 DateTime.add(@now, -9_999),
                 @now,
                 3_600,
                 %{wal_status: "lost"}
               )
    end

    test "no prior halt (fresh or clean state) proceeds" do
      assert :ok = Horizon.classify_resume(nil, @now, 3_600, %{wal_status: "reserved"})
      assert :ok = Horizon.classify_resume(nil, @now, nil, nil)
    end

    test "no claim-backed routes: nothing to gate" do
      assert :ok =
               Horizon.classify_resume(
                 DateTime.add(@now, -9_999),
                 @now,
                 nil,
                 %{wal_status: "extended"}
               )
    end

    test "an unreachable slot probe defers (never blocks recovery on a probe fault)" do
      assert :ok = Horizon.classify_resume(DateTime.add(@now, -9_999), @now, 3_600, nil)
      assert :ok = Horizon.classify_resume(DateTime.add(@now, -9_999), @now, 3_600, :unreachable)
    end
  end

  describe "the probe statement stays one home" do
    test "sql_replication_slot/0 carries safe_wal_size alongside the risk columns" do
      sql = Probe.sql_replication_slot()

      assert sql =~ "wal_status"
      assert sql =~ "safe_wal_size"
      # Admitted read-only (the doctor's own admission gate must accept it).
      assert sql == Probe.admit!(sql)
    end
  end

  describe "the at-risk event" do
    test "[:ash_replicant, :retention, :at_risk] is in the emitted inventory" do
      assert [:ash_replicant, :retention, :at_risk] in Telemetry.emitted_event_names()
    end

    test "it carries meta only — slot_name and the structural kind, no measurement" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :retention, :at_risk]])

      assert :ok =
               Telemetry.event([:ash_replicant, :retention, :at_risk], %{}, %{
                 slot_name: "slot",
                 kind: :wal_unreserved
               })

      assert_received {[:ash_replicant, :retention, :at_risk], ^ref, measurements, meta}
      assert measurements == %{}
      assert meta.slot_name == "slot"
      assert meta.kind == :wal_unreserved

      :telemetry.detach(ref)
    end
  end
end
