defmodule AshReplicant.CheckpointPolicyIntegrationTest do
  @moduledoc "Live PostgreSQL enforcement tests for generated checkpoint policies."
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Test.{Checkpoint, CheckpointPolicied}

  setup do
    # Seed via the sink's own path (authorize?: false) so the row exists regardless of
    # policy — exactly how the sink writes it.
    {:ok, row} =
      Ash.create(CheckpointPolicied, source_row("policy-slot", 7),
        action: :upsert,
        authorize?: false
      )

    %{row: row}
  end

  test "the sink path (authorize?: false) reads + upserts regardless of policy" do
    # Read bypass.
    assert Ash.get!(CheckpointPolicied, key("policy-slot"), authorize?: false).commit_lsn == 7

    # Upsert bypass — effect-once path is untouched by the authorizer.
    assert {:ok, _} =
             Ash.create(CheckpointPolicied, source_row("policy-slot", 99),
               action: :upsert,
               authorize?: false
             )

    assert Ash.get!(CheckpointPolicied, key("policy-slot"), authorize?: false).commit_lsn == 99
  end

  test "a system actor is allowed to read (non-vacuity — policies are not blanket-deny)" do
    assert {:ok, %{commit_lsn: 7}} =
             Ash.get(CheckpointPolicied, key("policy-slot"),
               actor: %{system: true},
               authorize?: true
             )
  end

  test "a non-system actor is denied the read (hard Forbidden, not a silent empty)" do
    # The check is actor-only, so a denial is a hard 403 — the watermark's existence is
    # never leaked as an empty result. This is the shape a host's own trust-band check
    # (a SimpleCheck) produces, which is the real consumption pattern.
    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.get(CheckpointPolicied, key("policy-slot"),
               actor: %{system: false},
               authorize?: true
             )
  end

  test "a nil actor is denied the read (fail-closed under :strict)" do
    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.get(CheckpointPolicied, key("policy-slot"), actor: nil, authorize?: true)
  end

  test "a non-system actor is denied a non-sink create (only the sink's authorize?: false writes)" do
    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(CheckpointPolicied, source_row("policy-slot-2", 1),
               action: :upsert,
               actor: %{system: false},
               authorize?: true
             )
  end

  test "the DEFAULT checkpoint stays open under authorize?: true (no authorizer to enforce)" do
    {:ok, _} =
      Ash.create(Checkpoint, source_row("open-slot", 3),
        action: :upsert,
        authorize?: false
      )

    # No authorizer → authorize?: true is a no-op → the row is returned. This is the
    # pre-0.4 behaviour, proving the opt is purely additive.
    assert Ash.get!(Checkpoint, key("open-slot"), actor: %{system: false}, authorize?: true).commit_lsn ==
             3
  end

  # The B2 source-bound shape: every access keys the (system, database, slot) triple.
  defp source_row(slot, lsn) do
    %{
      source_system_id: "policy-system",
      source_database: "policy-db",
      slot_name: slot,
      commit_lsn: lsn
    }
  end

  defp key(slot) do
    %{source_system_id: "policy-system", source_database: "policy-db", slot_name: slot}
  end
end
