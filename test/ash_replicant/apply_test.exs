defmodule AshReplicant.ApplyTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Apply
  alias AshReplicant.Test.Order
  alias AshReplicant.Test.TenantOrder

  defmodule MirrorTruncateDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  # A NON-global attribute-multitenant resource with `on_truncate :mirror`. Reuses
  # the existing `tenant_orders` table (no migration) via a hand-built index — it is
  # NOT in `ash_domains`, so it does not affect migration-drift. Locks that the
  # truncate `:mirror` path clears tenant-blind instead of dead-ending on
  # `TenantRequired` (the pre-fix `Ash.bulk_destroy!`-without-tenant defect).
  defmodule MirrorTruncateOrder do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.ApplyTest.MirrorTruncateDomain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "tenant_orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("tenant_orders")
      tenant_attribute(:org_id)
      on_truncate(:mirror)
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :org_id, :string, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
    end

    multitenancy do
      strategy :attribute
      attribute :org_id
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defp config do
    {:ok, index} = AshReplicant.Resolver.build_index([AshReplicant.Test.Domain])
    %{resolver_index: index, repo: AshReplicant.TestRepo, authorize?: false}
  end

  defp change(op, table, record, old_record \\ nil, unchanged \\ []) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: table,
      record: record,
      old_record: old_record,
      unchanged: unchanged
    }
  end

  test "interleaved delete-then-insert of the same PK leaves the row PRESENT (order preserved)" do
    cfg = config()
    Apply.apply_change(cfg, change(:insert, "orders", %{"id" => "5", "note" => "a"}))
    Apply.apply_change(cfg, change(:delete, "orders", nil, %{"id" => "5"}))
    Apply.apply_change(cfg, change(:insert, "orders", %{"id" => "5", "note" => "b"}))

    assert %Order{note: "b"} = Ash.get!(Order, "5", authorize?: false)
  end

  test "insert-then-delete of the same PK leaves the row ABSENT" do
    cfg = config()
    Apply.apply_change(cfg, change(:insert, "orders", %{"id" => "7", "note" => "x"}))
    Apply.apply_change(cfg, change(:delete, "orders", nil, %{"id" => "7"}))
    assert Ash.get!(Order, "7", authorize?: false, error?: false) == nil
  end

  test "PK-changing UPDATE removes the old PK and writes the new one (no ghost row)" do
    cfg = config()
    Apply.apply_change(cfg, change(:insert, "orders", %{"id" => "5", "note" => "a"}))

    Apply.apply_change(
      cfg,
      change(:update, "orders", %{"id" => "6", "note" => "a"}, %{"id" => "5"})
    )

    assert Ash.get!(Order, "5", authorize?: false, error?: false) == nil
    assert %Order{note: "a"} = Ash.get!(Order, "6", authorize?: false)
  end

  test "unchanged TOAST column is left untouched on upsert" do
    cfg = config()
    big = String.duplicate("z", 5_000)

    Apply.apply_change(
      cfg,
      change(:insert, "orders", %{"id" => "9", "note" => "n1", "body" => big})
    )

    Apply.apply_change(
      cfg,
      change(:update, "orders", %{"id" => "9", "note" => "n2"}, %{"id" => "9"}, ["body"])
    )

    row = Ash.get!(Order, "9", authorize?: false)
    assert row.note == "n2"
    assert row.body == big, "unchanged TOAST col must be preserved, not clobbered to nil"
  end

  test "apply iterates the change stream exactly once (spilled single-pass safety)" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    once =
      Stream.resource(
        fn ->
          n = Agent.get_and_update(agent, &{&1, &1 + 1})
          if n > 0, do: raise("changes enumerated more than once"), else: :ok
        end,
        fn :ok -> {:halt, :ok} end,
        fn _ -> :ok end
      )

    assert :ok = Enum.each(once, fn _ -> :ok end)
    assert Agent.get(agent, & &1) == 1
  end

  test "a delete whose old_record lacks the PK fails closed (no silent lost delete)" do
    cfg = config()

    assert_raise AshReplicant.Error, fn ->
      Apply.apply_change(cfg, change(:delete, "orders", nil, %{"note" => "no pk here"}))
    end
  end

  test "multitenant delete on a NON-global resource derives the tenant from old_record (would break with tenant: nil)" do
    cfg = config()

    Apply.apply_change(
      cfg,
      change(:insert, "tenant_orders", %{"id" => "t1", "org_id" => "org_1", "note" => "n"})
    )

    assert %TenantOrder{} = Ash.get!(TenantOrder, "t1", tenant: "org_1", authorize?: false)

    Apply.apply_change(
      cfg,
      change(:delete, "tenant_orders", nil, %{"id" => "t1", "org_id" => "org_1"})
    )

    assert Ash.get!(TenantOrder, "t1", tenant: "org_1", authorize?: false, error?: false) == nil
  end

  test "on_truncate :mirror clears a NON-global tenant resource tenant-blind (no TenantRequired dead-end)" do
    cfg = %{
      resolver_index: %{{"public", "tenant_orders"} => MirrorTruncateOrder},
      repo: AshReplicant.TestRepo,
      authorize?: false
    }

    Ash.create!(MirrorTruncateOrder, %{id: "m1", org_id: "org_1", note: "a"},
      tenant: "org_1",
      authorize?: false
    )

    Ash.create!(MirrorTruncateOrder, %{id: "m2", org_id: "org_2", note: "b"},
      tenant: "org_2",
      authorize?: false
    )

    # Pre-fix: Ash.bulk_destroy! without a tenant raised TenantRequired here → dead-end.
    assert :ok = Apply.apply_change(cfg, change(:truncate, "tenant_orders", nil))

    assert Ash.get!(MirrorTruncateOrder, "m1", tenant: "org_1", authorize?: false, error?: false) ==
             nil

    assert Ash.get!(MirrorTruncateOrder, "m2", tenant: "org_2", authorize?: false, error?: false) ==
             nil
  end

  test "truncate with on_truncate :halt fails closed with a value-free error" do
    cfg = config()

    err =
      assert_raise AshReplicant.Error, fn ->
        Apply.apply_change(cfg, change(:truncate, "orders", nil))
      end

    assert err.reason == :truncate_halt
    # value-free: message names only reason/resource/op/shape, no row value
    refute Exception.message(err) =~ "note"
  end
end
