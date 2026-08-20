defmodule AshReplicant.SnapshotTenantScopeTest do
  @moduledoc """
  Completion-time scope enumeration and SCD2 retirement (S02, ADR-0017).

  Two properties that fail SILENTLY when they fail:

    * retirement that misses a destination tenant scope leaves that tenant's
      stale rows open forever, and nothing observes it; and
    * SCD2 retirement that matches a CLOSED version rewrites immutable history,
      which no final-state assertion on the open version would notice.
  """
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Sink.Impl

  alias AshReplicant.Test.{
    AdmittedGeneration,
    SnapCtxOrder,
    SnapCtxTenants,
    SnapshotEffects,
    SnapTenantOrder,
    SnapVersion
  }

  @slot "snap_scope_slot"
  @ctx_slot "snap_ctx_slot"
  @lsn 7_000

  defmodule Sink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.SnapshotDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snap_scope_slot"
  end

  defmodule CtxSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.SnapshotContextDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snap_ctx_slot"
  end

  setup do
    bind!(Sink, @slot)
    bind!(CtxSink, @ctx_slot)
    SnapshotEffects.reset!()
    SnapCtxTenants.clear_override()

    on_exit(fn ->
      SnapCtxTenants.clear_override()
      :persistent_term.erase({AshReplicant, @slot})
      :persistent_term.erase({AshReplicant, @ctx_slot})
      Impl.clear_snapshot_ordinals(@slot)
      Impl.clear_snapshot_ordinals(@ctx_slot)
    end)

    :ok
  end

  defp bind!(sink, slot) do
    generation = AdmittedGeneration.put!(sink)

    sink.handle_session_identity(
      %Replicant.SessionIdentity{
        system_identifier: generation.source_identity.system_identifier,
        timeline_id: 1,
        current_lsn: 0,
        database: generation.source_identity.database
      },
      %{slot_name: slot, publication: generation.publication}
    )

    generation
  end

  defp ctx(table, first?),
    do: %{snapshot_lsn: @lsn, table: "public.#{table}", first_for_table?: first?}

  describe "SCD2 retirement" do
    defp version(id, amount),
      do: %Replicant.Change{
        op: :snapshot,
        schema: "public",
        table: "snap_versions",
        record: %{"order_id" => id, "amount" => amount}
      }

    test "an unchanged version is marked without a close/open pair" do
      assert :ok = Sink.handle_snapshot([version("v1", "10")], ctx("snap_versions", true))
      assert {:ok, _} = Sink.handle_snapshot_complete(@lsn)

      SnapshotEffects.reset!()
      AdmittedGeneration.put!(Sink)

      assert :ok = Sink.handle_snapshot([version("v1", "10")], ctx("snap_versions", true))
      assert {:ok, _} = Sink.handle_snapshot_complete(@lsn)

      # No new version opened, no close written: bookkeeping only.
      assert SnapshotEffects.business() == []
      assert length(Ash.read!(SnapVersion, authorize?: false)) == 1
    end

    test "retirement closes only the OPEN version and never rewrites closed history" do
      assert :ok = Sink.handle_snapshot([version("v1", "10")], ctx("snap_versions", true))
      assert {:ok, _} = Sink.handle_snapshot_complete(@lsn)

      # A second run at a LATER point changes the row, closing v1's first
      # version and opening a second. The closed one is now immutable history.
      AdmittedGeneration.put!(Sink)
      later = %{snapshot_lsn: @lsn + 100, table: "public.snap_versions", first_for_table?: true}
      assert :ok = Sink.handle_snapshot([version("v1", "20")], later)
      assert {:ok, _} = Sink.handle_snapshot_complete(@lsn + 100)

      closed_before = closed_versions()
      assert length(closed_before) == 1

      # A third run where the row has VANISHED upstream: completion must close
      # the open version and leave the already-closed one byte-identical.
      SnapshotEffects.reset!()
      AdmittedGeneration.put!(Sink)
      final = %{snapshot_lsn: @lsn + 200, table: "public.snap_versions", first_for_table?: true}
      assert :ok = Sink.handle_snapshot([], final)
      assert {:ok, _} = Sink.handle_snapshot_complete(@lsn + 200)

      assert closed_versions() |> Enum.filter(&(&1.valid_to_lsn == @lsn + 100)) == closed_before

      # Every open version is now closed, and nothing is left current.
      assert Enum.all?(Ash.read!(SnapVersion, authorize?: false), &(not &1.is_current))
    end

    defp closed_versions do
      SnapVersion
      |> Ash.read!(authorize?: false)
      |> Enum.reject(&is_nil(&1.valid_to_lsn))
      |> Enum.sort_by(& &1.valid_from_lsn)
    end
  end

  describe "attribute-multitenancy scope enumeration" do
    defp tenant_order(id, org),
      do: %Replicant.Change{
        op: :snapshot,
        schema: "public",
        table: "snap_tenant_orders",
        record: %{"id" => id, "org_id" => org, "note" => "n"}
      }

    test "every distinct discriminator value is swept, including one absent from the source" do
      for org <- ["org_a", "org_b", "org_c"] do
        Ash.create!(SnapTenantOrder, %{id: "stale_#{org}", org_id: org, note: "old"},
          action: :create,
          tenant: org,
          authorize?: false
        )
      end

      SnapshotEffects.reset!()

      assert :ok =
               Sink.handle_snapshot(
                 [tenant_order("keep", "org_a")],
                 ctx("snap_tenant_orders", true)
               )

      assert {:ok, _} = Sink.handle_snapshot_complete(@lsn)

      for org <- ["org_a", "org_b", "org_c"] do
        assert SnapshotEffects.business_ops("stale_#{org}") == ["DELETE"],
               "tenant #{org} was not enumerated"
      end

      assert %SnapTenantOrder{} =
               Ash.get!(SnapTenantOrder, "keep", tenant: "org_a", authorize?: false)
    end

    test "a scope enumeration carrying a blank tenant fails closed" do
      # A blank discriminator is the fail-open shape Ash treats as NO tenant: a
      # retirement pass under it would run TENANT-BLIND over every tenant's rows.
      TestRepo.query!(
        "INSERT INTO snap_tenant_orders (id, org_id, note) VALUES ($1, $2, $3)",
        ["blank", "  ", "old"]
      )

      assert :ok =
               Sink.handle_snapshot(
                 [tenant_order("keep", "org_a")],
                 ctx("snap_tenant_orders", true)
               )

      assert {:error, %AshReplicant.Error{reason: :snapshot_scope_incomplete}} =
               Sink.handle_snapshot_complete(@lsn)

      # Fail-closed means nothing was retired, not "most of it was".
      assert Enum.empty?(Enum.filter(SnapshotEffects.all(), &(&1.op == "DELETE")))
    end
  end

  describe "context-multitenancy scope enumeration" do
    defp ctx_order(id, schema),
      do: %Replicant.Change{
        op: :snapshot,
        schema: "public",
        table: "snap_ctx_orders",
        record: %{"id" => id, "org_schema" => schema, "note" => "n"}
      }

    test "context multitenancy retires through every declared scope" do
      # ctx_org_b holds a stale row and appears in NO source change: only the
      # declared enumerator can reveal it.
      TestRepo.query!(
        "INSERT INTO ctx_org_b.snap_ctx_orders (id, note) VALUES ($1, $2)",
        ["stale_b", "old"]
      )

      SnapshotEffects.reset!()

      assert :ok =
               CtxSink.handle_snapshot(
                 [ctx_order("a1", "ctx_org_a")],
                 ctx("snap_ctx_orders", true)
               )

      assert {:ok, _} = CtxSink.handle_snapshot_complete(@lsn)

      assert SnapshotEffects.business_ops("stale_b") == ["DELETE"]

      assert %SnapCtxOrder{} =
               Ash.get!(SnapCtxOrder, "a1", tenant: "ctx_org_a", authorize?: false)
    end

    test "an enumerator that RAISES fails completion closed" do
      SnapCtxTenants.put_override({:raise, "registry unavailable"})

      assert :ok =
               CtxSink.handle_snapshot(
                 [ctx_order("a1", "ctx_org_a")],
                 ctx("snap_ctx_orders", true)
               )

      assert {:error, %AshReplicant.Error{reason: :snapshot_scope_incomplete}} =
               CtxSink.handle_snapshot_complete(@lsn)
    end

    test "an enumerator returning a malformed scope fails completion closed" do
      SnapCtxTenants.put_override(["ctx_org_a", nil])

      assert :ok =
               CtxSink.handle_snapshot(
                 [ctx_order("a1", "ctx_org_a")],
                 ctx("snap_ctx_orders", true)
               )

      assert {:error, %AshReplicant.Error{reason: :snapshot_scope_incomplete}} =
               CtxSink.handle_snapshot_complete(@lsn)
    end
  end
end
