defmodule AshReplicant.DeleteKeyTypesTest do
  use AshReplicant.DataCase, async: false
  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias Replicant.Casting.Types

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Uuid do
    use Ash.Resource,
      domain: AshReplicant.DeleteKeyTypesTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "delete_key_uuid"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("delete_key_uuid")
    end

    attributes do
      attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule IntegerKey do
    use Ash.Resource,
      domain: AshReplicant.DeleteKeyTypesTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "delete_key_integer"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("delete_key_integer")
    end

    attributes do
      attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule StringKey do
    use Ash.Resource,
      domain: AshReplicant.DeleteKeyTypesTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "delete_key_string"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("delete_key_string")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule AtomKey do
    use Ash.Resource,
      domain: AshReplicant.DeleteKeyTypesTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "delete_key_atom"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("delete_key_atom")
    end

    attributes do
      attribute :id, :atom,
        primary_key?: true,
        allow_nil?: false,
        public?: true,
        constraints: [one_of: [:ready, :spent]]
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule DecimalKey do
    use Ash.Resource,
      domain: AshReplicant.DeleteKeyTypesTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "delete_key_decimal"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("delete_key_decimal")
    end

    attributes do
      attribute :id, :decimal, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule Composite do
    use Ash.Resource,
      domain: AshReplicant.DeleteKeyTypesTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "delete_key_composite"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("delete_key_composite")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :partition, :integer, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  test "delete removes a uuid primary key row" do
    resource = Uuid
    record = %{"id" => "21df6e84-a204-4fb6-8504-ecb9b45c2741"}
    SQL.query!(TestRepo, "CREATE TABLE delete_key_uuid (id uuid PRIMARY KEY)")

    config = %{
      resolver_index: %{{"public", "delete_key_uuid"} => resource},
      repo: TestRepo,
      authorize?: false
    }

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "delete_key_uuid",
      record: record
    }

    assert :ok = AshReplicant.Apply.apply_change(config, change)
    assert [_row] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)
  end

  test "delete removes an integer primary key row" do
    resource = IntegerKey
    record = %{"id" => 41}
    SQL.query!(TestRepo, "CREATE TABLE delete_key_integer (id bigint PRIMARY KEY)")

    config = %{
      resolver_index: %{{"public", "delete_key_integer"} => resource},
      repo: TestRepo,
      authorize?: false
    }

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "delete_key_integer",
      record: record
    }

    assert :ok = AshReplicant.Apply.apply_change(config, change)
    assert [_row] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)
  end

  test "delete removes a string primary key row" do
    resource = StringKey
    record = %{"id" => "wire-key"}
    SQL.query!(TestRepo, "CREATE TABLE delete_key_string (id text PRIMARY KEY)")

    config = %{
      resolver_index: %{{"public", "delete_key_string"} => resource},
      repo: TestRepo,
      authorize?: false
    }

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "delete_key_string",
      record: record
    }

    assert :ok = AshReplicant.Apply.apply_change(config, change)
    assert [_row] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)
  end

  test "delete removes an atom primary key row" do
    resource = AtomKey
    record = %{"id" => "ready"}
    SQL.query!(TestRepo, "CREATE TABLE delete_key_atom (id text PRIMARY KEY)")

    config = %{
      resolver_index: %{{"public", "delete_key_atom"} => resource},
      repo: TestRepo,
      authorize?: false
    }

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "delete_key_atom",
      record: record
    }

    assert :ok = AshReplicant.Apply.apply_change(config, change)
    assert [_row] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)
  end

  test "delete removes a decimal primary key row" do
    resource = DecimalKey
    key = Types.cast_record("12.50", "numeric")
    assert %Decimal{} = key
    record = %{"id" => key}
    SQL.query!(TestRepo, "CREATE TABLE delete_key_decimal (id numeric PRIMARY KEY)")

    config = %{
      resolver_index: %{{"public", "delete_key_decimal"} => resource},
      repo: TestRepo,
      authorize?: false
    }

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "delete_key_decimal",
      record: record
    }

    assert :ok = AshReplicant.Apply.apply_change(config, change)
    assert [_row] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)
  end

  test "delete removes a composite primary key row" do
    resource = Composite
    record = %{"id" => "composite-key", "partition" => 7}

    SQL.query!(
      TestRepo,
      "CREATE TABLE delete_key_composite (id text, partition bigint, PRIMARY KEY (id, partition))"
    )

    config = %{
      resolver_index: %{{"public", "delete_key_composite"} => resource},
      repo: TestRepo,
      authorize?: false
    }

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "delete_key_composite",
      record: record
    }

    assert :ok = AshReplicant.Apply.apply_change(config, change)
    assert [_row] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)

    assert :ok =
             AshReplicant.Apply.apply_change(config, %{
               change
               | op: :delete,
                 record: nil,
                 old_record: record
             })

    assert [] = Ash.read!(resource, authorize?: false)
  end
end
