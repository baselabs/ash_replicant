defmodule UpgradeFixture.Checkpoint do
  @moduledoc false
  use AshReplicant.Checkpoint,
    repo: UpgradeFixture.Repo,
    domain: UpgradeFixture.Domain
end
