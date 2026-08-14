defmodule AshReplicant.Test.CheckpointIdentitySkipOrder do
  @moduledoc false
  # Minimal deterministic fixture for the classifier matrix: one relation with a
  # declared skip, one plain column, no tenant.
  use Ash.Resource,
    domain: AshReplicant.Test.CheckpointIdentitySkipDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "checkpoint_identity_skip_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("skip_orders")
    skip([:audit_note])
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :external_code, :string, public?: true
    attribute :audit_note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.CheckpointIdentitySkipDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.CheckpointIdentitySkipOrder
  end
end

defmodule AshReplicant.CheckpointIdentityTest do
  @moduledoc """
  Pure unit tests for the canonical publication/resolver contract and its
  set-monotone transition classifier (roadmap B2). No database: the contract is
  reflection over compiled resources; the classifier is a pure function over
  two manifests.
  """
  use ExUnit.Case, async: true

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Test.{Account, Domain, Order, Secret}

  @publication ["orders_pub"]

  test "canonical_contract/2 builds the value-free structure" do
    assert {:ok, contract} = Identity.canonical_contract(sink_config(), @publication)

    assert contract.contract_version == 1
    assert contract.publication == @publication
    assert contract.ignores == []

    order = find_relation(contract, "public", "orders")
    assert order.resource == Order
    assert order.tenant == nil
    assert order.skips == []

    assert %{source: "note", target: :note, sensitive: false} = find_column(order, "note")

    secret = find_relation(contract, "public", "secret_orders")
    assert %{source: "pan", target: :encrypted_pan, sensitive: true} = find_column(secret, "pan")

    account = find_relation(contract, "public", "accounts")
    assert account.tenant == %{kind: :attribute, source: "org_id"}
  end

  test "determinism: repeated and input-order-shuffled builds are identical" do
    assert {:ok, first} = Identity.canonical_contract(sink_config(), @publication)
    assert {:ok, second} = Identity.canonical_contract(sink_config(), @publication)
    assert first == second
    assert Identity.encode(first) == Identity.encode(second)

    assert {:ok, shuffled} =
             Identity.canonical_contract(sink_config(), Enum.reverse(@publication))

    assert shuffled == first
  end

  test "value-free: every binary in the contract is an identifier-shaped name" do
    {:ok, contract} = Identity.canonical_contract(sink_config(), @publication)

    for binary <- deep_binaries(contract) do
      assert String.match?(binary, ~r/^[a-zA-Z0-9_]+$/),
             "non-identifier binary in the contract: #{inspect(binary)}"
    end
  end

  describe "classify/2 — the transition matrix" do
    setup do
      {:ok, contract} =
        Identity.canonical_contract(
          %{domains: [AshReplicant.Test.CheckpointIdentitySkipDomain]},
          [
            "skip_pub"
          ]
        )

      %{base: contract}
    end

    test "nil stored (adopted row) initializes compatibly", %{base: base} do
      assert Identity.classify(nil, base) == {:compatible, :initialized}
    end

    test "identical contracts are :equal", %{base: base} do
      assert Identity.classify(base, base) == :equal
    end

    test "a brand-new column ADDED is compatible", %{base: base} do
      grown =
        mutate(base, fn rel ->
          %{
            rel
            | columns:
                put_column(rel, %{source: "brand_new", target: :brand_new, sensitive: false})
          }
        end)

      assert Identity.classify(base, grown) == {:compatible, :relations_added}
    end

    test "a column moved columns -> skips is compatible (ignore addition)", %{base: base} do
      moved =
        mutate(base, fn rel ->
          %{
            rel
            | columns: drop_column(rel, "external_code"),
              skips: Enum.sort(["external_code" | rel.skips])
          }
        end)

      assert Identity.classify(base, moved) == {:compatible, :relations_added}
    end

    test "a skip REACTIVATED (skips -> columns) is incompatible", %{base: base} do
      reactivated =
        mutate(base, fn rel ->
          %{
            rel
            | columns:
                put_column(rel, %{source: "audit_note", target: :audit_note, sensitive: false}),
              skips: List.delete(rel.skips, "audit_note")
          }
        end)

      assert Identity.classify(base, reactivated) == {:incompatible, :skip_reactivated}
    end

    test "a relation ADDED is compatible", %{base: base} do
      relation = find_relation(base, "public", "skip_orders")
      new_relation = %{relation | schema: "other", table: "other_orders"}

      added = %{
        base
        | relations: Enum.sort_by([new_relation | base.relations], &{&1.schema, &1.table})
      }

      assert Identity.classify(base, added) == {:compatible, :relations_added}
    end

    test "a relation REMOVED is incompatible", %{base: base} do
      removed = %{base | relations: []}
      assert Identity.classify(base, removed) == {:incompatible, :relation_removed}
    end

    test "a relation RETARGETED (resource swap) is incompatible", %{base: base} do
      retargeted = mutate(base, &%{&1 | resource: Order})
      assert Identity.classify(base, retargeted) == {:incompatible, :relation_retargeted}
    end

    test "a column REMOVED outright is incompatible", %{base: base} do
      removed = mutate(base, &%{&1 | columns: drop_column(&1, "external_code")})
      assert Identity.classify(base, removed) == {:incompatible, :column_removed}
    end

    test "a column RE-TARGETED is incompatible", %{base: base} do
      retargeted =
        mutate(base, fn rel ->
          put_column(rel, %{source: "external_code", target: :renamed_code, sensitive: false})
          |> then(&%{rel | columns: &1})
        end)

      assert Identity.classify(base, retargeted) == {:incompatible, :column_changed}
    end

    test "a column TYPE change is incompatible", %{base: base} do
      typed = mutate(base, &%{&1 | types: Map.put(&1.types, :external_code, :integer)})
      assert Identity.classify(base, typed) == {:incompatible, :column_type}
    end

    test "a TENANT source change is incompatible", %{base: base} do
      tenanted = mutate(base, &%{&1 | tenant: %{kind: :attribute, source: "org_id"}})
      assert Identity.classify(base, tenanted) == {:incompatible, :tenant_source}
    end

    test "a PUBLICATION change is incompatible (addition and removal)", %{base: base} do
      added = %{base | publication: ["skip_pub", "other_pub"]}
      assert Identity.classify(base, added) == {:incompatible, :publication}

      removed = %{base | publication: []}
      assert Identity.classify(base, removed) == {:incompatible, :publication}
    end

    test "a contract VERSION change is incompatible (both directions)", %{base: base} do
      bumped = %{base | contract_version: 2}
      assert Identity.classify(base, bumped) == {:incompatible, :version}
      assert Identity.classify(bumped, base) == {:incompatible, :version}
    end

    test "an ignores ADDITION is compatible (B3's explicit ignores land additively)", %{
      base: base
    } do
      grown = %{base | ignores: ["other_schema.other_table"]}
      assert Identity.classify(base, grown) == {:compatible, :relations_added}
    end
  end

  describe "encode/decode/fingerprint round trip" do
    test "round trip preserves the manifest and the digest-of-stored-bytes rule" do
      {:ok, contract} = Identity.canonical_contract(sink_config(), @publication)
      encoded = Identity.encode(contract)
      assert {:ok, ^contract} = Identity.decode(encoded)
      assert Identity.fingerprint(encoded) == :crypto.hash(:sha256, encoded)
      assert byte_size(Identity.fingerprint(encoded)) == 32
    end

    test "garbage decodes as :error (fail-closed, never mis-classified)" do
      assert Identity.decode("not a term") == :error
      assert Identity.decode(:erlang.term_to_binary(%{contract_version: 1})) == :error
    end
  end

  # --- helpers ---

  defp sink_config do
    %{
      domains: [Domain],
      repo: AshReplicant.TestRepo,
      slot_name: "orders",
      checkpoint_resource: AshReplicant.Test.Checkpoint
    }
  end

  defp find_relation(contract, schema, table) do
    Enum.find(contract.relations, &(&1.schema == schema and &1.table == table))
  end

  defp find_column(relation, source), do: Enum.find(relation.columns, &(&1.source == source))

  defp mutate(base, fun) do
    [only] = base.relations
    %{base | relations: [fun.(only)]}
  end

  defp put_column(rel, column) do
    Enum.sort_by([column | Enum.reject(rel.columns, &(&1.source == column.source))], & &1.source)
  end

  defp drop_column(rel, source), do: Enum.reject(rel.columns, &(&1.source == source))

  defp deep_binaries(term), do: collect(term, [])

  defp collect(binary, acc) when is_binary(binary), do: [binary | acc]

  defp collect(map, acc) when is_map(map),
    do: Enum.flat_map(Map.to_list(map), fn {k, v} -> collect(k, acc) ++ collect(v, acc) end)

  defp collect(list, acc) when is_list(list), do: Enum.flat_map(list, &collect(&1, acc))
  defp collect(_other, acc), do: acc
end
