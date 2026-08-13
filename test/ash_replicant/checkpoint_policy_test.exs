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
end
