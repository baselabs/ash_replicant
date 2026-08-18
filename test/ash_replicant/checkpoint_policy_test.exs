defmodule AshReplicant.CheckpointPolicyTest do
  @moduledoc """
  Database-free introspection and strict-check enforcement for the generated
  checkpoint's default-deny trust posture (roadmap B7 / ADR-0014). Live
  sink-bypass enforcement is covered separately under
  `test/integration/checkpoint_policy_test.exs`.
  """
  use ExUnit.Case, async: true

  alias AshReplicant.Test.{Checkpoint, CheckpointPolicied, CheckpointUnguarded}

  describe "introspection — the generated default is policy-capable, empty-policy (deny-all)" do
    test "the DEFAULT checkpoint carries the policy authorizer with an empty policy set" do
      assert Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(Checkpoint)
      assert Ash.Policy.Info.policies(Checkpoint) == []
    end

    test "the policied checkpoint carries the policy authorizer + declared policies" do
      assert Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(CheckpointPolicied)
      refute Ash.Policy.Info.policies(CheckpointPolicied) == []
    end

    test "the explicit opt-out reproduces the pre-B7 unguarded shape" do
      assert Ash.Resource.Info.authorizers(CheckpointUnguarded) == []
    end

    test "all resources still expose the sink's actions + identity (macro body intact)" do
      for resource <- [Checkpoint, CheckpointPolicied, CheckpointUnguarded] do
        action_names = resource |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)
        assert :upsert in action_names
        assert :read in action_names
        assert :operator_reset in action_names
        assert Ash.Resource.Info.identity(resource, :source_slot)
      end
    end

    test "the policied note about pre-0.4 byte-equality no longer holds (shape changed)" do
      # The macro's shape is source-bound as of B2: the identity is the triple, not
      # the slot. This assertion pins the rename so a silent revert is a named red.
      identity = Ash.Resource.Info.identity(Checkpoint, :source_slot)
      assert identity.keys == [:source_system_id, :source_database, :slot_name]
      assert Ash.Resource.Info.identity(Checkpoint, :unique_slot) == nil
    end
  end

  describe "default-deny enforcement (no DB — Ash.can evaluates the policy layer only)" do
    # An authorizer with an empty policy set authorizes nothing: every actor,
    # every action. Probed through Ash.can (pure policy evaluation — a full
    # Ash.read cannot run without a Repo even on the forbidden path, because
    # the error handler checks in-transaction state first); the end-to-end
    # Forbidden error is proven live in the integration policy suite.
    test "no actor is authorized for the default checkpoint's read — not even a system actor" do
      assert {:ok, false} = Ash.can({Checkpoint, :read}, %{system: true}, run_queries?: false)
      assert {:ok, false} = Ash.can({Checkpoint, :read}, nil, run_queries?: false)
    end

    test "no actor is authorized for the default checkpoint's upsert or destroy" do
      assert {:ok, false} = Ash.can({Checkpoint, :upsert}, %{system: true}, run_queries?: false)

      assert {:ok, false} =
               Ash.can({Checkpoint, :operator_reset}, %{system: true}, run_queries?: false)
    end

    test "the policied checkpoint's own policies still decide (non-vacuity contrast)" do
      # A map actor's check is not strictly decidable pre-flight, so the
      # system actor yields :maybe (decided at runtime) — never :false,
      # which is the contrast that proves the default-deny is policy
      # evaluation, not a blanket refuse.
      assert {:ok, allow} =
               Ash.can({CheckpointPolicied, :read}, %{system: true}, run_queries?: false)

      assert allow in [:maybe, true]

      assert {:ok, false} =
               Ash.can({CheckpointPolicied, :read}, %{system: false}, run_queries?: false)
    end

    test "the unguarded opt-out stays open (no authorizer, nothing to enforce)" do
      assert {:ok, true} =
               Ash.can({CheckpointUnguarded, :read}, nil, run_queries?: false, maybe_is: true)
    end
  end
end
