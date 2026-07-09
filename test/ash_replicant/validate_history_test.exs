defmodule AshReplicant.ValidateHistoryTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  # A helper macro would obscure the shape under test; each case inlines its resource.

  test "a complete SCD2 version resource compiles clean (green control)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateHistoryTest.GoodVersion do
        use Ash.Resource,
          domain: AshReplicant.ValidateHistoryTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
          history_strategy(:scd2)
          history_business_key([:order_id])
          upsert_identity(:order_version)
          history_close_action(:close_version)
          history_current_attribute(:is_current)
          history_valid_from_timestamp_attribute(:valid_from_ts)
        end

        attributes do
          uuid_primary_key :id
          attribute :order_id, :string, allow_nil?: false
          attribute :valid_from_lsn, :integer, allow_nil?: false
          attribute :valid_to_lsn, :integer, allow_nil?: true
          attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: true
          attribute :is_current, :boolean, allow_nil?: false
          attribute :amount, :decimal
        end

        identities do
          identity :order_version, [:order_id, :valid_from_lsn],
            pre_check_with: AshReplicant.ValidateHistoryTest.Domain
        end

        actions do
          defaults [:read, :destroy, create: :*, update: :*]

          update :close_version do
            accept [:valid_to_lsn]
          end
        end
      end
    end
  end

  test "SCD2 with an empty business key fails closed (tripwire)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :history_business_key]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.NoBusinessKey do
          use Ash.Resource,
            domain: AshReplicant.ValidateHistoryTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            history_strategy(:scd2)
            upsert_identity(:order_version)
          end

          attributes do
            uuid_primary_key :id
            attribute :valid_from_lsn, :integer
            attribute :valid_to_lsn, :integer, allow_nil?: true
          end

          identities do
            identity :order_version, [:valid_from_lsn],
              pre_check_with: AshReplicant.ValidateHistoryTest.Domain
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]
          end
        end
      end

    assert err.message =~ "business key"
  end

  test "SCD2 whose business key IS the primary key (non-surrogate) fails closed (tripwire)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.NonSurrogatePk do
          use Ash.Resource,
            domain: AshReplicant.ValidateHistoryTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            history_strategy(:scd2)
            history_business_key([:order_id])
            upsert_identity(:order_version)
          end

          attributes do
            # order_id is BOTH the business key AND the primary key — not a surrogate.
            attribute :order_id, :string, primary_key?: true, allow_nil?: false
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: true
          end

          identities do
            identity :order_version, [:order_id, :valid_from_lsn],
              pre_check_with: AshReplicant.ValidateHistoryTest.Domain
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]
          end
        end
      end

    assert err.message =~ "surrogate"
  end

  test "SCD2 with a non-nullable valid_to_lsn fails closed (a closed-only window can't stay open)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.NonNullableValidTo do
          use Ash.Resource,
            domain: AshReplicant.ValidateHistoryTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            history_strategy(:scd2)
            history_business_key([:order_id])
            upsert_identity(:order_version)
          end

          attributes do
            uuid_primary_key :id
            attribute :order_id, :string, allow_nil?: false
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: false
          end

          identities do
            identity :order_version, [:order_id, :valid_from_lsn],
              pre_check_with: AshReplicant.ValidateHistoryTest.Domain
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]
          end
        end
      end

    assert err.message =~ "valid_to"
  end

  test "SCD2 whose upsert_identity keys != business_key ++ [valid_from_lsn] fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :upsert_identity]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.WrongIdentity do
          use Ash.Resource,
            domain: AshReplicant.ValidateHistoryTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            history_strategy(:scd2)
            history_business_key([:order_id])
            upsert_identity(:order_version)
          end

          attributes do
            uuid_primary_key :id
            attribute :order_id, :string, allow_nil?: false
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: true
          end

          identities do
            # missing :valid_from_lsn → not a version identity
            identity :order_version, [:order_id],
              pre_check_with: AshReplicant.ValidateHistoryTest.Domain
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]
          end
        end
      end

    assert err.message =~ "identity"
  end

  test "SCD2 missing the close action fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :history_close_action]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.NoCloseAction do
          use Ash.Resource,
            domain: AshReplicant.ValidateHistoryTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            history_strategy(:scd2)
            history_business_key([:order_id])
            upsert_identity(:order_version)
          end

          attributes do
            uuid_primary_key :id
            attribute :order_id, :string, allow_nil?: false
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: true
          end

          identities do
            identity :order_version, [:order_id, :valid_from_lsn],
              pre_check_with: AshReplicant.ValidateHistoryTest.Domain
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]
            # no :close_version action
          end
        end
      end

    assert err.message =~ "close"
  end
end
