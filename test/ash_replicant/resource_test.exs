defmodule AshReplicant.ResourceTest do
  use ExUnit.Case, async: true

  alias AshReplicant.Resource.Info

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule ExplicitOrders do
    use Ash.Resource,
      domain: AshReplicant.ResourceTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReplicant.Resource]

    replicant do
      source_table("orders")
      source_schema("reporting")
      tenant_attribute(:org_id)
    end

    attributes do
      uuid_primary_key :id
      attribute :org_id, :string
    end
  end

  defmodule ReflectedWidgets do
    use Ash.Resource,
      domain: AshReplicant.ResourceTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "widgets"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end
  end

  test "an explicit source_table is returned by the generated bang accessor" do
    assert Info.replicant_source_table!(ExplicitOrders) == "orders"
    assert Info.replicant_tenant_attribute!(ExplicitOrders) == :org_id
  end

  test "unset options carry their declared defaults" do
    assert Info.replicant_on_truncate!(ExplicitOrders) == :halt
    assert Info.replicant_on_schema_change!(ExplicitOrders) == :halt_destructive
    assert Info.replicant_sensitive!(ExplicitOrders) == []
    assert Info.replicant_skip!(ExplicitOrders) == []
  end

  test "source_table/1 and source_schema/1 return the explicit DSL values (override branch)" do
    assert Info.source_table(ExplicitOrders) == "orders"
    assert Info.source_schema(ExplicitOrders) == "reporting"
  end

  test "source_table/1 falls back to the reflected AshPostgres table when unset" do
    assert Info.source_table(ReflectedWidgets) == "widgets"
  end

  test "source_schema/1 falls back to \"public\" when neither DSL nor postgres schema is set" do
    assert Info.source_schema(ReflectedWidgets) == "public"
  end

  describe "history_* options" do
    test "history_strategy defaults to :scd1 and is readable" do
      # AshReplicant.Test.Secret is an existing non-history resource.
      assert Info.history_scd2?(AshReplicant.Test.Secret) == false
      assert Info.replicant_history_strategy!(AshReplicant.Test.Secret) == :scd1
    end
  end
end
