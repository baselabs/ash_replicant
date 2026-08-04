defmodule AshReplicant.CheckpointPolicyTest do
  @moduledoc """
  The `authorizers:` opt on `use AshReplicant.Checkpoint` (0.4). Two layers:

    * introspection (no DB) — the opt actually reaches `use Ash.Resource`: the policied
      checkpoint carries `Ash.Policy.Authorizer` + declared policies, and the default
      checkpoint (no opt) carries neither. This is the gap closing — before the opt, a
      `policies do` block on the generated resource was an unknown-section compile error.
    * enforcement (`:integration`, needs live PG) — the policies actually bite: a
      non-system actor is denied, a system actor is allowed, and the sink's
      `authorize?: false` path bypasses both regardless.
  """
  use AshReplicant.DataCase, async: false

  alias AshReplicant.Test.{Checkpoint, CheckpointPolicied}

  describe "introspection — the opt makes the resource policy-capable (no DB)" do
    test "the policied checkpoint carries the policy authorizer + declared policies" do
      assert Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(CheckpointPolicied)
      refute Ash.Policy.Info.policies(CheckpointPolicied) == []
    end

    test "the default checkpoint (no authorizers opt) is unchanged — no authorizer" do
      # Backward-compat: omitting the opt reproduces the pre-0.4 resource exactly.
      assert Ash.Resource.Info.authorizers(Checkpoint) == []
    end

    test "both resources still expose the sink's actions + identity (macro body intact)" do
      for resource <- [Checkpoint, CheckpointPolicied] do
        action_names = resource |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)
        assert :upsert in action_names
        assert :read in action_names
        assert Ash.Resource.Info.identity(resource, :unique_slot)
      end
    end
  end

  describe "enforcement — the declared policies bite (needs live PG)" do
    @describetag :integration

    setup do
      # Seed via the sink's own path (authorize?: false) so the row exists regardless of
      # policy — exactly how the sink writes it.
      {:ok, row} =
        Ash.create(CheckpointPolicied, %{slot_name: "policy-slot", commit_lsn: 7},
          action: :upsert,
          authorize?: false
        )

      %{row: row}
    end

    test "the sink path (authorize?: false) reads + upserts regardless of policy" do
      # Read bypass.
      assert Ash.get!(CheckpointPolicied, "policy-slot", authorize?: false).commit_lsn == 7

      # Upsert bypass — effect-once path is untouched by the authorizer.
      assert {:ok, _} =
               Ash.create(CheckpointPolicied, %{slot_name: "policy-slot", commit_lsn: 99},
                 action: :upsert,
                 authorize?: false
               )

      assert Ash.get!(CheckpointPolicied, "policy-slot", authorize?: false).commit_lsn == 99
    end

    test "a system actor is allowed to read (non-vacuity — policies are not blanket-deny)" do
      assert {:ok, %{commit_lsn: 7}} =
               Ash.get(CheckpointPolicied, "policy-slot",
                 actor: %{system: true},
                 authorize?: true
               )
    end

    test "a non-system actor is denied the read (hard Forbidden, not a silent empty)" do
      # The check is actor-only, so a denial is a hard 403 — the watermark's existence is
      # never leaked as an empty result. This is the shape a host's own trust-band check
      # (a SimpleCheck) produces, which is the real consumption pattern.
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.get(CheckpointPolicied, "policy-slot",
                 actor: %{system: false},
                 authorize?: true
               )
    end

    test "a nil actor is denied the read (fail-closed under :strict)" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.get(CheckpointPolicied, "policy-slot", actor: nil, authorize?: true)
    end

    test "a non-system actor is denied a non-sink create (only the sink's authorize?: false writes)" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(CheckpointPolicied, %{slot_name: "policy-slot-2", commit_lsn: 1},
                 action: :upsert,
                 actor: %{system: false},
                 authorize?: true
               )
    end

    test "the DEFAULT checkpoint stays open under authorize?: true (no authorizer to enforce)" do
      {:ok, _} =
        Ash.create(Checkpoint, %{slot_name: "open-slot", commit_lsn: 3},
          action: :upsert,
          authorize?: false
        )

      # No authorizer → authorize?: true is a no-op → the row is returned. This is the
      # pre-0.4 behaviour, proving the opt is purely additive.
      assert Ash.get!(Checkpoint, "open-slot", actor: %{system: false}, authorize?: true).commit_lsn ==
               3
    end
  end
end
