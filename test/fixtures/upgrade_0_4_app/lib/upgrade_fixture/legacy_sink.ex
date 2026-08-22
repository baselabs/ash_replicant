defmodule UpgradeFixture.LegacySink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: UpgradeFixture.Repo,
    domains: [UpgradeFixture.Domain],
    checkpoint_resource: UpgradeFixture.Checkpoint,
    slot_name: "consumer_upgrade_slot",
    apply_ledger: :consumer_legacy_apply_ledger
end
