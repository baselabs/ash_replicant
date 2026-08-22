defmodule UpgradeFixture.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource UpgradeFixture.Checkpoint
    resource UpgradeFixture.Order
  end
end
