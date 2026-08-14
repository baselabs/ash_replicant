defmodule AshReplicant.CheckpointPolicyTest do
  @moduledoc """
  Database-free introspection for the `authorizers:` option on
  `use AshReplicant.Checkpoint`. Live policy enforcement is covered separately under
  `test/integration/checkpoint_policy_test.exs`.
  """
  use ExUnit.Case, async: true

  alias AshReplicant.Test.{Checkpoint, CheckpointPolicied}

  describe "introspection — the opt makes the resource policy-capable (no DB)" do
    test "the policied checkpoint carries the policy authorizer + declared policies" do
      assert Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(CheckpointPolicied)
      refute Ash.Policy.Info.policies(CheckpointPolicied) == []
    end

    test "the default checkpoint (no authorizers opt) carries no authorizer" do
      # The authorizers OPT behavior is unchanged (default []); the generated SHAPE
      # is source-bound as of B2 (see the rename test below).
      assert Ash.Resource.Info.authorizers(Checkpoint) == []
    end

    test "both resources still expose the sink's actions + identity (macro body intact)" do
      for resource <- [Checkpoint, CheckpointPolicied] do
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
end
