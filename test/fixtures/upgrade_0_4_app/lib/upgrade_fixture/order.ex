defmodule UpgradeFixture.Order do
  @moduledoc false
  use Ash.Resource,
    domain: UpgradeFixture.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "upgrade_fixture_orders"
    repo UpgradeFixture.Repo
  end

  replicant do
    source_table("upgrade_fixture_orders")
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
