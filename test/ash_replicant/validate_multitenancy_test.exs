defmodule AshReplicant.ValidateMultitenancyTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  # As in the sensitive verifier test: Spark re-emits a verifier's DslError as a
  # compiler diagnostic (`@after_verify` catch -> `IO.warn`), so `Spark.Test`
  # collects the errors as data rather than `assert_raise`. Matching on the
  # `[:replicant, :tenant_attribute]` path isolates THIS verifier: `sensitive
  # [:org_id]` on a plaintext column also trips ValidateSensitive (path
  # `[:replicant, :sensitive]`), so the specific-path match proves the tripwire
  # fires for the multitenancy rule and not merely "some error".

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  test "a tenant_attribute that is also classified sensitive fails closed (tripwire)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :tenant_attribute]} do
        defmodule Elixir.AshReplicant.ValidateMultitenancyTest.SensitiveDiscriminator do
          use Ash.Resource,
            domain: AshReplicant.ValidateMultitenancyTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            tenant_attribute(:org_id)
            sensitive([:org_id])
          end

          attributes do
            uuid_primary_key :id
            attribute :org_id, :string
          end
        end
      end

    assert err.message =~ "plaintext selector"
  end

  test "a tenant_attribute listed in skip fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :tenant_attribute]} do
        defmodule Elixir.AshReplicant.ValidateMultitenancyTest.SkippedDiscriminator do
          use Ash.Resource,
            domain: AshReplicant.ValidateMultitenancyTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            tenant_attribute(:org_id)
            skip([:org_id])
          end

          attributes do
            uuid_primary_key :id
            attribute :org_id, :string
          end
        end
      end

    assert err.message =~ "skip"
  end

  test "an undeclared tenant_attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :tenant_attribute]} do
        defmodule Elixir.AshReplicant.ValidateMultitenancyTest.UndeclaredDiscriminator do
          use Ash.Resource,
            domain: AshReplicant.ValidateMultitenancyTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            tenant_attribute(:org_id)
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "declared attribute"
  end

  test "a binary-storage tenant_attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :tenant_attribute]} do
        defmodule Elixir.AshReplicant.ValidateMultitenancyTest.BinaryDiscriminator do
          use Ash.Resource,
            domain: AshReplicant.ValidateMultitenancyTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            tenant_attribute(:org_id)
          end

          attributes do
            uuid_primary_key :id
            attribute :org_id, :binary
          end
        end
      end

    assert err.message =~ "binary"
  end

  test "a plain, declared, string tenant_attribute compiles clean (green control)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateMultitenancyTest.PlainDiscriminator do
        use Ash.Resource,
          domain: AshReplicant.ValidateMultitenancyTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
          tenant_attribute(:org_id)
        end

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string
        end
      end
    end
  end
end
