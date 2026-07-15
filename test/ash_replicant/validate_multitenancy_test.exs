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

  defmodule TenantHelper do
    @moduledoc false
    # Value-free MFA target for the tenant_mfa arm: resolves the per-row tenant from a
    # source column. The verifier never invokes it (compile-time shape check only).
    def resolve(record, key), do: Map.get(record, key)
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

  test "a tenant_attribute without an Ash multitenancy block fails closed (fail-open guard)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :tenant_attribute]} do
        defmodule Elixir.AshReplicant.ValidateMultitenancyTest.NoMultitenancy do
          use Ash.Resource,
            domain: AshReplicant.ValidateMultitenancyTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            tenant_attribute(:org_id)
          end

          # No `multitenancy` block: Ash silently ignores the `tenant:` option the sink
          # passes, so the mirror write is UNSCOPED (fail-open isolation) — must fail closed.
          attributes do
            uuid_primary_key :id
            attribute :org_id, :string
          end
        end
      end

    assert err.message =~ "multitenancy"
  end

  test "a declared string tenant_attribute WITH attribute multitenancy compiles clean (green control)" do
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

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string
        end
      end
    end
  end

  # --- tenant_mfa arm (symmetric to the tenant_attribute fail-open guard above) ---
  #
  # An mfa-resolved tenant is passed to Ash as the `tenant:` option exactly like a
  # tenant_attribute-resolved one; Ash HONORS it only under a declared multitenancy block.
  # With none, `tenant:` is silently ignored and every tenant mirrors UNSCOPED (fail-open).
  # The mfa arm reports at path [:replicant, :tenant_mfa] (distinct from the tenant_attribute
  # arm's [:replicant, :tenant_attribute]), so the path match isolates THIS arm — a green
  # self-test is not coverage.

  test "a tenant_mfa without an Ash multitenancy block fails closed (fail-open guard, mfa arm)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :tenant_mfa]} do
        defmodule Elixir.AshReplicant.ValidateMultitenancyTest.MfaNoMultitenancy do
          use Ash.Resource,
            domain: AshReplicant.ValidateMultitenancyTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            tenant_mfa({AshReplicant.ValidateMultitenancyTest.TenantHelper, :resolve, ["org_id"]})
          end

          # No `multitenancy` block: the sink's `tenant:` is silently ignored, so the mirror
          # write is UNSCOPED across tenants (fail-open isolation) — must fail closed.
          attributes do
            uuid_primary_key :id
          end
        end
      end

    assert err.message =~ "multitenancy"
  end

  test "a tenant_mfa WITH :context multitenancy compiles clean (green control, mfa arm)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateMultitenancyTest.MfaWithContext do
        use Ash.Resource,
          domain: AshReplicant.ValidateMultitenancyTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
          tenant_mfa({AshReplicant.ValidateMultitenancyTest.TenantHelper, :resolve, ["org_id"]})
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

  test "a tenant_mfa WITH :attribute multitenancy compiles clean (any strategy satisfies, not :context-only)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateMultitenancyTest.MfaWithAttribute do
        use Ash.Resource,
          domain: AshReplicant.ValidateMultitenancyTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
          tenant_mfa({AshReplicant.ValidateMultitenancyTest.TenantHelper, :resolve, ["org_id"]})
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string
        end
      end
    end
  end
end
