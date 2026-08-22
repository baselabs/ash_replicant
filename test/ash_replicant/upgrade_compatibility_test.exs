defmodule AshReplicant.Upgrade.CompatibilityTest do
  use ExUnit.Case, async: true

  test "the 0.4 apply_ledger option compiles only as an activation-refused marker" do
    [{module, _bytecode}] =
      Code.compile_string("""
      defmodule AshReplicant.Test.LegacyUpgradeSink do
        use AshReplicant.Sink,
          repo: AshReplicant.TestRepo,
          domains: [AshReplicant.Test.Domain],
          checkpoint_resource: AshReplicant.Test.Checkpoint,
          slot_name: "legacy_upgrade_slot",
          apply_ledger: :legacy_apply_ledger
      end
      """)

    assert module.__ash_replicant_config__().legacy_apply_ledger?

    assert {:error, :legacy_upgrade_required} =
             AshReplicant.activate_owner([sink: module], self())
  end

  test "unknown options remain compile-time refusals" do
    assert_raise ArgumentError, ~r/:typo_option/, fn ->
      Code.compile_string("""
      defmodule AshReplicant.Test.UpgradeTypoOptionSink do
        use AshReplicant.Sink,
          repo: AshReplicant.TestRepo,
          domains: [AshReplicant.Test.Domain],
          checkpoint_resource: AshReplicant.Test.Checkpoint,
          slot_name: "upgrade_typo_option_slot",
          typo_option: true
      end
      """)
    end
  end
end
