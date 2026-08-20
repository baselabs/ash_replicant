defmodule AshReplicant.SnapshotV1RetryTest do
  @moduledoc """
  The whole-table V1 snapshot retry protocol (S02, ADR-0017).

  Every assertion here counts PHYSICAL writes through the append-only observer
  (`AshReplicant.Test.SnapshotEffects`), never final state — because final-state
  convergence is exactly what ADR-0017 rejects as proof. A host create, destroy,
  or SCD2 close can carry an append-only local effect even when a later upsert
  converges to the same row, so "the row looks right afterwards" says nothing
  about whether the business action ran twice.
  """
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Sink.Impl
  alias AshReplicant.Snapshot.{Provenance, State}
  alias AshReplicant.Test.{AdmittedGeneration, SnapOrder, SnapshotEffects, SnapTenantOrder}

  @slot "snap_v1_slot"
  @lsn 5_000

  defmodule Sink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.SnapshotDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "snap_v1_slot"
  end

  setup do
    generation = activate!()

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

  # A fresh activation = a fresh PipelineOwner = a fresh delivery run. This is
  # the "operator-authorized retry under a later owner" of ADR-0017.
  defp activate!, do: AdmittedGeneration.put!(Sink)

  defp order(id, note),
    do: %Replicant.Change{
      op: :snapshot,
      schema: "public",
      table: "snap_orders",
      record: %{"id" => id, "note" => note}
    }

  defp tenant_order(id, org, note),
    do: %Replicant.Change{
      op: :snapshot,
      schema: "public",
      table: "snap_tenant_orders",
      record: %{"id" => id, "org_id" => org, "note" => note}
    }

  defp ctx(table, first?, lsn \\ @lsn),
    do: %{snapshot_lsn: lsn, table: "public.#{table}", first_for_table?: first?}

  defp durable_state do
    keys = elem(Provenance.keys(), 1)

    %{snapshot_state: encoded} =
      Ash.get!(
        AshReplicant.Test.Checkpoint,
        %{
          source_system_id: "test-system",
          source_database: "test-database",
          slot_name: @slot
        },
        authorize?: false
      )

    State.decode(encoded, keys)
  end

  # One complete V1 run: every chunk, then the fenced completion.
  defp run_snapshot!(batches, lsn \\ @lsn) do
    batches
    |> Enum.with_index()
    |> Enum.each(fn {{table, changes}, index} ->
      assert :ok = Sink.handle_snapshot(changes, ctx(table, index == 0, lsn))
    end)

    Sink.handle_snapshot_complete(lsn)
  end

  describe "the whole-resource first-chunk clear is ABSENT" do
    test "a pre-existing destination row survives the first chunk untouched" do
      Ash.create!(SnapOrder, %{id: "ghost", note: "old"}, action: :create, authorize?: false)
      SnapshotEffects.reset!()

      assert :ok = Sink.handle_snapshot([order("1", "a")], ctx("snap_orders", true))

      # The row is still there — the chunk deleted nothing. It is RETIRED at
      # fenced completion instead, through the host action, per tenant scope.
      assert %SnapOrder{note: "old"} = Ash.get!(SnapOrder, "ghost", authorize?: false)
      assert SnapshotEffects.business_ops("ghost") == []
    end

    test "no DELETE is issued during any chunk, first or later" do
      Ash.create!(SnapOrder, %{id: "ghost", note: "old"}, action: :create, authorize?: false)
      SnapshotEffects.reset!()

      assert :ok = Sink.handle_snapshot([order("1", "a")], ctx("snap_orders", true))
      assert :ok = Sink.handle_snapshot([order("2", "b")], ctx("snap_orders", false))

      refute Enum.any?(SnapshotEffects.all(), &(&1.op == "DELETE"))
    end
  end

  describe "attempt binding to the owner's delivery run" do
    test "the first chunk of a run binds ONE attempt; later chunks reuse it" do
      assert :ok = Sink.handle_snapshot([order("1", "a")], ctx("snap_orders", true))
      assert {:ok, first} = durable_state()

      assert first.mode == :v1
      assert first.status == :active
      assert byte_size(first.attempt) == State.id_bytes()
      assert is_nil(first.completed_lsn)

      assert :ok = Sink.handle_snapshot([order("2", "b")], ctx("snap_orders", false))
      assert {:ok, second} = durable_state()

      assert second.attempt == first.attempt
      assert second.delivery_run == first.delivery_run
    end

    test "a NEW owner rotates the attempt even at the SAME consistent point" do
      assert :ok = Sink.handle_snapshot([order("1", "a")], ctx("snap_orders", true))
      assert {:ok, before} = durable_state()

      # The pipeline dies and an operator authorizes a re-export. PostgreSQL
      # hands back the SAME snapshot_lsn — nothing in the consistent point tells
      # the two attempts apart, so only the per-activation delivery run can.
      generation = activate!()
      refute generation.delivery_run == before.delivery_run

      assert :ok = Sink.handle_snapshot([order("1", "a")], ctx("snap_orders", true, @lsn))
      assert {:ok, rotated} = durable_state()

      refute rotated.attempt == before.attempt
      assert rotated.delivery_run == generation.delivery_run
    end

    test "the attempt binds the admitted contract and refuses to resume under drift" do
      assert :ok = Sink.handle_snapshot([order("1", "a")], ctx("snap_orders", true))
      assert {:ok, bound} = durable_state()

      config = AshReplicant.runtime_config(:persistent_term.get({AshReplicant, @slot}))
      assert {:ok, digest} = State.contract_digest(config)
      assert bound.contract_digest == digest

      # Rewrite the durable envelope so it names a DIFFERENT admitted contract
      # (what a manifest, config, or bytecode change would produce), keeping the
      # same delivery run so only the contract is at issue.
      write_state!(%{bound | contract_digest: :crypto.strong_rand_bytes(32)})

      assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
               Sink.handle_snapshot([order("2", "b")], ctx("snap_orders", false))
    end

    test "a TAMPERED envelope fails closed rather than arming a fresh attempt" do
      assert :ok = Sink.handle_snapshot([order("1", "a")], ctx("snap_orders", true))

      %{snapshot_state: encoded} = checkpoint_row()
      offset = byte_size(State.magic()) + 6
      <<head::binary-size(^offset), byte::8, tail::binary>> = encoded
      write_raw_state!(<<head::binary, Bitwise.bxor(byte, 0xFF)::8, tail::binary>>)

      assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
               Sink.handle_snapshot([order("2", "b")], ctx("snap_orders", false))
    end
  end

  describe "unchanged rows do not repeat host business effects" do
    test "a full re-run under a new owner writes ZERO business effects" do
      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a"), order("2", "b")]}])

      assert Enum.sort(SnapshotEffects.business_ops("1")) == ["INSERT"]
      assert Enum.sort(SnapshotEffects.business_ops("2")) == ["INSERT"]

      SnapshotEffects.reset!()
      activate!()

      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a"), order("2", "b")]}])

      # Bookkeeping only: the rows were re-marked into the new attempt, and no
      # host create ran a second time.
      assert SnapshotEffects.business() == []
      assert length(SnapshotEffects.bookkeeping()) == 2
    end

    test "a CHANGED row goes through the host business action exactly once" do
      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a"), order("2", "b")]}])

      SnapshotEffects.reset!()
      activate!()

      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "CHANGED"), order("2", "b")]}])

      assert SnapshotEffects.business_ops("1") == ["UPDATE"]
      assert SnapshotEffects.business_ops("2") == []
    end

    test "a MISSING row is retired at completion, through the host retire action" do
      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a"), order("2", "b")]}])

      SnapshotEffects.reset!()
      activate!()

      # Row 2 is gone upstream: this attempt never marks it, so completion
      # retires it — and only it.
      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a")]}])

      assert SnapshotEffects.business_ops("2") == ["DELETE"]
      assert SnapshotEffects.business_ops("1") == []
      assert Ash.get!(SnapOrder, "2", authorize?: false, error?: false) == nil
      assert %SnapOrder{} = Ash.get!(SnapOrder, "1", authorize?: false)
    end

    test "a row that was never marked by ANY attempt is retired, not silently kept" do
      # NULL marker: `marker != attempt` is NULL in SQL and would exclude the
      # row from the retirement match unless the predicate says `or is_nil(...)`.
      Ash.create!(SnapOrder, %{id: "ghost", note: "old"}, action: :create, authorize?: false)
      SnapshotEffects.reset!()

      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a")]}])

      assert SnapshotEffects.business_ops("ghost") == ["DELETE"]
    end
  end

  describe "provenance key rotation and key loss" do
    test "a key rotation re-stamps unchanged rows under the ACTIVE version, repeating nothing" do
      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a")]}])

      SnapshotEffects.reset!()

      # v2 becomes active; v1 is RETAINED, so the row minted under v1 still
      # verifies and must NOT be reported as changed.
      AshReplicant.Test.Provenance.put_provenance_keys!([
        {1, "test-snapshot-provenance-key-v1"},
        {2, "test-snapshot-provenance-key-v2-rotated"}
      ])

      activate!()
      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a")]}])

      assert SnapshotEffects.business() == []

      # The re-stamp lands under the ACTIVE version, so v1 can eventually be
      # dropped without every row looking changed.
      row = Ash.get!(SnapOrder, "1", authorize?: false)
      assert row.replica_fingerprint =~ ~r/^e\dv2:/
    end

    test "a fingerprint whose answer is UNKNOWN halts instead of re-running the host action" do
      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a")]}])

      SnapshotEffects.reset!()

      # The row's stored fingerprint names a key version that is not in the
      # configured set — an operator dropped a retained key while rows still
      # named it. The comparison cannot produce an answer, and an unknown answer
      # must NEVER degrade to `:changed`: that would re-run the host business
      # action for every affected row, repeating any append-only effect.
      TestRepo.query!(
        "UPDATE snap_orders SET replica_fingerprint = $1 WHERE id = $2",
        ["e1v9:" <> String.duplicate("ab", 32), "1"]
      )

      activate!()

      assert {:error, %AshReplicant.Error{reason: :snapshot_provenance_unavailable}} =
               Sink.handle_snapshot([order("1", "a")], ctx("snap_orders", true))

      assert SnapshotEffects.business() == []
    end
  end

  describe "crash injection at every batch boundary" do
    test "each source row carries exactly ONE host business effect across all retries" do
      rows = for n <- 1..6, do: order("r#{n}", "v#{n}")
      batches = Enum.chunk_every(rows, 2)

      # Crash after 0, 1, 2 and 3 committed batches, each time re-exporting the
      # whole snapshot under a fresh owner at the SAME consistent point.
      for committed <- 0..length(batches) do
        activate!()

        batches
        |> Enum.take(committed)
        |> Enum.with_index()
        |> Enum.each(fn {batch, index} ->
          assert :ok = Sink.handle_snapshot(batch, ctx("snap_orders", index == 0))
        end)
      end

      activate!()
      assert {:ok, _} = run_snapshot!([{"snap_orders", rows}])

      for n <- 1..6 do
        assert SnapshotEffects.business_ops("r#{n}") == ["INSERT"],
               "row r#{n} repeated a committed host business effect"
      end
    end
  end

  describe "completion, the replay fence, and tenant scope" do
    test "completion records the delivery run and LSN, and redelivery is a no-op BEFORE scanning" do
      assert {:ok, @lsn} = run_snapshot!([{"snap_orders", [order("1", "a")]}])
      assert {:ok, completed} = durable_state()

      assert completed.status == :complete
      assert completed.completed_lsn == @lsn

      # The reply was lost, a LATER stream write landed (it carries no marker
      # from the completed attempt), and completion is redelivered. The fence
      # must return before any row scan, so the newer row survives.
      Ash.create!(SnapOrder, %{id: "later", note: "streamed"},
        action: :create,
        authorize?: false
      )

      SnapshotEffects.reset!()

      assert {:ok, @lsn} = Sink.handle_snapshot_complete(@lsn)

      assert %SnapOrder{} = Ash.get!(SnapOrder, "later", authorize?: false)
      assert SnapshotEffects.all() == []
    end

    test "completion enumerates a destination tenant the source attempt never mentioned" do
      # org_2 exists only in the DESTINATION. A completion that enumerated only
      # the tenants the source produced would leave its stale row open forever.
      Ash.create!(SnapTenantOrder, %{id: "t9", org_id: "org_2", note: "stale"},
        action: :create,
        tenant: "org_2",
        authorize?: false
      )

      SnapshotEffects.reset!()

      assert {:ok, _} =
               run_snapshot!([
                 {"snap_tenant_orders", [tenant_order("t1", "org_1", "a")]}
               ])

      assert SnapshotEffects.business_ops("t9") == ["DELETE"]

      assert %SnapTenantOrder{} =
               Ash.get!(SnapTenantOrder, "t1", tenant: "org_1", authorize?: false)
    end

    test "retirement never touches a resource outside the sink's declared scope" do
      # `AshReplicant.Test.Order` is mapped by a DIFFERENT sink's domain; this
      # sink's resolver index does not contain it.
      Ash.create!(AshReplicant.Test.Order, %{id: "outside", note: "keep"},
        action: :create,
        authorize?: false
      )

      assert {:ok, _} = run_snapshot!([{"snap_orders", [order("1", "a")]}])

      assert %AshReplicant.Test.Order{note: "keep"} =
               Ash.get!(AshReplicant.Test.Order, "outside", authorize?: false)
    end

    test "a completion with no matching in-flight attempt fails closed" do
      assert {:error, %AshReplicant.Error{reason: :snapshot_state_invalid}} =
               Sink.handle_snapshot_complete(@lsn)
    end
  end

  # --- durable-state helpers (these write the column DIRECTLY, which is what
  # a tamper or an operator mistake looks like from the sink's side) ---

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

  defp write_state!(%State{} = state) do
    {:ok, keys} = Provenance.keys()
    {:ok, encoded} = State.encode(state, keys)
    write_raw_state!(encoded)
  end

  defp write_raw_state!(encoded) do
    TestRepo.query!(
      "UPDATE ash_replicant_checkpoints SET snapshot_state = $1 WHERE slot_name = $2",
      [encoded, @slot]
    )

    :ok
  end
end
