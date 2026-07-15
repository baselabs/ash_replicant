defmodule AshReplicant.ValidateActionMultitenancyTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  # The sink writes through the host's PRIMARY create/destroy (and, for SCD2, the close
  # action). An Ash action declaring `multitenancy :bypass`/`:bypass_all` makes Ash ignore
  # the per-row tenant the sink passes (create.ex handle_multitenancy: neither force-set nor
  # required) → every tenant's rows mirror UNSCOPED, despite a valid multitenancy block.
  # This verifier rejects that at compile time. Errors are at path [:actions, <name>],
  # distinct from the tenant-source verifiers ([:replicant, ...]) — the path match isolates
  # THIS verifier, so a green self-test is not coverage.

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  test "a :bypass primary create action on a multitenant resource fails closed (tripwire)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:actions, :create]} do
        defmodule Elixir.AshReplicant.ValidateActionMultitenancyTest.BypassCreate do
          use Ash.Resource,
            domain: AshReplicant.ValidateActionMultitenancyTest.Domain,
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

          actions do
            defaults [:read, :destroy]

            # :bypass makes Ash ignore the sink's tenant — the mirror write is UNSCOPED.
            create :create, primary?: true, multitenancy: :bypass
          end
        end
      end

    assert err.message =~ "bypass"
  end

  test "a :bypass_all primary destroy action on a multitenant resource fails closed (tripwire)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:actions, :destroy]} do
        defmodule Elixir.AshReplicant.ValidateActionMultitenancyTest.BypassDestroy do
          use Ash.Resource,
            domain: AshReplicant.ValidateActionMultitenancyTest.Domain,
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

          actions do
            defaults [:read, create: :*]

            destroy :destroy, primary?: true, multitenancy: :bypass_all
          end
        end
      end

    assert err.message =~ "bypass"
  end

  test "a :bypass SCD2 close action on a multitenant resource fails closed (tripwire, SCD2 close path)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:actions, :close_version]} do
        defmodule Elixir.AshReplicant.ValidateActionMultitenancyTest.BypassClose do
          use Ash.Resource,
            domain: AshReplicant.ValidateActionMultitenancyTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            tenant_attribute(:org_id)
            history_strategy(:scd2)
            history_business_key([:order_id])
            upsert_identity(:ov)
            history_close_action(:close_version)
          end

          multitenancy do
            strategy :attribute
            attribute :org_id
          end

          attributes do
            uuid_primary_key :id
            attribute :order_id, :string, allow_nil?: false
            attribute :org_id, :string, allow_nil?: false
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: true
          end

          identities do
            identity :ov, [:order_id, :valid_from_lsn],
              pre_check_with: AshReplicant.ValidateActionMultitenancyTest.Domain
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]

            # The SCD2 close routes through this update action; :bypass makes it ignore the
            # tenant, so the version close lands UNSCOPED — must fail closed.
            update :close_version, multitenancy: :bypass, accept: [:valid_to_lsn]
          end
        end
      end

    assert err.message =~ "bypass"
  end

  test "a :bypass primary READ action on a multitenant resource fails closed (tripwire, read path)" do
    # The sink's SCD2 close (`bulk_update`) and mirror delete (`bulk_destroy`) READ matching rows
    # via the primary read (`Ash.Query.do_filter`) before writing; under the stream strategy a
    # `:bypass` read matches ACROSS tenants → cross-tenant close/delete (verified probe). The read
    # action is a sink-selected action too — must fail closed.
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:actions, :read]} do
        defmodule Elixir.AshReplicant.ValidateActionMultitenancyTest.BypassRead do
          use Ash.Resource,
            domain: AshReplicant.ValidateActionMultitenancyTest.Domain,
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

          actions do
            defaults [:destroy, create: :*]

            read :read, primary?: true, multitenancy: :bypass
          end
        end
      end

    assert err.message =~ "bypass"
  end

  test "default (:enforce) sink actions on a multitenant resource compile clean (green control)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateActionMultitenancyTest.EnforceDefault do
        use Ash.Resource,
          domain: AshReplicant.ValidateActionMultitenancyTest.Domain,
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

        actions do
          defaults [:read, :destroy, create: :*]
        end
      end
    end
  end

  test "an :allow_global sink action compiles clean (the sink always passes a tenant → still scoped)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateActionMultitenancyTest.AllowGlobal do
        use Ash.Resource,
          domain: AshReplicant.ValidateActionMultitenancyTest.Domain,
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

        actions do
          defaults [:read, :destroy]

          create :create, primary?: true, multitenancy: :allow_global
        end
      end
    end
  end

  test "a :bypass action on a NON-multitenant resource compiles clean (no tenant to bypass — exempt)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateActionMultitenancyTest.NonTenantBypass do
        use Ash.Resource,
          domain: AshReplicant.ValidateActionMultitenancyTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
        end

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read, :destroy]

          create :create, primary?: true, multitenancy: :bypass
        end
      end
    end
  end
end
