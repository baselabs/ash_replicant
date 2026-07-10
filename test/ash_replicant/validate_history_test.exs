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

  test "on_truncate :close on a non-SCD2 (SCD1) resource fails closed at build" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :on_truncate]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.Scd1CloseTruncate do
          use Ash.Resource,
            domain: AshReplicant.ValidateHistoryTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            # history_strategy defaults to :scd1
            on_truncate(:close)
          end

          attributes do
            attribute :id, :string, primary_key?: true, allow_nil?: false
          end

          actions do
            defaults [:read]
          end
        end
      end

    assert err.message =~ "scd2"
  end

  test "SCD2 whose primary key OVERLAPS (not equals) the business key fails closed (surrogate must be disjoint)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.OverlappingPk do
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
            # PK is [id, order_id] — a surrogate id PLUS a business-key column: overlaps, not
            # disjoint. Spec §8 requires a fully disjoint surrogate PK, so this is rejected even
            # though the unique id would technically permit many rows per order_id.
            uuid_primary_key :id
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

            update :close_version do
              accept [:valid_to_lsn]
            end
          end
        end
      end

    assert err.message =~ "surrogate"
  end

  test "SCD2 with a nullable valid_from_lsn fails closed (the version anchor must be non-null)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.NullableValidFrom do
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
            # valid_from_lsn is the identity anchor — a nullable anchor is a fail-open shape.
            attribute :valid_from_lsn, :integer, allow_nil?: true
            attribute :valid_to_lsn, :integer, allow_nil?: true
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

    assert err.message =~ "valid_from"
  end

  test "SCD2 whose business_key names an undeclared attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :history_business_key]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.BkUndeclared do
          use Ash.Resource,
            domain: AshReplicant.ValidateHistoryTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            history_strategy(:scd2)
            history_business_key([:nonexistent_col])
            upsert_identity(:order_version)
          end

          attributes do
            uuid_primary_key :id
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: true
          end

          identities do
            identity :order_version, [:nonexistent_col, :valid_from_lsn],
              pre_check_with: AshReplicant.ValidateHistoryTest.Domain
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]
          end
        end
      end

    assert err.message =~ "not a declared attribute"
  end

  test "SCD2 with a missing valid_from_lsn attribute fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.MissingValidFrom do
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
            # no valid_from_lsn attribute declared
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

    assert err.message =~ "valid_from_lsn"
  end

  test "SCD2 with a non-integer valid_from_lsn fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.NonIntegerValidFrom do
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
            # valid_from_lsn declared as a string, not integer storage
            attribute :valid_from_lsn, :string, allow_nil?: false
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

    assert err.message =~ "integer"
  end

  test "SCD2 with a wrong-typed valid_from_timestamp (not datetime) fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.BadTsType do
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
            history_valid_from_timestamp_attribute(:valid_from_ts)
          end

          attributes do
            uuid_primary_key :id
            attribute :order_id, :string, allow_nil?: false
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: true
            # declared as a string, not a datetime
            attribute :valid_from_ts, :string, allow_nil?: true
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

    assert err.message =~ "datetime"
  end

  test "SCD2 with a non-nullable valid_from_timestamp fails closed (snapshots open with nil ts)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.NonNullableTs do
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
            history_valid_from_timestamp_attribute(:valid_from_ts)
          end

          attributes do
            uuid_primary_key :id
            attribute :order_id, :string, allow_nil?: false
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: true
            # a ts column must be allow_nil?: true (snapshots carry no source commit timestamp)
            attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: false
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

    assert err.message =~ "allow_nil"
  end

  test "SCD2 with a wrong-typed is_current (not boolean) fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.BadCurrentType do
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
            history_current_attribute(:is_current)
          end

          attributes do
            uuid_primary_key :id
            attribute :order_id, :string, allow_nil?: false
            attribute :valid_from_lsn, :integer, allow_nil?: false
            attribute :valid_to_lsn, :integer, allow_nil?: true
            # is_current declared as a string, not a boolean
            attribute :is_current, :string, allow_nil?: true
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

    assert err.message =~ "boolean"
  end

  test "SCD2 whose declared optional timestamp attribute is absent from the resource fails closed" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant]} do
        defmodule Elixir.AshReplicant.ValidateHistoryTest.OptionalAbsent do
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
            # names a ts attribute that is never declared below
            history_valid_from_timestamp_attribute(:valid_from_ts)
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

            update :close_version do
              accept [:valid_to_lsn]
            end
          end
        end
      end

    assert err.message =~ "not present"
  end
end
