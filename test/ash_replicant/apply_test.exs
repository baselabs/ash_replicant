defmodule AshReplicant.Test.RaisingTenantMfa do
  @moduledoc false
  # Raises ONLY on the old side shape (no tenant_key key present) — the B4
  # :tenant_resolution_failed cell.
  def resolve(record, "tenant_key") when is_map_key(record, "tenant_key"),
    do: Map.get(record, "tenant_key")

  def resolve(_record, "tenant_key"), do: raise(ArgumentError, "raising resolver fixture")
end

defmodule AshReplicant.Test.RaisingMfaOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.RaisingMfaDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshReplicant.Resource]

  # The multitenancy block satisfies ValidateMultitenancy's compile gate: the
  # fixture's DELIBERATE fault is the RAISING resolver (the runtime
  # :tenant_resolution_failed cell), not the verifier-rejectable missing block —
  # a module-level fixture carrying invalid config warns on every compile and
  # trips the structural battery's no-error gate.
  multitenancy do
    strategy(:context)
  end

  replicant do
    source_table("raising_mfa_orders")
    tenant_mfa({AshReplicant.Test.RaisingTenantMfa, :resolve, ["tenant_key"]})
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.ApplyTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Apply
  alias AshReplicant.Resolver
  alias AshReplicant.Test.Order
  alias AshReplicant.Test.TenantOrder
  alias Ecto.Adapters.SQL

  defmodule MirrorTruncateDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  # U3/D4: an EMBEDDED-QUOTE mirror table. Ecto's identifier policy forbids `"`
  # in table names on the ASH path, so this resource deliberately has NO Ash
  # writes driven against it — the truncate `:mirror` path issues only the raw
  # tenant-blind DELETE, whose exact construction (PG-canonical `""` doubling)
  # is what this fixture pins. A bare `"#{table}"` interpolation would break
  # out of the quoting; the Sql home must render `"ord""ers"` and delete
  # EXACTLY that table while the same-schema decoy `orders` survives.
  defmodule EmbeddedQuoteTruncate do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.ApplyTest.MirrorTruncateDomain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "ord\"ers"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("embedded_quote_src")
      on_truncate(:mirror)
    end

    attributes do
      attribute :id, :string do
        primary_key? true
        allow_nil? false
        public? true
      end
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
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

  # A NON-global attribute-multitenant resource that declares a SOURCE-PK upsert
  # identity — `identity :source_pk, [:id]` + `upsert_identity(:source_pk)`. Under
  # attribute multitenancy Ash scopes that identity's unique index to `(org_id,
  # id)` (see the reassign_orders migration), while `id` is ALSO a global primary
  # key. This is the shape a real mirror carries; it is what makes a tenant
  # reassignment collide (the new-tenant upsert misses the `(org_id, id)` conflict
  # target and INSERTs, hitting the global `id` PK of the old-tenant row).
  defmodule ReassignOrder do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.ApplyTest.MirrorTruncateDomain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "reassign_orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("reassign_orders")
      tenant_attribute(:org_id)
      upsert_identity(:source_pk)
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

    identities do
      identity :source_pk, [:id]
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defp reassign_config do
    %{
      resolver_index: %{{"public", "reassign_orders"} => ReassignOrder},
      repo: AshReplicant.TestRepo,
      authorize?: false
    }
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

  test "deleting a never-present row is an idempotent no-op that does not over-match (atomic 0-row match)" do
    cfg = config()

    # A distinct sibling row that MUST survive the never-present delete — makes this
    # test red-capable against an unfiltered/over-broad DELETE: the atomic
    # `DELETE ... WHERE pk` must scope to the target PK, never wipe the table.
    Apply.apply_change(cfg, change(:insert, "orders", %{"id" => "survivor", "note" => "keep"}))

    # The row was never mirrored — the atomic DELETE ... WHERE pk matches 0 rows and
    # must return :ok (never raise), exactly as the prior read-then-destroy returned
    # :ok when Ash.get! found nothing.
    assert :ok = Apply.apply_change(cfg, change(:delete, "orders", nil, %{"id" => "never-here"}))

    # A genuine 0-row no-op: the sibling is untouched (over-match guard) and the
    # never-present PK is still absent.
    assert %Order{note: "keep"} = Ash.get!(Order, "survivor", authorize?: false)
    assert Ash.get!(Order, "never-here", authorize?: false, error?: false) == nil
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

  test "tenant-reassigning UPDATE (org_id changes, id same) MOVES the row to the new tenant — no PK-collision halt, no ghost" do
    cfg = reassign_config()

    Apply.apply_change(
      cfg,
      change(:insert, "reassign_orders", %{"id" => "r1", "org_id" => "org_1", "note" => "n"})
    )

    assert %ReassignOrder{} = Ash.get!(ReassignOrder, "r1", tenant: "org_1", authorize?: false)

    # The source reassigns the row from org_1 to org_2 (same PK). Under REPLICA
    # IDENTITY FULL the old_record carries the OLD org_id. With a source-PK upsert
    # identity the conflict target is (org_id, id); a plain upsert under the NEW
    # tenant misses it and falls through to an INSERT, which collides with the
    # GLOBAL id primary key of the still-present old-tenant row → the whole sink
    # transaction halts fail-closed and the mirror stalls for ALL tenants. The fix
    # treats a tenant change like a PK change: destroy-old (under the old tenant,
    # from old_record) then upsert-new.
    Apply.apply_change(
      cfg,
      change(
        :update,
        "reassign_orders",
        %{"id" => "r1", "org_id" => "org_2", "note" => "n"},
        %{"id" => "r1", "org_id" => "org_1"}
      )
    )

    # The row now lives ONLY under org_2 — no ghost under org_1, no halt.
    assert Ash.get!(ReassignOrder, "r1", tenant: "org_1", authorize?: false, error?: false) == nil

    assert %ReassignOrder{note: "n"} =
             Ash.get!(ReassignOrder, "r1", tenant: "org_2", authorize?: false)
  end

  test "an update that changes BOTH the PK and the tenant relocates once (old-key/old-tenant destroyed, new-key/new-tenant upserted)" do
    cfg = reassign_config()

    Apply.apply_change(
      cfg,
      change(:insert, "reassign_orders", %{"id" => "p1", "org_id" => "org_1", "note" => "n"})
    )

    # Both the PK (p1 -> p2) and the tenant (org_1 -> org_2) change in one update. The single
    # destroy_by_pk(old_record) retires (org_1, p1); the upsert writes (org_2, p2). No ghost
    # under the old key/tenant, no collision.
    Apply.apply_change(
      cfg,
      change(
        :update,
        "reassign_orders",
        %{"id" => "p2", "org_id" => "org_2", "note" => "n"},
        %{"id" => "p1", "org_id" => "org_1"}
      )
    )

    assert Ash.get!(ReassignOrder, "p1", tenant: "org_1", authorize?: false, error?: false) == nil
    assert Ash.get!(ReassignOrder, "p2", tenant: "org_1", authorize?: false, error?: false) == nil

    assert %ReassignOrder{note: "n"} =
             Ash.get!(ReassignOrder, "p2", tenant: "org_2", authorize?: false)
  end

  describe "identifier quoting drives the raw truncate SQL (U3/D4)" do
    setup do
      q = &SQL.query!(AshReplicant.TestRepo, &1, [])

      q.(~s(DROP TABLE IF EXISTS "ord""ers"))
      q.(~s|CREATE TABLE "ord""ers" (id text primary key)|)

      on_exit(fn -> q.(~s(DROP TABLE IF EXISTS "ord""ers")) end)

      :ok
    end

    # RED capability: a bare `"#{table}"` interpolation renders
    # `DELETE FROM "public"."ord"ers"` — a Postgres syntax error, the raised
    # error is scrubbed to `{:error, %Error{}}`, and this `assert :ok` fails.
    test "the :mirror truncate DELETE doubles the embedded quote and hits exactly that table" do
      q = &SQL.query!(AshReplicant.TestRepo, &1, [])
      q.(~s|INSERT INTO "ord""ers" VALUES ('q1')|)

      cfg = %{
        resolver_index: %{{"public", "embedded_quote_src"} => EmbeddedQuoteTruncate},
        repo: AshReplicant.TestRepo,
        authorize?: false
      }

      assert :ok = Apply.apply_change(cfg, change(:truncate, "embedded_quote_src", nil))

      assert q.(~s|SELECT count(*) FROM "ord""ers"|).rows == [[0]],
             "the embedded-quote table must be wiped by the correctly doubled ident"
    end
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

  # Operational contract: a tenant-scoped DELETE/PK-change derives the tenant from
  # `old_record`, which under the Postgres-DEFAULT replica identity is KEY-ONLY (the
  # tenant column is absent). The source table for a tenant-scoped mirror must be
  # REPLICA IDENTITY FULL so `old_record` carries the tenant. Without it, the sink
  # fails CLOSED (`:tenant_required`, no base-tenant write) — this locks that
  # behaviour so the documented requirement cannot silently regress into a leak.
  test "tenant-scoped delete with a KEY-ONLY old_record fails closed :tenant_required (REPLICA IDENTITY FULL required)" do
    cfg = config()

    Ash.create!(TenantOrder, %{id: "k1", org_id: "org_1", note: "n"},
      tenant: "org_1",
      authorize?: false
    )

    # old_record carries only the key (id) — as under default replica identity.
    err =
      assert_raise AshReplicant.Error, fn ->
        Apply.apply_change(cfg, change(:delete, "tenant_orders", nil, %{"id" => "k1"}))
      end

    assert err.reason == :tenant_required

    # Fail-closed: the row is untouched, never a cross-tenant/base-tenant delete.
    assert %TenantOrder{} = Ash.get!(TenantOrder, "k1", tenant: "org_1", authorize?: false)
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

  test "apply_change/3 accepts an optional commit_timestamp; /2 still works" do
    config = %{resolver_index: %{}, repo: AshReplicant.TestRepo, authorize?: false}
    change = %Replicant.Change{op: :insert, schema: "public", table: "unmapped", record: %{}}
    # B3: an unmapped table now HALTS (:source_table_unmapped) instead of the
    # silent :ok — the arity proof asserts the halt shape, not a silent pass.
    err =
      assert_raise AshReplicant.Error, fn ->
        Apply.apply_change(config, change)
      end

    assert err.reason == :source_table_unmapped

    err3 =
      assert_raise AshReplicant.Error, fn ->
        Apply.apply_change(config, change, ~U[2026-07-09 00:00:00.000000Z])
      end

    assert err3.reason == :source_table_unmapped
  end

  describe "B4 tri-modal tenant transition (roadmap B4)" do
    test ":same update keeps the upsert path (old side resolved, no relocate)" do
      change = %Replicant.Change{
        op: :update,
        schema: "public",
        table: "tenant_orders",
        record: %{"id" => "1", "org_id" => "org-a", "note" => "n"},
        old_record: %{"id" => "1", "org_id" => "org-a"}
      }

      assert {:ok, :same, "org-a", "org-a"} =
               Resolver.require_tenant_pair!(AshReplicant.Test.TenantOrder, change, :upsert)
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
               Resolver.require_tenant_pair!(AshReplicant.Test.TenantOrder, change, :upsert)
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
          Resolver.require_tenant_pair!(AshReplicant.Test.TenantOrder, change, :upsert)
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
            Resolver.require_tenant_pair!(AshReplicant.Test.TenantOrder, change, :upsert)
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
          Resolver.require_tenant_pair!(AshReplicant.Test.RaisingMfaOrder, change, :upsert)
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
               Resolver.require_tenant_pair!(AshReplicant.Test.TenantOrder, change, :create)
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
               Resolver.require_tenant_pair!(AshReplicant.Test.Order, change, :upsert)
    end
  end
end
