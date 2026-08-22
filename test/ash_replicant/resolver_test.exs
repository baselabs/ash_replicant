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
    RaisingMfaOrder,
    Secret,
    TenantOrder
  }

  defmodule LsnOnlyDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule LsnOnlyVersion do
    @moduledoc """
    A valid SCD2 version resource declaring ONLY the LSN window columns — no
    optional `history_valid_from_timestamp_attribute` / `..._valid_to_timestamp` /
    `history_current_attribute`. Exercises `version_open_input/3`'s `maybe_put`
    nil-skip (omit) branch, which every AshPostgres fixture leaves uncovered because
    they all declare the optional attrs. ETS-backed: `version_open_input/3` is pure
    DSL/record reflection, so no table or migration is needed.
    """
    use Ash.Resource,
      domain: AshReplicant.ResolverTest.LsnOnlyDomain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReplicant.Resource]

    replicant do
      source_table("orders")
      history_strategy(:scd2)
      history_business_key([:order_id])
      upsert_identity(:ov)
      history_close_action(:close_version)
    end

    attributes do
      uuid_primary_key :id
      attribute :order_id, :string, allow_nil?: false
      attribute :valid_from_lsn, :integer, allow_nil?: false
      attribute :valid_to_lsn, :integer, allow_nil?: true
    end

    identities do
      identity :ov, [:order_id, :valid_from_lsn],
        pre_check_with: AshReplicant.ResolverTest.LsnOnlyDomain
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      update :close_version do
        accept [:valid_to_lsn]
      end
    end
  end

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

    # Ash treats a falsy tenant as NO scoping: `handle_attribute_multitenancy` guards on
    # `if changeset.tenant` (create.ex) and `validate_changeset_multitenancy` keys on
    # `is_nil(changeset.tenant)` (helpers.ex) — so `false` is neither force-set NOR
    # rejected, and the mirror write lands UNSCOPED across tenants. Both a `tenant_attribute`
    # column holding `false` and a `tenant_mfa` returning `false` must fail closed. One test
    # per source: each path is an independent observation channel for the mutation matrix
    # (ExUnit reports only a test's first failing assertion).
    test "a boolean-false tenant_attribute value fails closed (falsy tenant = UNSCOPED — tripwire)" do
      assert {:error, :tenant_required} = Resolver.resolve_tenant(Account, %{"org_id" => false})
    end

    test "a boolean-false tenant_mfa result fails closed (falsy tenant = UNSCOPED — tripwire)" do
      assert {:error, :tenant_required} =
               Resolver.resolve_tenant(MfaOrder, %{"tenant_key" => false})
    end
  end

  describe "require_tenant_pair!/3 (B4 tri-modal tenant transition)" do
    # Pure no-database observers (resource reflection + record maps, no Repo):
    # the mutation matrix drives these against the fail-closed reassignment
    # guards. The live relocate/close behavior stays in the integration suite.
    test ":same update keeps the upsert path (old side resolved, no relocate)" do
      change = %Replicant.Change{
        op: :update,
        schema: "public",
        table: "tenant_orders",
        record: %{"id" => "1", "org_id" => "org-a", "note" => "n"},
        old_record: %{"id" => "1", "org_id" => "org-a"}
      }

      assert {:ok, :same, "org-a", "org-a"} =
               Resolver.require_tenant_pair!(TenantOrder, change, :upsert)
    end

    test ":reassigned transition classifies (old side resolved, differs)" do
      change = %Replicant.Change{
        op: :update,
        schema: "public",
        table: "tenant_orders",
        record: %{"id" => "1", "org_id" => "org-b"},
        old_record: %{"id" => "1", "org_id" => "org-a"}
      }

      assert {:ok, :reassigned, "org-a", "org-b"} =
               Resolver.require_tenant_pair!(TenantOrder, change, :upsert)
    end

    test "an update with NO old tuple on a tenant-scoped resource halts :tenant_required side=old (tripwire)" do
      # The DEFAULT-replica-identity pgoutput shape: no old tuple at all. On a
      # tenant-scoped resource the old side is structurally REQUIRED — silently
      # treating the update as :same would let a tenant reassignment keep the
      # row under the old tenant. Must halt BEFORE any write.
      change = %Replicant.Change{
        op: :update,
        schema: "public",
        table: "tenant_orders",
        record: %{"id" => "1", "org_id" => "org-b"},
        old_record: nil
      }

      err =
        assert_raise AshReplicant.Error, fn ->
          Resolver.require_tenant_pair!(TenantOrder, change, :update)
        end

      assert err.reason == :tenant_required
      assert err.shape == "side=old"
    end

    test "missing old tenant halts :tenant_required side=old BEFORE any write" do
      change = %Replicant.Change{
        op: :update,
        schema: "public",
        table: "tenant_orders",
        record: %{"id" => "1", "org_id" => "org-b"},
        old_record: %{"id" => "1"}
      }

      err =
        assert_raise AshReplicant.Error, fn ->
          Resolver.require_tenant_pair!(TenantOrder, change, :upsert)
        end

      assert err.reason == :tenant_required
      assert err.shape == "side=old"
    end

    test "blank/false old tenant halts :tenant_required side=old" do
      for blank <- ["", false] do
        change = %Replicant.Change{
          op: :update,
          schema: "public",
          table: "tenant_orders",
          record: %{"id" => "1", "org_id" => "org-b"},
          old_record: %{"id" => "1", "org_id" => blank}
        }

        err =
          assert_raise AshReplicant.Error, fn ->
            Resolver.require_tenant_pair!(TenantOrder, change, :upsert)
          end

        assert err.reason == :tenant_required
        assert err.shape == "side=old"
      end
    end

    test "a raising tenant_mfa on the old side halts :tenant_resolution_failed" do
      change = %Replicant.Change{
        op: :update,
        schema: "public",
        table: "raising_mfa_orders",
        record: %{"id" => "1", "tenant_key" => "k2"},
        old_record: %{"id" => "1"}
      }

      err =
        assert_raise AshReplicant.Error, fn ->
          Resolver.require_tenant_pair!(RaisingMfaOrder, change, :upsert)
        end

      assert err.reason == :tenant_resolution_failed
      assert err.shape == "side=old"

      # The raising message never escapes (value-free): the rendered error
      # carries only reason/resource/op/shape.
      refute Exception.message(err) =~ "raising resolver"
    end

    test "insert resolves only the new side (:same)" do
      change = %Replicant.Change{
        op: :insert,
        schema: "public",
        table: "tenant_orders",
        record: %{"id" => "1", "org_id" => "org-a"}
      }

      assert {:ok, :same, nil, "org-a"} =
               Resolver.require_tenant_pair!(TenantOrder, change, :create)
    end

    test "a non-tenant resource always resolves :same with nil tenants" do
      change = %Replicant.Change{
        op: :update,
        schema: "public",
        table: "orders",
        record: %{"id" => "1"},
        old_record: %{"id" => "1"}
      }

      assert {:ok, :same, nil, nil} =
               Resolver.require_tenant_pair!(Order, change, :upsert)
    end
  end

  describe "the delivery paths enter the tenant-pair prelude (live source pins)" do
    # The B4 prelude is only a guard if both delivery paths actually CALL it
    # before their first effect. A deleted or reordered prelude silently
    # reopens the indeterminate-tenant window with every behavioral test
    # above still green, so each call site is pinned against the live source:
    # present exactly once, ahead of the first effect of its clause.
    test "Apply enters require_tenant_pair!/3 before the mirror upsert (live source pin)" do
      source = File.read!("lib/ash_replicant/apply.ex")

      calls =
        count_lines_containing(source, "Resolver.require_tenant_pair!(resource, change, op)")

      assert calls == 1,
             "lib/ash_replicant/apply.ex carries #{calls} tenant-pair preludes, expected 1"

      {prelude, _} =
        :binary.match(source, "Resolver.require_tenant_pair!(resource, change, op)")

      {effect, _} = :binary.match(source, "upsert(config, resource, change)")

      assert prelude < effect,
             "the Apply tenant-pair prelude must run before the mirror upsert effect"
    end

    test "Apply.Scd2 enters require_tenant_pair!/3 before the version close/open (live source pin)" do
      source = File.read!("lib/ash_replicant/apply/scd2.ex")

      calls =
        count_lines_containing(source, "Resolver.require_tenant_pair!(resource, change, op)")

      assert calls == 1,
             "lib/ash_replicant/apply/scd2.ex carries #{calls} tenant-pair preludes, expected 1"

      {prelude, _} =
        :binary.match(source, "Resolver.require_tenant_pair!(resource, change, op)")

      {effect, _} = :binary.match(source, "close_current(")

      assert prelude < effect,
             "the Apply.Scd2 tenant-pair prelude must run before the version close/open effects"
    end
  end

  describe "attrs_for_upsert/2 (classification)" do
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

  defp count_lines_containing(source, needle) do
    source
    |> String.split("\n")
    |> Enum.count(&String.contains?(&1, needle))
  end

  describe "SCD2 helpers" do
    test "business_key_values/2 pulls the declared business key from a string-keyed source record" do
      record = %{"order_id" => "o-1", "amount" => "9.99", "org_id" => "t-1"}

      assert AshReplicant.Resolver.business_key_values(AshReplicant.Test.OrderVersion, record) ==
               %{order_id: "o-1"}
    end

    test "version_open_input/3 opens a version with ALL declared window columns (present-optional path)" do
      {inputs, fields} =
        Resolver.version_open_input(
          AshReplicant.Test.OrderVersion,
          %{"order_id" => "o-1", "amount" => "9.99"},
          %{lsn: 42, ts: ~U[2026-01-01 00:00:00.000000Z]}
        )

      # source data columns (via attrs_for_upsert) carry through
      assert inputs[:order_id] == "o-1"
      assert inputs[:amount] == "9.99"

      # window columns stamped: valid_from_lsn, valid_to_lsn: nil, and the declared
      # optional valid_from_ts + is_current
      assert inputs[:valid_from_lsn] == 42
      assert Map.has_key?(inputs, :valid_to_lsn)
      assert inputs[:valid_to_lsn] == nil
      assert inputs[:valid_from_ts] == ~U[2026-01-01 00:00:00.000000Z]
      assert inputs[:is_current] == true

      # upsert_fields name every window column so a same-lsn re-open coalesces...
      for col <- [:valid_from_lsn, :valid_to_lsn, :valid_from_ts, :is_current] do
        assert col in fields
      end

      # ...with no duplicate field names
      assert Enum.uniq(fields) == fields
    end

    test "version_open_input/3 OMITS undeclared optional window columns (LSN-only path)" do
      {inputs, fields} =
        Resolver.version_open_input(
          LsnOnlyVersion,
          %{"order_id" => "o-2"},
          %{lsn: 7, ts: ~U[2026-01-01 00:00:00.000000Z]}
        )

      assert inputs[:order_id] == "o-2"
      assert inputs[:valid_from_lsn] == 7
      assert Map.has_key?(inputs, :valid_to_lsn)
      assert inputs[:valid_to_lsn] == nil

      # the optional columns are NOT declared on this resource, so the maybe_put
      # nil-skip branch drops them from BOTH inputs and upsert_fields
      refute Map.has_key?(inputs, :valid_from_ts)
      refute Map.has_key?(inputs, :valid_to_ts)
      refute Map.has_key?(inputs, :is_current)

      refute :valid_from_ts in fields
      refute :valid_to_ts in fields
      refute :is_current in fields
    end
  end
end
