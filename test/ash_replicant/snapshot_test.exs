defmodule AshReplicant.SnapshotTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Sink.Impl
  alias AshReplicant.Test.{Order, Secret, Vault}

  defmodule Sink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snap_slot"
  end

  setup do
    {:ok, index} = AshReplicant.Resolver.build_index([AshReplicant.Test.Domain])
    :persistent_term.put({AshReplicant, "snap_slot"}, index)
    on_exit(fn -> :persistent_term.erase({AshReplicant, "snap_slot"}) end)
    :ok
  end

  defp snap(id),
    do: %Replicant.Change{
      op: :snapshot,
      schema: "public",
      table: "orders",
      record: %{"id" => id, "note" => "s"}
    }

  defp ctx(first?), do: %{snapshot_lsn: 500, table: "public.orders", first_for_table?: first?}

  test "first_for_table? clears stale mirror rows before applying (redo-safety)" do
    Ash.create!(Order, %{id: "ghost", note: "old"}, action: :create, authorize?: false)
    assert :ok = Sink.handle_snapshot([snap("1"), snap("2")], ctx(true))
    assert Ash.get!(Order, "ghost", authorize?: false, error?: false) == nil
    assert %Order{} = Ash.get!(Order, "1", authorize?: false)
  end

  test "a snapshot batch with a failing row RAISES (stop_on_error), never silently swallows" do
    bad = %Replicant.Change{
      op: :snapshot,
      schema: "public",
      table: "orders",
      record: %{"note" => "no-id"}
    }

    assert {:error, %AshReplicant.Error{}} = Sink.handle_snapshot([snap("1"), bad], ctx(true))
  end

  test "handle_snapshot_complete durably sets the checkpoint to snapshot_lsn" do
    assert {:ok, 500} = Sink.handle_snapshot_complete(500)
    assert {:ok, 500} = Sink.checkpoint()
  end

  # An empty resolver index must fail closed on BOTH snapshot entry points, exactly
  # as handle_transaction does — otherwise a degenerate/misloaded index would drop
  # the whole backfill AND advance the checkpoint past it (permanent invisible loss).
  test "an empty resolver index fails closed on snapshot AND snapshot_complete (:config_invalid), checkpoint not advanced" do
    empty = %{
      repo: TestRepo,
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snap_slot",
      resolver_index: %{},
      authorize?: false
    }

    assert {:error, %AshReplicant.Error{reason: :config_invalid}} =
             Impl.handle_snapshot(empty, [snap("1")], ctx(true))

    assert {:error, %AshReplicant.Error{reason: :config_invalid}} =
             Impl.handle_snapshot_complete(empty, 500)

    # loss=0: the checkpoint was NOT advanced.
    assert {:ok, nil} = Impl.checkpoint(empty)
  end

  # Spec §Telemetry: the two snapshot events are emitted with their spec'd
  # measurements/metadata (previously never emitted). :batch carries change_count +
  # table + commit_lsn (= snapshot_lsn); :complete carries commit_lsn. All value-free.
  test "snapshot telemetry: :batch and :complete fire with spec'd measurements/metadata" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:ash_replicant, :snapshot, :batch],
        [:ash_replicant, :snapshot, :complete]
      ])

    assert :ok = Sink.handle_snapshot([snap("1"), snap("2")], ctx(true))

    assert_received {[:ash_replicant, :snapshot, :batch], ^ref, m1, meta1}
    assert m1.change_count == 2
    assert meta1.table == "orders"
    assert meta1.commit_lsn == 500

    assert {:ok, 500} = Sink.handle_snapshot_complete(500)

    assert_received {[:ash_replicant, :snapshot, :complete], ^ref, _m2, meta2}
    assert meta2.commit_lsn == 500

    :telemetry.detach(ref)
  end

  test "a sensitive-resource snapshot routes per-record so AshCloak encrypts (no plaintext)" do
    start_supervised!(Vault)

    sctx = %{snapshot_lsn: 600, table: "public.secret_orders", first_for_table?: true}

    change = %Replicant.Change{
      op: :snapshot,
      schema: "public",
      table: "secret_orders",
      record: %{"id" => "sec1", "pan" => "4111111111111111"}
    }

    assert :ok = Sink.handle_snapshot([change], sctx)

    # raw ciphertext is stored, NOT the plaintext PAN
    %Postgrex.Result{rows: [[enc]]} =
      TestRepo.query!("SELECT encrypted_pan FROM secret_orders WHERE id = $1", ["sec1"])

    refute is_nil(enc)
    assert is_binary(enc)
    refute enc == "4111111111111111"

    # and it decrypts back to the plaintext (AshCloak fired)
    assert Secret |> Ash.get!("sec1", load: [:pan], authorize?: false) |> Map.get(:pan) ==
             "4111111111111111"
  end

  test "a non-global multitenant snapshot clears across tenants and applies each row under its own tenant (redo-safe)" do
    alias AshReplicant.Test.TenantOrder
    # stale ghost in org_1 that upstream no longer has
    Ash.create!(TenantOrder, %{id: "ghost", org_id: "org_1", note: "old"},
      action: :create,
      tenant: "org_1",
      authorize?: false
    )

    changes = [
      %Replicant.Change{
        op: :snapshot,
        schema: "public",
        table: "tenant_orders",
        record: %{"id" => "t1", "org_id" => "org_1", "note" => "s"}
      },
      %Replicant.Change{
        op: :snapshot,
        schema: "public",
        table: "tenant_orders",
        record: %{"id" => "t2", "org_id" => "org_2", "note" => "s"}
      }
    ]

    tctx = %{snapshot_lsn: 700, table: "public.tenant_orders", first_for_table?: true}

    assert :ok = Sink.handle_snapshot(changes, tctx)

    assert Ash.get!(TenantOrder, "ghost", tenant: "org_1", authorize?: false, error?: false) ==
             nil

    assert %TenantOrder{} = Ash.get!(TenantOrder, "t1", tenant: "org_1", authorize?: false)
    assert %TenantOrder{} = Ash.get!(TenantOrder, "t2", tenant: "org_2", authorize?: false)
  end

  @tag :integration
  test "snapshot seeds one open version per row for an SCD2 resource" do
    config = %{
      resolver_index: %{{"public", "orders"} => AshReplicant.Test.OrderVersion},
      repo: AshReplicant.TestRepo,
      authorize?: false,
      slot_name: "scd2_snap",
      checkpoint_resource: AshReplicant.Test.Checkpoint
    }

    # Real snapshot changes carry commit_lsn: nil — the LSN lives in ctx.snapshot_lsn.
    # Building them with nil (the PRODUCTION shape) is what makes this test observe the
    # threading, instead of fabricating a commit_lsn that masks the bug.
    changes = [
      %Replicant.Change{
        op: :insert,
        schema: "public",
        table: "orders",
        record: %{"order_id" => "s1", "amount" => "1"},
        commit_lsn: nil
      },
      %Replicant.Change{
        op: :insert,
        schema: "public",
        table: "orders",
        record: %{"order_id" => "s2", "amount" => "2"},
        commit_lsn: nil
      }
    ]

    assert :ok =
             AshReplicant.Sink.Impl.handle_snapshot(config, changes, %{
               table: "public.orders",
               first_for_table?: true,
               snapshot_lsn: 10
             })

    rows = Ash.read!(AshReplicant.Test.OrderVersion, authorize?: false)
    assert length(rows) == 2

    assert Enum.all?(
             rows,
             &(&1.is_current and is_nil(&1.valid_to_lsn) and &1.valid_from_lsn == 10)
           )
  end
end
