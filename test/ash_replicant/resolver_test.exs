defmodule AshReplicant.ResolverTest do
  use ExUnit.Case, async: true

  alias AshReplicant.Resolver

  alias AshReplicant.Test.{
    Account,
    Domain,
    DuplicateDomain,
    MfaOrder,
    NoSourceDomain,
    Order,
    Secret,
    TenantOrder
  }

  describe "build_index/1" do
    test "keys mirror resources by {source_schema, source_table}, filtering out non-replicant resources" do
      assert {:ok, index} = Resolver.build_index([Domain])
      assert index[{"public", "orders"}] == Order
      assert index[{"public", "accounts"}] == Account
      assert index[{"public", "tenant_orders"}] == TenantOrder
      assert index[{"public", "secret_orders"}] == Secret
      assert map_size(index) == 4
    end

    test "fails closed on a duplicate {schema, table} (tripwire)" do
      assert {:error, {:duplicate_source, {"public", "dup_orders"}}} =
               Resolver.build_index([DuplicateDomain])
    end

    test "fails closed on a nil source_table (MANDATE 1 tripwire)" do
      assert {:error, {:missing_source_table, AshReplicant.Test.NoSource}} =
               Resolver.build_index([NoSourceDomain])
    end
  end

  describe "resolve_tenant/2" do
    test "reads the tenant attribute from the record" do
      assert {:ok, "org_1"} =
               Resolver.resolve_tenant(Account, %{"id" => "1", "org_id" => "org_1"})
    end

    test "a nil, blank, or whitespace-only or missing tenant fails closed (tripwire)" do
      assert {:error, :tenant_required} = Resolver.resolve_tenant(Account, %{"org_id" => nil})
      assert {:error, :tenant_required} = Resolver.resolve_tenant(Account, %{"org_id" => ""})
      assert {:error, :tenant_required} = Resolver.resolve_tenant(Account, %{"org_id" => "   "})
      assert {:error, :tenant_required} = Resolver.resolve_tenant(Account, %{})
    end

    test "a non-tenant resource resolves to {:ok, nil}" do
      assert {:ok, nil} = Resolver.resolve_tenant(Order, %{"id" => "1"})
    end

    test "tenant_mfa {m, f, [extra]} applies as apply(m, f, [record | extra_args])" do
      # MfaOrder declares tenant_mfa {TenantMfa, :resolve, ["tenant_key"]};
      # resolve(record, "tenant_key") == Map.get(record, "tenant_key"). This
      # proves the {:tuple, [:atom, :atom, {:list, :any}]} type validated the
      # 3-tuple AND the resolver threads [record | extra_args] correctly.
      assert {:ok, "org_9"} = Resolver.resolve_tenant(MfaOrder, %{"tenant_key" => "org_9"})
    end

    test "tenant_mfa fails closed on a nil/blank/missing resolved tenant (tripwire)" do
      assert {:error, :tenant_required} = Resolver.resolve_tenant(MfaOrder, %{})

      assert {:error, :tenant_required} =
               Resolver.resolve_tenant(MfaOrder, %{"tenant_key" => nil})

      assert {:error, :tenant_required} =
               Resolver.resolve_tenant(MfaOrder, %{"tenant_key" => "  "})
    end
  end

  describe "writable_target/2 + attrs_for_upsert/2 (classification)" do
    test "a sensitive column maps to its AshCloak encrypted target" do
      assert {:ok, :encrypted_pan} = Resolver.writable_target(Secret, "pan")
    end

    test "attrs_for_upsert passes plaintext under the cloak argument but upsert_fields names the encrypted attr" do
      {inputs, fields} = Resolver.attrs_for_upsert(Secret, %{"id" => "1", "pan" => "4111"})
      assert inputs[:pan] == "4111"
      assert :encrypted_pan in fields
      refute :pan in fields
      assert :id in fields
    end

    test "a plain column maps its input key and upsert_field to the same attribute atom" do
      {inputs, fields} = Resolver.attrs_for_upsert(Order, %{"id" => "5", "note" => "x"})
      assert inputs == %{id: "5", note: "x"}
      assert :id in fields and :note in fields
    end
  end

  describe "upsert_reflection/1 + upsert_input/2 (batch-invariant hoist)" do
    test "upsert_input under a precomputed reflection routes a cloak row to encrypted fields" do
      reflection = Resolver.upsert_reflection(Secret)

      # Assert the CONCRETE shape (not equality with attrs_for_upsert/2, which would be
      # tautological once that delegates) so a broken split goes red independently:
      # a cloak column passes plaintext under :pan but names encrypted_pan in fields.
      {inputs, fields} = Resolver.upsert_input(reflection, %{"id" => "1", "pan" => "4111"})
      assert inputs == %{id: "1", pan: "4111"}
      assert :encrypted_pan in fields
      assert :id in fields
      refute :pan in fields

      # A second, differently-shaped row reuses the SAME reflection (batch-invariant,
      # not row-specific) and still maps correctly.
      assert Resolver.upsert_input(reflection, %{"id" => "2"}) == {%{id: "2"}, [:id]}
    end

    test "upsert_reflection/1 is the batch-invariant {skip, cloak, attrs} triple" do
      {skip, cloak, attrs} = Resolver.upsert_reflection(Order)
      assert skip == []
      assert cloak == []
      assert MapSet.member?(attrs, :note)
      refute MapSet.member?(attrs, :nonexistent)
    end
  end

  describe "primary_key/1, pk_values/2, upsert_action/1, upsert_identity/1" do
    test "PK extraction is string-keyed and composite-safe" do
      assert Resolver.primary_key(Order) == [:id]
      assert Resolver.pk_values(Order, %{"id" => "5", "note" => "n"}) == %{id: "5"}
    end

    test "upsert_action/1 is the resource's primary create action; upsert_identity/1 defaults to nil (PK upsert)" do
      assert Resolver.upsert_action(Order) == :create
      assert Resolver.upsert_identity(Order) == nil
    end
  end
end
