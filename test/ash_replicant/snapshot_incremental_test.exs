defmodule AshReplicant.SnapshotIncrementalTest do
  @moduledoc """
  The sink-owned incremental snapshot protocol (S03, ADR-0017).

  These tests drive the callbacks Replicant 1.2.2 actually emits: progress is
  armed before reader/stream start, chunks carry their exact opaque token, and
  completion is an empty at-least-once `handle_snapshot/2` callback.
  """
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Sink.Impl
  alias AshReplicant.Snapshot.{Provenance, State}

  alias AshReplicant.Test.{
    AdmittedGeneration,
    SnapOrder,
    SnapshotEffects,
    SnapTenantOrder,
    SnapVersion
  }

  @slot "snap_incremental_slot"
  @floor_lsn 5_000

  defmodule Sink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.SnapshotDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snap_incremental_slot"
  end

  setup do
    generation = activate!()

    assert :ok =
             Sink.handle_session_identity(
               %Replicant.SessionIdentity{
                 system_identifier: generation.source_identity.system_identifier,
                 timeline_id: 1,
                 current_lsn: 0,
                 database: generation.source_identity.database
               },
               %{slot_name: @slot, publication: generation.publication}
             )

    SnapshotEffects.reset!()

    on_exit(fn ->
      :persistent_term.erase({AshReplicant, @slot})
      Impl.clear_snapshot_ordinals(@slot)
    end)

    :ok
  end

  defp activate!(opts \\ []), do: AdmittedGeneration.put!(Sink, opts)

  defp order(id, note) do
    %Replicant.Change{
      op: :snapshot,
      schema: "public",
      table: "snap_orders",
      record: %{"id" => id, "note" => note}
    }
  end

  defp stream_order(id, note, lsn) do
    %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "snap_orders",
      record: %{"id" => id, "note" => note},
      commit_lsn: lsn,
      ordinal: 0
    }
  end

  defp stream_update(old_id, new_id, note, lsn) do
    %Replicant.Change{
      op: :update,
      schema: "public",
      table: "snap_orders",
      old_record: %{"id" => old_id, "note" => "before"},
      record: %{"id" => new_id, "note" => note},
      commit_lsn: lsn,
      ordinal: 0
    }
  end

  defp stream_delete(id, note, lsn) do
    %Replicant.Change{
      op: :delete,
      schema: "public",
      table: "snap_orders",
      old_record: %{"id" => id, "note" => note},
      record: nil,
      commit_lsn: lsn,
      ordinal: 0
    }
  end

  defp tenant_snapshot(id, org, note) do
    %Replicant.Change{
      op: :snapshot,
      schema: "public",
      table: "snap_tenant_orders",
      record: %{"id" => id, "org_id" => org, "note" => note}
    }
  end

  defp tenant_reassignment(id, old_org, new_org, lsn) do
    %Replicant.Change{
      op: :update,
      schema: "public",
      table: "snap_tenant_orders",
      old_record: %{"id" => id, "org_id" => old_org, "note" => "before"},
      record: %{"id" => id, "org_id" => new_org, "note" => "after"},
      commit_lsn: lsn,
      ordinal: 0
    }
  end

  defp version_change(op, order_id, amount, lsn) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: "snap_versions",
      old_record: if(op == :update, do: %{"order_id" => order_id, "amount" => "before"}),
      record: %{"order_id" => order_id, "amount" => amount},
      commit_lsn: lsn,
      ordinal: 0
    }
  end

  defp transaction(lsn, changes) do
    %Replicant.Transaction{
      commit_lsn: lsn,
      commit_timestamp: DateTime.utc_now(),
      changes: changes,
      messages: []
    }
  end

  defp chunk_ctx(progress, overrides \\ %{}) do
    Map.merge(
      %{
        snapshot_lsn: @floor_lsn,
        table: "public.snap_orders",
        first_for_table?: false,
        backfill_complete?: false,
        progress: progress
      },
      overrides
    )
  end

  defp complete_ctx(progress) do
    chunk_ctx(progress, %{
      table: "__backfill_complete__",
      backfill_complete?: true
    })
  end

  defp checkpoint_row do
    Ash.get!(
      AshReplicant.Test.Checkpoint,
      %{
        source_system_id: "test-system",
        source_database: "test-database",
        slot_name: @slot
      },
      authorize?: false
    )
  end

  defp durable_state do
    {:ok, keys} = Provenance.keys()
    %{snapshot_state: encoded} = checkpoint_row()
    State.decode(encoded, keys)
  end

  defp write_checkpoint!(fields) do
    row = checkpoint_row()

    Ash.create!(
      AshReplicant.Test.Checkpoint,
      row
      |> Map.take([:source_system_id, :source_database, :slot_name])
      |> Map.merge(fields),
      action: :upsert,
      upsert?: true,
      upsert_identity: :source_slot,
      upsert_fields: Map.keys(fields),
      authorize?: false
    )
  end

  test "progress callback durably arms one attempt and owner restart reuses it" do
    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert {:ok, armed} = durable_state()
    assert armed.mode == :incremental
    assert armed.status == :armed

    activate!()

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert {:ok, resumed} = durable_state()
    assert resumed.attempt == armed.attempt
  end

  test "a committed stream checkpoint with no snapshot state remains stream-only" do
    write_checkpoint!(%{
      commit_lsn: @floor_lsn,
      snapshot_progress: nil,
      snapshot_state: nil
    })

    assert {:ok, nil} = Sink.snapshot_progress()
    assert checkpoint_row().snapshot_state == nil
  end

  test "chunk effects, marker, ordinal cursor, and exact progress commit atomically" do
    progress = <<131, 104, 2, 100, 0, 8, "progress", 97, 1>>
    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert :ok = Sink.handle_snapshot([order("1", "a")], chunk_ctx(progress))

    row = checkpoint_row()
    assert row.snapshot_progress == progress
    assert {:ok, state} = durable_state()
    assert state.status == :active
    assert state.next_ordinal == 1

    mirrored = Ash.get!(SnapOrder, "1", authorize?: false)
    assert mirrored.replica_seen_attempt == state.attempt
    assert SnapshotEffects.business_ops("1") == ["INSERT"]
  end

  test "partial progress and the operation-key cursor survive an owner restart" do
    first_progress = "opaque-progress-first"
    second_progress = "opaque-progress-second"

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert :ok = Sink.handle_snapshot([order("1", "a")], chunk_ctx(first_progress))
    assert {:ok, first_state} = durable_state()

    activate!()

    assert {:ok, ^first_progress} = Sink.snapshot_progress()
    assert :ok = Sink.handle_snapshot([order("2", "b")], chunk_ctx(second_progress))
    assert {:ok, second_state} = durable_state()

    assert second_state.attempt == first_state.attempt
    assert first_state.next_ordinal == 1
    assert second_state.next_ordinal == 2
  end

  test "a valid replacement progress token cannot skip an authenticated in-flight position" do
    progress = "opaque-progress-authenticated"
    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert :ok = Sink.handle_snapshot([order("1", "a")], chunk_ctx(progress))

    replacement = "opaque-progress-valid-but-foreign"
    write_checkpoint!(%{snapshot_progress: replacement})
    activate!()

    assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
             Sink.snapshot_progress()
  end

  test "a failed chunk rolls back row effects, cursor, and progress together" do
    progress = "opaque-progress-rollback"
    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    invalid = order(nil, "invalid")

    assert {:error, %AshReplicant.Error{}} =
             Sink.handle_snapshot([order("1", "a"), invalid], chunk_ctx(progress))

    assert Ash.get!(SnapOrder, "1", authorize?: false, error?: false) == nil
    assert checkpoint_row().snapshot_progress == nil
    assert {:ok, state} = durable_state()
    assert state.status == :armed
    assert state.next_ordinal == 0
  end

  test "stream before the first chunk stamps membership and completion preserves it" do
    complete = "opaque-complete-token"
    stream_lsn = @floor_lsn + 100

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert {:ok, ^stream_lsn} =
             Sink.handle_transaction(
               transaction(stream_lsn, [stream_order("s", "stream", stream_lsn)])
             )

    assert {:ok, active} = durable_state()
    assert active.status == :active
    assert Ash.get!(SnapOrder, "s", authorize?: false).replica_seen_attempt == active.attempt
    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))
    assert %SnapOrder{} = Ash.get!(SnapOrder, "s", authorize?: false)

    row = checkpoint_row()
    assert row.commit_lsn == stream_lsn
    assert row.snapshot_progress == complete
    assert {:ok, completed} = durable_state()
    assert completed.status == :complete
    assert completed.progress_token_hash == :crypto.hash(:sha256, complete)
    assert completed.completed_token_hash == :crypto.hash(:sha256, complete)
    assert {:ok, ^complete} = Sink.snapshot_progress()
  end

  test "stream update, key change, and delete preserve current-read ordering" do
    progress = "opaque-progress-collisions"
    complete = "opaque-complete-collisions"

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert :ok =
             Sink.handle_snapshot(
               [order("move", "before"), order("delete", "before")],
               chunk_ctx(progress)
             )

    update_lsn = @floor_lsn + 10
    delete_lsn = @floor_lsn + 20

    assert {:ok, ^update_lsn} =
             Sink.handle_transaction(
               transaction(update_lsn, [
                 stream_update("move", "moved", "after", update_lsn)
               ])
             )

    assert {:ok, ^delete_lsn} =
             Sink.handle_transaction(
               transaction(delete_lsn, [stream_delete("delete", "before", delete_lsn)])
             )

    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))

    assert Ash.get!(SnapOrder, "move", authorize?: false, error?: false) == nil
    assert %SnapOrder{note: "after"} = Ash.get!(SnapOrder, "moved", authorize?: false)
    assert Ash.get!(SnapOrder, "delete", authorize?: false, error?: false) == nil
  end

  test "sink-owned transaction batches stamp the armed attempt before one trailing watermark" do
    first_lsn = @floor_lsn + 10
    second_lsn = @floor_lsn + 20

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert {:ok, ^second_lsn} =
             Sink.handle_batch([
               transaction(first_lsn, [stream_order("b1", "one", first_lsn)]),
               transaction(second_lsn, [stream_order("b2", "two", second_lsn)])
             ])

    assert {:ok, active} = durable_state()
    assert active.status == :active
    assert checkpoint_row().commit_lsn == second_lsn

    for id <- ["b1", "b2"] do
      assert Ash.get!(SnapOrder, id, authorize?: false).replica_seen_attempt == active.attempt
    end
  end

  test "tenant reassignment stamps only the new scope and completion never crosses tenants" do
    progress = "opaque-progress-tenant"
    complete = "opaque-complete-tenant"
    stream_lsn = @floor_lsn + 50

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert :ok =
             Sink.handle_snapshot(
               [tenant_snapshot("tenant-row", "org-a", "before")],
               chunk_ctx(progress, %{table: "public.snap_tenant_orders"})
             )

    assert {:ok, ^stream_lsn} =
             Sink.handle_transaction(
               transaction(stream_lsn, [
                 tenant_reassignment("tenant-row", "org-a", "org-b", stream_lsn)
               ])
             )

    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))

    assert Ash.get!(SnapTenantOrder, "tenant-row",
             tenant: "org-a",
             authorize?: false,
             error?: false
           ) == nil

    assert %SnapTenantOrder{org_id: "org-b"} =
             Ash.get!(SnapTenantOrder, "tenant-row", tenant: "org-b", authorize?: false)
  end

  test "SCD2 stream update marks the new open version and leaves closed history immutable" do
    progress = "opaque-progress-scd2"
    complete = "opaque-complete-scd2"
    stream_lsn = @floor_lsn + 60

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert :ok =
             Sink.handle_snapshot(
               [version_change(:snapshot, "scd2", "before", @floor_lsn)],
               chunk_ctx(progress, %{table: "public.snap_versions"})
             )

    assert {:ok, ^stream_lsn} =
             Sink.handle_transaction(
               transaction(stream_lsn, [version_change(:update, "scd2", "after", stream_lsn)])
             )

    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))

    versions =
      SnapVersion
      |> Ash.Query.sort(valid_from_lsn: :asc)
      |> Ash.read!(authorize?: false)

    assert [closed, open] = versions
    assert closed.amount == "before"
    assert closed.valid_to_lsn == stream_lsn
    assert open.amount == "after"
    assert open.valid_to_lsn == nil
    assert is_binary(open.replica_seen_attempt)
  end

  test "SCD2 stream insert before its snapshot window coalesces with the current version" do
    progress = "opaque-progress-scd2-pre-window"
    complete = "opaque-complete-scd2-pre-window"
    stream_lsn = @floor_lsn + 70

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert {:ok, ^stream_lsn} =
             Sink.handle_transaction(
               transaction(stream_lsn, [
                 version_change(:insert, "pre-window", "current", stream_lsn)
               ])
             )

    assert :ok =
             Sink.handle_snapshot(
               [version_change(:snapshot, "pre-window", "current", @floor_lsn)],
               chunk_ctx(progress, %{table: "public.snap_versions"})
             )

    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))

    versions = Ash.read!(SnapVersion, authorize?: false)

    assert [%SnapVersion{valid_from_lsn: ^stream_lsn, valid_to_lsn: nil} = open] = versions
    assert is_binary(open.replica_seen_attempt)
  end

  test "SCD2 snapshot mismatch cannot open below a newer streamed version" do
    progress = "opaque-progress-scd2-newer-mismatch"
    stream_lsn = @floor_lsn + 80

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert {:ok, ^stream_lsn} =
             Sink.handle_transaction(
               transaction(stream_lsn, [
                 version_change(:insert, "newer-mismatch", "current", stream_lsn)
               ])
             )

    assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
             Sink.handle_snapshot(
               [version_change(:snapshot, "newer-mismatch", "stale", @floor_lsn)],
               chunk_ctx(progress, %{table: "public.snap_versions"})
             )

    versions = Ash.read!(SnapVersion, authorize?: false)

    assert [%SnapVersion{valid_from_lsn: ^stream_lsn, valid_to_lsn: nil, amount: "current"}] =
             versions

    assert %{snapshot_progress: nil} = checkpoint_row()
  end

  test "SCD2 snapshot rejects an invalid negative current-version LSN" do
    assert %SnapVersion{} =
             Ash.create!(
               SnapVersion,
               %{
                 order_id: "negative-lsn",
                 amount: "invalid-current",
                 valid_from_lsn: -1,
                 valid_to_lsn: nil,
                 is_current: true
               },
               authorize?: false
             )

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
             Sink.handle_snapshot(
               [version_change(:snapshot, "negative-lsn", "snapshot", @floor_lsn)],
               chunk_ctx("opaque-progress-scd2-negative", %{table: "public.snap_versions"})
             )

    assert [%SnapVersion{valid_from_lsn: -1, amount: "invalid-current", valid_to_lsn: nil}] =
             Ash.read!(SnapVersion, authorize?: false)
  end

  test "matching completion redelivery no-ops before scan after a later stream write" do
    complete = "opaque-complete-redelivery"
    later_lsn = @floor_lsn + 200

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))

    assert {:ok, ^later_lsn} =
             Sink.handle_transaction(
               transaction(later_lsn, [stream_order("later", "stream", later_lsn)])
             )

    SnapshotEffects.reset!()

    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))
    assert %SnapOrder{} = Ash.get!(SnapOrder, "later", authorize?: false)
    assert SnapshotEffects.all() == []
  end

  test "a completed fence survives admitted contract drift and streaming continues" do
    complete = "opaque-complete-before-contract-drift"
    later_lsn = @floor_lsn + 300

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))

    activate!(publication: ["test_publication", "after_deploy"])

    assert {:ok, ^complete} = Sink.snapshot_progress()
    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))

    assert {:ok, ^later_lsn} =
             Sink.handle_transaction(
               transaction(later_lsn, [stream_order("after-drift", "stream", later_lsn)])
             )

    assert %SnapOrder{} = Ash.get!(SnapOrder, "after-drift", authorize?: false)
  end

  test "a different completion token cannot reuse the permanent replay fence" do
    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert :ok = Sink.handle_snapshot([], complete_ctx("complete-a"))

    assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
             Sink.handle_snapshot([], complete_ctx("complete-b"))
  end

  test "progress without its state and a tampered state both fail closed" do
    write_checkpoint!(%{snapshot_progress: "orphan-progress"})

    assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
             Sink.snapshot_progress()

    write_checkpoint!(%{snapshot_progress: nil})
    assert {:ok, :backfill_pending} = Sink.snapshot_progress()

    %{snapshot_state: encoded} = checkpoint_row()
    offset = byte_size(State.magic()) + 6
    <<head::binary-size(^offset), byte::8, tail::binary>> = encoded

    write_checkpoint!(%{
      snapshot_state: <<head::binary, Bitwise.bxor(byte, 0xFF)::8, tail::binary>>
    })

    assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
             Sink.snapshot_progress()
  end

  test "a resumed attempt rekeys state and rows before the retained key is removed" do
    progress = "opaque-progress-key-rotation"
    complete = "opaque-complete-key-rotation"

    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert {:ok, initial} = durable_state()
    assert initial.key_version == 1

    AshReplicant.Test.Provenance.put_provenance_keys!([
      {1, "test-snapshot-provenance-key-v1"},
      {2, "test-snapshot-provenance-key-v2-rotated"}
    ])

    activate!()
    assert {:ok, :backfill_pending} = Sink.snapshot_progress()
    assert :ok = Sink.handle_snapshot([order("rotate", "a")], chunk_ctx(progress))
    assert :ok = Sink.handle_snapshot([], complete_ctx(complete))

    assert {:ok, completed} = durable_state()
    assert completed.key_version == 2
    assert Ash.get!(SnapOrder, "rotate", authorize?: false).replica_fingerprint =~ ~r/^e\dv2:/

    AshReplicant.Test.Provenance.put_provenance_keys!([
      {2, "test-snapshot-provenance-key-v2-rotated"}
    ])

    activate!()
    assert {:ok, ^complete} = Sink.snapshot_progress()
  end
end
