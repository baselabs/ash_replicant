defmodule AshReplicant.EffectOnceTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.{DestinationObserver, Marquee}
  alias AshReplicant.Test.PG
  alias Ecto.Adapters.SQL.Sandbox

  @slot "marquee_slot"

  setup do
    # The pipeline's Connection/AssemblerServer run in their OWN processes and do
    # real `config.repo` writes; logical replication also needs COMMITTED source
    # rows. Neither works under the suite's :manual Sandbox (no owner for those
    # processes, and sandbox writes never commit). Run this module against real
    # committing pooled connections (:auto), restoring :manual afterward. This
    # on_exit is registered FIRST so it runs LAST (LIFO): the cleanup queries below
    # still execute while mode is :auto.
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()
    run_id = "scd1-#{System.unique_integer([:positive])}"
    DestinationObserver.setup!(run_id, observer_triggers())
    assert DestinationObserver.unconstrained?()
    start_supervised!({Marquee.EscapeRepo, Marquee.escape_repo_config()})
    :persistent_term.put(Marquee.escape_key(), false)
    :persistent_term.put(Marquee.observer_key(), self())

    # `drop_slot!` retries while the walsender still holds the slot: Postgres
    # releases a replication slot ASYNCHRONOUSLY after the client socket closes, so
    # a drop immediately after a stop can raise 55006 (object_in_use).
    Marquee.drop_slot!(@slot)

    # The slot and its durable checkpoint are a PAIR: replicant fail-closes with
    # `:data_gap` when the slot is absent but a checkpoint > 0 exists (potential
    # silent loss). `ash_replicant_checkpoints` is committed OUTSIDE the sandbox and
    # keyed by slot_name, so a prior run's row survives the slot drop. Clear it here
    # to reset to a genuine first run. Only at setup/teardown — NEVER mid-test, so
    # the crash-resume slot+checkpoint stay consistent for dedup.
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    # MANDATE A: mirror the defensive tmp_block drop into setup too — a hard kill
    # during the atomic test's fault window (constraint added, not yet dropped)
    # would otherwise leave it lingering and poison every checkpoint upsert next run.
    Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT IF EXISTS tmp_block")

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)

      Marquee.drop_slot!(@slot)

      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

      # MANDATE A: the atomic-rollback test adds a CHECK constraint to the SHARED
      # ash_replicant_checkpoints table. Drop it defensively here so a mid-test
      # crash can never poison every subsequent checkpoint upsert (idempotent).
      Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT IF EXISTS tmp_block")
      DestinationObserver.teardown!(observer_triggers())
      :persistent_term.erase(Marquee.escape_key())
      :persistent_term.erase(Marquee.observer_key())
    end)

    {:ok, run_id: run_id}
  end

  # `Replicant.start_link` returns once the pipeline is supervised, but the
  # replication connection creates/resumes the slot asynchronously. Inserting
  # before the slot is streaming would place the row's WAL BEFORE the slot's
  # start point, and `go_forward_only: true` would skip it (silent loss). Block on
  # the `:slot_active` event (fires on both fresh `:create_slot` AND stream-resume)
  # so the INSERT is always captured — the readiness pattern replicant's own
  # integration marquee uses.
  defp start! do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _meta, _cfg -> send(test_pid, {:slot_active, ref}) end,
      nil
    )

    {:ok, _pid} =
      AshReplicant.start_link(
        sink: Marquee.Sink,
        connection: Marquee.conn(),
        slot_name: @slot,
        publication: Marquee.publication(),
        source_identity: Marquee.source_identity(),
        go_forward_only: true
      )

    receive do
      {:slot_active, ^ref} -> :ok
    after
      15_000 -> flunk("pipeline never reached slot_active for #{@slot}")
    end

    :telemetry.detach({__MODULE__, ref})
  end

  test "activation preflight fails structurally when the authoritative store is absent" do
    assert {:ok, manifest} =
             AshReplicant.Destination.manifest(Marquee.Sink.__ash_replicant_config__())

    assert :ok =
             AshReplicant.Destination.preflight_onetime(manifest, AshReplicant.TestRepo)

    assert {:ok, :checked} =
             AshReplicant.TestRepo.transaction(fn ->
               Marquee.q!("SET LOCAL search_path TO pg_temp")

               assert {:error, {:invalid_destination_config, :onetime_store}} =
                        AshReplicant.Destination.preflight_onetime(
                          manifest,
                          AshReplicant.TestRepo
                        )

               :checked
             end)
  end

  test "end-to-end: mapped, auxiliary, and checkpoint effects share one transaction", %{
    run_id: run_id
  } do
    start!()
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('1', 'a')")
    PG.wait_until(fn -> Marquee.mirror_rows() == [["1", "a"]] end)

    # 6 stream-transaction effects + 1 bind-write checkpoint row (B2: the bind
    # transaction creates the bound row at connect).
    PG.wait_until(fn -> length(DestinationObserver.rows(run_id)) == 7 end)
    assert_effect_counts(run_id, 1, 1, 2)
    assert_onetime_effect_counts(run_id, 1, 1, 1)
    assert_atomic_observer_groups(run_id)
  end

  test "two same-action changes at one commit LSN use distinct ordinal-bound claims", %{
    run_id: run_id
  } do
    start!()
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('1', 'a'), ('2', 'b')")
    PG.wait_until(fn -> Marquee.mirror_rows() == [["1", "a"], ["2", "b"]] end)

    PG.wait_until(fn ->
      DestinationObserver.effect_count(run_id, "onetime_claim", "INSERT") == 2
    end)

    assert_effect_counts(run_id, 2, 2, 2)
    assert_onetime_effect_counts(run_id, 2, 2, 2)
    assert_atomic_observer_groups(run_id)
  end

  test "crash-and-resume: killing the pipeline mid-stream loses nothing and duplicates nothing",
       %{run_id: run_id} do
    start!()
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('1', 'a')")
    PG.wait_until(fn -> Marquee.mirror_rows() == [["1", "a"]] end)

    :ok = AshReplicant.stop_supervised(@slot)
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('2', 'b'), ('3', 'c')")

    start!()
    PG.wait_until(fn -> length(Marquee.mirror_rows()) == 3 end)
    assert Marquee.mirror_rows() == [["1", "a"], ["2", "b"], ["3", "c"]]

    # Two checkpoint advances UPDATEs (txns 1 and 3; the crash window's replay
    # coalesced) plus the bind INSERT — 3 checkpoint writes total.
    PG.wait_until(fn -> DestinationObserver.effect_count(run_id, "checkpoint", "UPDATE") == 2 end)
    assert_effect_counts(run_id, 3, 3, 3)
    assert_onetime_effect_counts(run_id, 3, 3, 3)
    assert_atomic_observer_groups(run_id)
  end

  test "atomic rollback: a checkpoint-write fault rolls back every participant, then replays once",
       %{run_id: run_id} do
    start!()
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('1', 'a')")
    PG.wait_until(fn -> Marquee.mirror_rows() == [["1", "a"]] end)

    Marquee.q!(
      "ALTER TABLE ash_replicant_checkpoints ADD CONSTRAINT tmp_block CHECK (commit_lsn < 0) NOT VALID"
    )

    query_ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, query_ref},
      [:ash_replicant, :test_repo, :query],
      fn _event, _measurements, metadata, _config ->
        if is_binary(metadata[:query]) and
             String.contains?(metadata.query, ~s(INSERT INTO "#{Marquee.mirror()}")) do
          send(test_pid, {:mapped_statement_executed, query_ref})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, query_ref}) end)

    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('2', 'b')")
    assert_receive {:mapped_statement_executed, ^query_ref}, 15_000
    assert Marquee.mirror_rows() == [["1", "a"]]
    assert_effect_counts(run_id, 1, 1, 2)
    assert_onetime_effect_counts(run_id, 1, 1, 1)

    Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT tmp_block")
    AshReplicant.stop_supervised(@slot)
    start!()
    PG.wait_until(fn -> length(Marquee.mirror_rows()) == 2 end)
    assert Marquee.mirror_rows() == [["1", "a"], ["2", "b"]]

    PG.wait_until(fn -> length(DestinationObserver.rows(run_id)) == 13 end)
    assert_effect_counts(run_id, 2, 2, 3)
    assert_onetime_effect_counts(run_id, 2, 2, 2)
    assert_atomic_observer_groups(run_id)

    [[commit_lsn]] =
      Marquee.q!(
        "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [@slot]
      ).rows

    source_identity = Map.new(Marquee.source_identity())

    {:ok, operation_key} =
      AshReplicant.DestinationParticipant.operation_key(
        %{
          source_system_identifier: source_identity.system_identifier,
          source_database: source_identity.database,
          slot_name: @slot,
          commit_lsn: commit_lsn,
          ordinal: 0,
          # F7: must EQUAL the sink-minted label at this effect site (the
          # streaming upsert path) or the key matches no stored claim.
          invocation: :upsert
        },
        :scd1_auxiliary
      )

    replayed =
      Ash.create!(Marquee.Auxiliary, %{},
        action: :record,
        authorize?: false,
        private_arguments: %{operation_key: operation_key},
        context: %{data_layer: %{repo: AshReplicant.TestRepo}}
      )

    assert AshOnetime.replayed?(replayed) == true
    assert_effect_counts(run_id, 2, 2, 3)
    assert_onetime_effect_counts(run_id, 2, 2, 2)
  end

  test "observer positive control exposes an auxiliary write that escapes through a second Repo",
       %{run_id: run_id} do
    start!()

    Marquee.q!(
      "ALTER TABLE ash_replicant_checkpoints ADD CONSTRAINT tmp_block CHECK (commit_lsn < 0) NOT VALID"
    )

    :persistent_term.put(Marquee.escape_key(), true)
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('escape', 'structural')")

    assert_receive {:sink_transaction_id, sink_transaction_id}, 15_000
    assert_receive {:escape_inserted, 1}, 15_000

    PG.wait_until(fn -> DestinationObserver.effect_count(run_id, "auxiliary", "INSERT") == 1 end)

    assert Marquee.mirror_rows() == []
    assert [[1]] = Marquee.q!("SELECT count(*) FROM #{Marquee.auxiliary()}").rows

    # B2: the bind created the row at connect; the watermark stays nil because
    # the halted transaction never committed an advance.
    assert [[nil]] ==
             Marquee.q!(
               "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
               [@slot]
             ).rows

    # The escaped auxiliary write is the ONLY non-bind observer row: the B2
    # bind's checkpoint INSERT is its own (legitimate) earlier transaction.
    assert [%{participant: "auxiliary", transaction_id: foreign_transaction_id}] =
             Enum.filter(DestinationObserver.rows(run_id), &(&1.participant == "auxiliary"))

    refute foreign_transaction_id == sink_transaction_id
  end

  defp observer_triggers do
    [
      %{table: Marquee.mirror(), participant: "mapped", operations: [:insert, :update, :delete]},
      %{table: Marquee.auxiliary(), participant: "auxiliary", operations: [:insert]},
      %{
        table: "ash_replicant_checkpoints",
        participant: "checkpoint",
        operations: [:insert, :update],
        commit_lsn_column: "commit_lsn"
      },
      %{
        table: "ash_onetime_idempotency_claims",
        participant: "onetime_claim",
        operations: [:insert, :update]
      },
      %{
        table: "ash_onetime_response_payloads",
        participant: "onetime_response",
        operations: [:insert]
      }
    ]
  end

  defp assert_effect_counts(run_id, mapped, auxiliary, checkpoint) do
    assert DestinationObserver.effect_count(run_id, "mapped", "INSERT") == mapped
    assert DestinationObserver.effect_count(run_id, "auxiliary", "INSERT") == auxiliary

    checkpoint_count =
      DestinationObserver.effect_count(run_id, "checkpoint", "INSERT") +
        DestinationObserver.effect_count(run_id, "checkpoint", "UPDATE")

    assert checkpoint_count == checkpoint
  end

  defp assert_onetime_effect_counts(run_id, claims, completions, responses) do
    assert DestinationObserver.effect_count(run_id, "onetime_claim", "INSERT") == claims
    assert DestinationObserver.effect_count(run_id, "onetime_claim", "UPDATE") == completions
    assert DestinationObserver.effect_count(run_id, "onetime_response", "INSERT") == responses
  end

  defp assert_atomic_observer_groups(run_id) do
    run_id
    |> DestinationObserver.rows()
    |> Enum.group_by(& &1.transaction_id)
    # Scoped to STREAM-transaction groups (those carrying a mapped effect): the
    # B2 bind transaction legitimately observes as a checkpoint-only group.
    |> Enum.filter(fn {_transaction_id, rows} ->
      Enum.any?(rows, &(&1.participant == "mapped"))
    end)
    |> Enum.each(fn {_transaction_id, rows} ->
      participants = MapSet.new(rows, & &1.participant)

      assert participants ==
               MapSet.new([
                 "mapped",
                 "auxiliary",
                 "checkpoint",
                 "onetime_claim",
                 "onetime_response"
               ])

      assert Enum.count(rows, &(&1.participant == "checkpoint")) == 1
    end)
  end
end
