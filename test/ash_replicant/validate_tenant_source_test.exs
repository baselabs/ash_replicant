defmodule AshReplicant.ValidateTenantSourceTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  # This verifier fires the CONVERSE of ValidateMultitenancy: it requires a
  # `replicant` tenant source (tenant_attribute OR tenant_mfa) whenever the resource
  # declares NON-global Ash multitenancy. The error is at the section path
  # `[:replicant]` (distinct from ValidateMultitenancy's `[:replicant,
  # :tenant_attribute]`), so a path match isolates THIS verifier — a green self-test
  # is not coverage.

  defmodule Helper do
    @moduledoc false
    def resolve(record, _key), do: record
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  test "non-global :attribute multitenancy WITHOUT a replicant discriminator fails closed (tripwire)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateTenantSourceTest.AttrNoSource do
          use Ash.Resource,
            domain: AshReplicant.ValidateTenantSourceTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
          end

          multitenancy do
            strategy :attribute
            attribute :org_id
          end

          attributes do
            uuid_primary_key :id
            attribute :org_id, :string, allow_nil?: false, public?: true
          end
        end
      end

    assert err.message =~ "tenant source"
  end

  test "non-global :context multitenancy WITHOUT a replicant discriminator fails closed" do
    assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
      defmodule Elixir.AshReplicant.ValidateTenantSourceTest.CtxNoSource do
        use Ash.Resource,
          domain: AshReplicant.ValidateTenantSourceTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
        end

        multitenancy do
          strategy :context
        end

        attributes do
          uuid_primary_key :id
        end
      end
    end
  end

  test "a GLOBAL multitenant resource without a discriminator compiles clean (tenant optional → exempt)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateTenantSourceTest.GlobalNoSource do
        use Ash.Resource,
          domain: AshReplicant.ValidateTenantSourceTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
          global? true
        end

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string, allow_nil?: false, public?: true
        end
      end
    end
  end

  test "a NON-tenant resource without a discriminator compiles clean (exempt)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateTenantSourceTest.NonTenant do
        use Ash.Resource,
          domain: AshReplicant.ValidateTenantSourceTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
        end

        attributes do
          uuid_primary_key :id
        end
      end
    end
  end

  test "non-global multitenancy WITH a tenant_attribute compiles clean (satisfied)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateTenantSourceTest.AttrSource do
        use Ash.Resource,
          domain: AshReplicant.ValidateTenantSourceTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
          tenant_attribute(:org_id)
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string, allow_nil?: false, public?: true
        end
      end
    end
  end

  test "non-global multitenancy WITH a tenant_mfa compiles clean (satisfied via the mfa path)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateTenantSourceTest.MfaSource do
        use Ash.Resource,
          domain: AshReplicant.ValidateTenantSourceTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
          tenant_mfa({AshReplicant.ValidateTenantSourceTest.Helper, :resolve, ["org_id"]})
        end

        multitenancy do
          strategy :context
        end

        attributes do
          uuid_primary_key :id
        end
      end
    end
  end
end
