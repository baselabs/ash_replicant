defmodule AshReplicant.Test.CheckpointBinding.ContractOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.CheckpointBinding.ContractADomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "checkpoint_binding_contract_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("contract_orders")
    skip([:audit_note, :external_code])
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.CheckpointBinding.ContractExtra do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.CheckpointBinding.ContractBDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "checkpoint_binding_contract_extras"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("contract_extras")
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true
    attribute :extra_col, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.CheckpointBinding.ContractADomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.CheckpointBinding.ContractOrder
  end
end

defmodule AshReplicant.Test.CheckpointBinding.ContractBDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.CheckpointBinding.ContractOrder
    resource AshReplicant.Test.CheckpointBinding.ContractExtra
  end
end

defmodule AshReplicant.CheckpointBindingTest do
  @moduledoc """
  Roadmap B2 acceptance marquees: the actual replication-session identity binds
  the checkpoint row durably, timeline/liveness/contract guards halt fail-closed,
  and compatible contract transitions replace manifest/fingerprint without
  touching the watermark. Observed through durable row state and telemetry only.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Test.{AdmittedGeneration, Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "bind_slot"
  @fresh_slot "bind_fresh_slot"
  @bind_publication "repl_bind_pub"

  defmodule SinkA do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.CheckpointBinding.ContractADomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "bind_slot",
      ignored_sources: ["public.contract_extras"]
  end

  defmodule SinkB do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.CheckpointBinding.ContractBDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "bind_slot"
  end

  defmodule FreshSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "bind_fresh_slot"
  end

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()

    # The binding sinks map contract_orders/contract_extras — create them and
    # a DEDICATED publication so the B3 activation preflight's rule 2 passes
    # (plan-review F2). FreshSink keeps the marquee publication, whose only
    # table it maps.
    Marquee.q!("DROP PUBLICATION IF EXISTS #{@bind_publication}")
    Marquee.q!("DROP TABLE IF EXISTS contract_orders")
    Marquee.q!("DROP TABLE IF EXISTS contract_extras")

    Marquee.q!(
      "CREATE TABLE contract_orders (id text primary key, note text, external_code text, audit_note text)"
    )

    Marquee.q!("CREATE TABLE contract_extras (id text primary key, note text, extra_col text)")

    Marquee.q!(
      "CREATE PUBLICATION #{@bind_publication} FOR TABLE contract_orders, contract_extras"
    )

    on_exit(fn ->
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@bind_publication}")
      Marquee.q!("DROP TABLE IF EXISTS contract_orders")
      Marquee.q!("DROP TABLE IF EXISTS contract_extras")
    end)

    for slot <- [@slot, @fresh_slot] do
      Marquee.drop_slot!(slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
    end

    on_exit(fn ->
      for slot <- [@slot, @fresh_slot] do
        AshReplicant.stop_supervised(slot)
        Marquee.drop_slot!(slot)
        Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
      end

      Marquee.teardown_schema!()
    end)

    :ok
  end

  test "fresh bind: the actual session identity, timeline, and contract durably bind the row" do
    ref = attach_events()

    assert {:ok, _pid} = start(FreshSink, @fresh_slot)

    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    identity = Marquee.source_identity()
    timeline = live_timeline()

    row = bound_row(@fresh_slot)

    assert row.source_system_id == identity[:system_identifier]
    assert row.source_database == identity[:database]
    assert row.source_timeline == timeline
    assert row.commit_lsn == nil

    {:ok, contract} =
      Identity.build_contract(FreshSink.__ash_replicant_config__(), [Marquee.publication()])

    assert row.publication_fingerprint == contract.fingerprint
    assert Identity.decode(row.publication_contract) == {:ok, contract.manifest}

    # First streamed transaction sets the watermark on the SAME row.
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('bind-1', 'bound')")

    assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :applied], %{commit_lsn: lsn}},
                   15_000

    PG.wait_until(fn ->
      bound_row(@fresh_slot).commit_lsn == lsn
    end)
  end

  test "sibling halt: a foreign-identity row under the same slot halts :source_identity_rebound, value-free" do
    ref = attach_events()
    identity = Marquee.source_identity()

    # A DIFFERENT source's row already owns the slot name.
    plant_row(%{
      source_system_id: "sentinel-foreign-system",
      source_database: identity[:database],
      slot_name: @slot,
      commit_lsn: 5
    })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _pid} = start(SinkA, @slot)

        assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                        %{reason: :source_identity_rebound}},
                       15_000

        assert_receive {:telemetry, ^ref, [:replicant, :connection, :session_identity_rejected],
                        %{}},
                       15_000
      end)

    refute log =~ "sentinel-foreign-system"

    # The foreign row is untouched — no foreign watermark was continued or erased.
    row = bound_row(@slot)
    assert row.source_system_id == "sentinel-foreign-system"
    assert row.commit_lsn == 5
  end

  test "timeline halt: a stored timeline that differs from the session halts :source_timeline_changed" do
    ref = attach_events()
    identity = Marquee.source_identity()

    plant_row(%{
      source_system_id: identity[:system_identifier],
      source_database: identity[:database],
      slot_name: @slot,
      source_timeline: 99,
      commit_lsn: nil
    })

    assert {:ok, _pid} = start(SinkA, @slot)

    assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                    %{reason: :source_timeline_changed}},
                   15_000

    assert bound_row(@slot).source_timeline == 99
  end

  test "liveness halt: a watermark beyond the session's flush position halts :source_behind_watermark" do
    ref = attach_events()
    identity = Marquee.source_identity()

    planted_watermark = flush_lsn() + 1_000_000_000

    plant_row(%{
      source_system_id: identity[:system_identifier],
      source_database: identity[:database],
      slot_name: @slot,
      source_timeline: live_timeline(),
      commit_lsn: planted_watermark
    })

    assert {:ok, _pid} = start(SinkA, @slot)

    assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                    %{reason: :source_behind_watermark}},
                   15_000

    assert bound_row(@slot).commit_lsn == planted_watermark
  end

  test "compatible transition: an added relation replaces the contract atomically, LSN byte-identical" do
    ref = attach_events()

    # Phase 1: bind under contract A on a live slot, then advance the watermark
    # to the slot's confirmed flush (durable state a real deployment would have).
    assert {:ok, _pid} = start(SinkA, @slot)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    assert :ok = AshReplicant.stop_supervised(@slot)

    watermark = confirmed_flush(@slot)

    Marquee.q!("UPDATE ash_replicant_checkpoints SET commit_lsn = $1 WHERE slot_name = $2", [
      watermark,
      @slot
    ])

    # Phase 2: SinkB's contract ADDS a relation — set-monotone growth, compatible.
    assert {:ok, _pid} = start(SinkB, @slot)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    row = bound_row(@slot)
    contract_b = contract_for(SinkB)
    assert row.publication_fingerprint == contract_b.fingerprint
    assert Identity.decode(row.publication_contract) == {:ok, contract_b.manifest}
    assert row.commit_lsn == watermark
  end

  test "incompatible transition: a removed relation halts :publication_contract_incompatible, row untouched" do
    identity = Marquee.source_identity()

    contract_b = contract_for(SinkB)

    plant_row(%{
      source_system_id: identity[:system_identifier],
      source_database: identity[:database],
      slot_name: @slot,
      source_timeline: live_timeline(),
      commit_lsn: 12_345,
      publication_contract: contract_b.encoded,
      publication_fingerprint: contract_b.fingerprint
    })

    ref = attach_events()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # SinkA's contract REMOVES a relation — a recorded entry's removal halts.
        assert {:ok, _pid} = start(SinkA, @slot)

        assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                        %{reason: :publication_contract_incompatible}},
                       15_000
      end)

    refute log =~ "contract_extras"

    row = bound_row(@slot)
    assert row.publication_fingerprint == contract_b.fingerprint
    assert row.commit_lsn == 12_345
  end

  test "steady-state reconnect: an unchanged contract and timeline write NOTHING" do
    ref = attach_events()

    assert {:ok, _pid} = start(SinkA, @slot)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    assert :ok = AshReplicant.stop_supervised(@slot)

    watermark = confirmed_flush(@slot)

    Marquee.q!("UPDATE ash_replicant_checkpoints SET commit_lsn = $1 WHERE slot_name = $2", [
      watermark,
      @slot
    ])

    before = bound_row(@slot)

    assert {:ok, _pid} = start(SinkA, @slot)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    after_start = bound_row(@slot)
    assert after_start.publication_fingerprint == before.publication_fingerprint
    assert after_start.updated_at == before.updated_at
    assert after_start.commit_lsn == watermark
  end

  describe "locked monotonic admission (task 4)" do
    setup do
      ref = attach_events()

      # Bind on a live slot, stop, then pin the watermark at the slot's flush —
      # the durable state a real deployment holds.
      assert {:ok, _pid} = start(SinkA, @slot)
      assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
      assert :ok = AshReplicant.stop_supervised(@slot)

      watermark = confirmed_flush(@slot)

      Marquee.q!("UPDATE ash_replicant_checkpoints SET commit_lsn = $1 WHERE slot_name = $2", [
        watermark,
        @slot
      ])

      # The direct-drive marquees below call the sink outside a live pipeline:
      # re-seed the admitted generation stop_supervised erased.
      identity = Marquee.source_identity()

      AdmittedGeneration.put!(SinkA,
        source_identity: %{
          system_identifier: identity[:system_identifier],
          database: identity[:database]
        },
        publication: [Marquee.publication()]
      )

      on_exit(fn -> :persistent_term.erase({AshReplicant, "bind_slot"}) end)

      %{ref: ref, watermark: watermark}
    end

    test "equal and lower LSN re-delivery skip; only strictly-greater advances", %{
      ref: ref,
      watermark: watermark
    } do
      # Equal LSN: skipped, watermark unchanged.
      assert {:ok, ^watermark} = txn(SinkA, watermark)

      assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :skipped],
                      %{commit_lsn: ^watermark}},
                     1_000

      assert bound_row(@slot).commit_lsn == watermark

      # Lower LSN: skipped (returns the delivered LSN), watermark unchanged
      # (no regression, no reapply).
      assert {:ok, lower} = txn(SinkA, watermark - 10_000)
      assert lower == watermark - 10_000
      assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :skipped], _}, 1_000
      assert bound_row(@slot).commit_lsn == watermark

      # Strictly greater: applied, watermark advances exactly once.
      assert {:ok, advanced} = txn(SinkA, watermark + 10_000)
      assert advanced == watermark + 10_000
      assert bound_row(@slot).commit_lsn == watermark + 10_000
    end

    test "snapshot handoff below the watermark never regresses it", %{watermark: watermark} do
      # The skip returns the REQUESTED consistent point (the framework acks its
      # own point, never the sink's return) — and writes NOTHING.
      assert {:ok, ^watermark} = SinkA.handle_snapshot_complete(watermark)
      assert bound_row(@slot).commit_lsn == watermark

      below = watermark - 5_000
      assert {:ok, ^below} = SinkA.handle_snapshot_complete(below)
      assert bound_row(@slot).commit_lsn == watermark

      # Above advances.
      assert {:ok, higher} = SinkA.handle_snapshot_complete(watermark + 5_000)
      assert higher == watermark + 5_000
      assert bound_row(@slot).commit_lsn == watermark + 5_000
    end

    test "an absent row is a permanent :checkpoint_unbound halt (never frontier-0)", %{
      ref: ref,
      watermark: watermark
    } do
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

      assert {:error, %AshReplicant.Error{reason: :checkpoint_unbound}} =
               txn(SinkA, watermark + 10)

      assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                      %{reason: :checkpoint_unbound}},
                     1_000

      assert {:error, %AshReplicant.Error{reason: :checkpoint_unbound}} =
               SinkA.handle_snapshot_complete(watermark + 10)

      # No row was silently recreated at frontier-0.
      assert bound_row(@slot) == :absent
    end

    test "concurrent admission serializes on the row lock (outside-sandbox two-connection shape)",
         %{ref: ref, watermark: watermark} do
      # The public two-process path cannot prove this (the per-slot activation
      # lease and the shared sandbox serialize ahead of the row lock), so the
      # marquee holds the lock on a SEPARATE real connection and proves the
      # admission BLOCKS at the locked read until release — then dedups.
      {:ok, conn} =
        Postgrex.start_link(
          hostname: "127.0.0.1",
          port: 5599,
          username: "postgres",
          database: "ash_replicant_test",
          sync_connect: true
        )

      identity = Marquee.source_identity()

      {:ok, _} = Postgrex.query(conn, "BEGIN", [])

      {:ok, _} =
        Postgrex.query(
          conn,
          "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE source_system_id = $1 AND source_database = $2 AND slot_name = $3 FOR UPDATE",
          [identity[:system_identifier], identity[:database], @slot]
        )

      task =
        Task.async(fn ->
          txn(SinkA, watermark + 20_000)
        end)

      refute_receive {:telemetry, ^ref, [:ash_replicant, :sink, :applied], _}, 500
      refute_receive {:telemetry, ^ref, [:ash_replicant, :sink, :skipped], _}, 500
      assert bound_row(@slot).commit_lsn == watermark

      {:ok, _} = Postgrex.query(conn, "COMMIT", [])

      assert {:ok, advanced} = Task.await(task, 15_000)
      assert advanced == watermark + 20_000

      assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :applied],
                      %{commit_lsn: ^advanced}},
                     1_000

      # A second admission at the same LSN dedups against the committed one.
      assert {:ok, ^advanced} = txn(SinkA, advanced)

      assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :skipped],
                      %{commit_lsn: ^advanced}},
                     1_000

      assert bound_row(@slot).commit_lsn == advanced
    end

    test "two racing same-LSN admissions produce exactly one applied and one skipped",
         %{ref: ref, watermark: watermark} do
      # The lock-only discriminator. The PUBLIC callback path cannot prove the
      # row lock on one node (the per-slot activation lease serializes ahead
      # of it — by design), so this races two DIRECT Impl admissions with the
      # seeded runtime config: lease-escaping writers are exactly the class
      # the row lock is the durable serializer for. With the lock, the loser
      # re-reads the advanced watermark under the lock and skips; WITHOUT the
      # lock both read the stale watermark and both report :applied (the
      # skipped-assert goes red).
      race_lsn = watermark + 30_000
      config = seeded_runtime_config(SinkA)

      change = %Replicant.Transaction{
        commit_lsn: race_lsn,
        commit_timestamp: DateTime.utc_now(),
        changes: []
      }

      tasks =
        for _i <- 1..2,
            do: Task.async(fn -> AshReplicant.Sink.Impl.handle_transaction(config, change) end)

      results = Enum.map(tasks, &Task.await(&1, 15_000))

      assert Enum.all?(results, &match?({:ok, ^race_lsn}, &1))

      assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :applied],
                      %{commit_lsn: ^race_lsn}},
                     1_000

      assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :skipped],
                      %{commit_lsn: ^race_lsn}},
                     1_000

      assert bound_row(@slot).commit_lsn == race_lsn
    end
  end

  # The runtime config the seeded generation would thread through run_callback,
  # WITHOUT the activation lease — the lease-escaping writer shape.
  defp seeded_runtime_config(sink) do
    config = sink.__ash_replicant_config__()

    generation =
      :persistent_term.get({AshReplicant, config.slot_name})
      |> case do
        %AshReplicant.Destination.Generation{} = gen -> gen
      end

    Map.merge(config, %{
      sink: sink,
      resolver_index: generation.resolver_index,
      destination_manifest: generation.manifest,
      source_contract: generation.source_contract,
      coverage: generation.coverage,
      source_identity: generation.source_identity,
      publication: generation.publication,
      generation: generation.reference,
      dynamic_repo: generation.dynamic_repo,
      data_layer_context: %{repo: generation.dynamic_repo},
      authorize?: false
    })
  end

  defp txn(sink, lsn) do
    sink.handle_transaction(%Replicant.Transaction{
      commit_lsn: lsn,
      commit_timestamp: DateTime.utc_now(),
      changes: []
    })
  end

  describe "operator adoption + timeline acknowledge (task 5)" do
    setup do
      ref = attach_events()

      # A live slot with a bound row, then stopped — the state an operator
      # migrates/adopts against.
      assert {:ok, _pid} = start(SinkA, @slot)
      assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
      assert :ok = AshReplicant.stop_supervised(@slot)

      %{ref: ref}
    end

    test "adopt preserves the watermark; the first bind initializes the contract without touching it",
         %{ref: ref} do
      identity = Marquee.source_identity()

      # Simulate the legacy capture/delete/migrate step: drop the bound row,
      # then adopt it back with the preserved watermark.
      watermark = confirmed_flush(@slot)

      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

      assert :ok = AshReplicant.adopt_checkpoint(SinkA, identity, watermark)

      row = bound_row(@slot)
      assert row.commit_lsn == watermark
      assert row.publication_contract == nil
      assert row.publication_fingerprint == nil

      # Adopting the identical row again is idempotent; a DIFFERENT watermark
      # (or a nil one over a durable row) is a mismatched re-adoption —
      # refused, the durable watermark untouched.
      assert :ok = AshReplicant.adopt_checkpoint(SinkA, identity, watermark)

      assert {:error, %AshReplicant.Error{reason: :checkpoint_adopt_conflict}} =
               AshReplicant.adopt_checkpoint(SinkA, identity, watermark + 7)

      assert {:error, %AshReplicant.Error{reason: :checkpoint_adopt_conflict}} =
               AshReplicant.adopt_checkpoint(SinkA, identity, nil)

      assert bound_row(@slot).commit_lsn == watermark

      # A different identity cannot own the slot name.
      assert {:error, %AshReplicant.Error{reason: :checkpoint_adopt_conflict}} =
               AshReplicant.adopt_checkpoint(
                 SinkA,
                 [system_identifier: "sentinel-other-system", database: identity[:database]],
                 watermark
               )

      # The first connect fills the contract (:initialized) and the timeline,
      # keeping the adopted watermark.
      assert {:ok, _pid} = start(SinkA, @slot)
      assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

      row = bound_row(@slot)
      contract = contract_for(SinkA)

      assert row.publication_fingerprint == contract.fingerprint
      assert row.source_timeline == live_timeline()
      assert row.commit_lsn == watermark
    end

    test "acknowledge re-binds a changed timeline without touching watermark or contract" do
      identity = Marquee.source_identity()
      contract = contract_for(SinkA)

      # Advance the watermark (the value the acknowledge must not touch), then
      # plant a foreign/future timeline that halts the bind.
      watermark = confirmed_flush(@slot)

      Marquee.q!("UPDATE ash_replicant_checkpoints SET commit_lsn = $1 WHERE slot_name = $2", [
        watermark,
        @slot
      ])

      Marquee.q!(
        "UPDATE ash_replicant_checkpoints SET source_timeline = 99 WHERE slot_name = $1",
        [@slot]
      )

      # ...and the operator's continuity assertion re-binds it.
      assert :ok = AshReplicant.acknowledge_checkpoint_timeline(SinkA, identity, 99)

      row = bound_row(@slot)
      assert row.source_timeline == 99
      assert row.publication_fingerprint == contract.fingerprint
      assert row.commit_lsn == watermark

      # Idempotent at the same timeline.
      assert :ok = AshReplicant.acknowledge_checkpoint_timeline(SinkA, identity, 99)

      # A row with NO recorded timeline (adopted, never bound) has nothing to
      # acknowledge — refuse with the start-the-pipeline guidance.
      Marquee.q!(
        "UPDATE ash_replicant_checkpoints SET source_timeline = NULL WHERE slot_name = $1",
        [@slot]
      )

      assert {:error, %AshReplicant.Error{reason: :checkpoint_adopt_invalid}} =
               AshReplicant.acknowledge_checkpoint_timeline(SinkA, identity, 99)
    end

    test "reset destroys the bound row idempotently" do
      identity = Marquee.source_identity()

      assert :ok = AshReplicant.reset_checkpoint(SinkA, identity)
      assert bound_row(@slot) == :absent

      # Idempotent when absent; a different identity's row is untouched (none here).
      assert :ok = AshReplicant.reset_checkpoint(SinkA, identity)
    end
  end

  describe "legacy refusal guard (task 5)" do
    test "a migrated table reports zero ambiguous legacy rows" do
      assert {:ok, 0} = Identity.legacy_checkpoint_row_count(AshReplicant.TestRepo)
      assert :ok = Identity.refuse_ambiguous_legacy_rows!(AshReplicant.TestRepo)
    end

    test "a slot-only table with rows raises a count-only structural error" do
      # Throwaway legacy shape under the guard's table parameter.
      Marquee.q!(
        "CREATE TABLE b2_legacy_checkpoints (slot_name text primary key, commit_lsn bigint not null)"
      )

      Marquee.q!("INSERT INTO b2_legacy_checkpoints VALUES ('legacy-1', 42), ('legacy-2', 43)")
      on_exit(fn -> Marquee.q!("DROP TABLE IF EXISTS b2_legacy_checkpoints") end)

      assert {:ok, 2} =
               Identity.legacy_checkpoint_row_count(
                 AshReplicant.TestRepo,
                 "b2_legacy_checkpoints"
               )

      error =
        assert_raise AshReplicant.Error, fn ->
          Identity.refuse_ambiguous_legacy_rows!(AshReplicant.TestRepo, "b2_legacy_checkpoints")
        end

      # Count-only, value-free: no slot names or watermarks.
      assert error.reason == :checkpoint_legacy_rows_present
      assert error.shape == "rows=2 options=capture_and_delete_then_adopt|reset"
      refute Exception.message(error) =~ "legacy-1"
    end
  end

  # --- helpers ---

  defp start(sink, _slot) do
    publication =
      case sink do
        FreshSink -> Marquee.publication()
        _sink -> [@bind_publication]
      end

    AshReplicant.start_link(
      sink: sink,
      connection: Marquee.conn(),
      publication: publication,
      source_identity: Marquee.source_identity(),
      go_forward_only: true
    )
    |> case do
      {:ok, pid} -> {:ok, pid}
      other -> other
    end
  end

  defp attach_events do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:ash_replicant, :checkpoint, :conflict],
        [:ash_replicant, :sink, :applied],
        [:ash_replicant, :sink, :skipped],
        [:replicant, :connection, :session_identity_rejected],
        [:replicant, :connection, :slot_active]
      ],
      fn event, measurements, meta, _c ->
        send(test_pid, {:telemetry, ref, event, Map.merge(measurements, meta)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp contract_for(sink) do
    publication =
      case sink do
        FreshSink -> Marquee.publication()
        _sink -> [@bind_publication]
      end

    {:ok, contract} = Identity.build_contract(sink.__ash_replicant_config__(), publication)

    contract
  end

  defp plant_row(values) do
    columns = Map.keys(values)
    placeholders = Enum.map(1..length(columns), &"$#{&1}")

    Marquee.q!(
      "INSERT INTO ash_replicant_checkpoints (" <>
        Enum.map_join(columns, ", ", &to_string/1) <>
        ", inserted_at, updated_at) VALUES (" <>
        Enum.join(placeholders, ", ") <> ", now(), now()) ON CONFLICT DO NOTHING",
      Enum.map(columns, &Map.get(values, &1))
    )
  end

  defp bound_row(slot) do
    case Marquee.q!(
           "SELECT count(*) FROM ash_replicant_checkpoints WHERE slot_name = $1",
           [slot]
         ).rows do
      [[0]] -> :absent
      [[1]] -> do_bound_row(slot)
    end
  end

  defp do_bound_row(slot) do
    [[sys, db, slot, timeline, lsn, contract, fingerprint, _inserted, updated]] =
      Marquee.q!(
        "SELECT source_system_id, source_database, slot_name, source_timeline, commit_lsn, " <>
          "publication_contract, publication_fingerprint, inserted_at, updated_at " <>
          "FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [slot]
      ).rows

    %{
      source_system_id: sys,
      source_database: db,
      slot_name: slot,
      source_timeline: timeline,
      commit_lsn: lsn,
      publication_contract: contract,
      publication_fingerprint: fingerprint,
      updated_at: updated
    }
  end

  defp live_timeline do
    [[timeline]] = Marquee.q!("SELECT timeline_id FROM pg_control_checkpoint()").rows
    timeline
  end

  defp confirmed_flush(slot) do
    [[lsn]] =
      Marquee.q!(
        "SELECT confirmed_flush_lsn::text FROM pg_replication_slots WHERE slot_name = $1",
        [
          slot
        ]
      ).rows

    parse_lsn(lsn)
  end

  defp flush_lsn do
    [[lsn]] = Marquee.q!("SELECT pg_current_wal_flush_lsn()::text").rows
    parse_lsn(lsn)
  end

  defp parse_lsn(lsn) do
    [file, offset] = String.split(lsn, "/", parts: 2)
    String.to_integer(file, 16) * 4_294_967_296 + String.to_integer(offset, 16)
  end
end
