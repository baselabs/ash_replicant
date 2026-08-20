defmodule AshReplicant.MessageActionsTest do
  @moduledoc """
  C1 direct-drive tier: the message paths exercised through the generated
  sink's callbacks against the live destination (sandbox-owned), with the
  generation admitted directly — every acceptance cell that does not need the
  wire. The pipeline tier (`MessagePipelineTest`, below) proves the live
  stream path.
  """

  use AshReplicant.DataCase, async: false
  @moduletag :integration

  alias AshReplicant.Test.{AdmittedGeneration, DestinationObserver, Marquee, Messages}
  alias Ecto.Adapters.SQL

  # The baked slot of Messages.MarqueeSink (the direct-drive sink); this module
  # runs before the pipeline tier and erases its checkpoint rows on exit, so
  # the two tiers share the slot name without sharing durable state.
  @slot "message_marquee_slot"

  setup do
    Marquee.setup_schema!()
    Messages.setup_schema!()

    generation = AdmittedGeneration.put!(Messages.MarqueeSink)

    identity = %Replicant.SessionIdentity{
      system_identifier: generation.source_identity.system_identifier,
      timeline_id: 1,
      current_lsn: 0,
      database: generation.source_identity.database
    }

    Messages.MarqueeSink.handle_session_identity(identity, %{
      slot_name: @slot,
      publication: generation.publication
    })

    run_id = "c1-direct-#{System.unique_integer([:positive])}"

    DestinationObserver.setup!(run_id, observer_triggers())

    Messages.reset_peer!()

    on_exit(fn ->
      :persistent_term.erase({AshReplicant, @slot})

      AshReplicant.TestRepo.query!(
        "DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [@slot]
      )

      Messages.reset_peer!()
    end)

    {:ok, generation: generation, run_id: run_id}
  end

  defp observer_triggers do
    [
      %{table: Marquee.mirror(), participant: "mapped", operations: [:insert]},
      %{table: Messages.outbox(), participant: "message_local", operations: [:insert]},
      %{table: Messages.peer(), participant: "message_peer", operations: [:insert]},
      %{
        table: "ash_replicant_checkpoints",
        participant: "checkpoint",
        operations: [:insert, :update],
        commit_lsn_column: "commit_lsn"
      }
    ]
  end

  defp msg(prefix, content, lsn, opts \\ []) do
    %Replicant.Decoder.Messages.Message{
      transactional?: Keyword.get(opts, :transactional?, false),
      lsn: lsn,
      prefix: prefix,
      content: content,
      ordinal: Keyword.get(opts, :ordinal)
    }
  end

  defp txn(lsn, changes, messages) do
    %Replicant.Transaction{commit_lsn: lsn, changes: changes, messages: messages}
  end

  defp ins(id, ordinal, lsn),
    do: %Replicant.Change{
      op: :insert,
      schema: "public",
      table: Marquee.src(),
      record: %{"id" => id, "note" => "n"},
      commit_lsn: lsn,
      ordinal: ordinal
    }

  defp outbox_contents,
    do: Messages.rows(Messages.outbox()) |> Enum.map(&Enum.at(&1, 0))

  defp checkpoint_lsn do
    [[lsn]] =
      SQL.query!(
        AshReplicant.TestRepo,
        "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [
          @slot
        ]
      ).rows

    lsn
  end

  describe "transactional messages ride the transaction" do
    test "changes and messages interleave by ordinal in ONE transaction", %{
      run_id: run_id
    } do
      # ordinals: change 0, MESSAGE 1, change 2 — the shared numbering space.
      assert {:ok, 700} =
               Messages.MarqueeSink.handle_transaction(
                 txn(700, [ins("a", 0, 700), ins("b", 2, 700)], [
                   msg("outbox", "between", 701, ordinal: 1, transactional?: true)
                 ])
               )

      assert outbox_contents() == ["between"]
      assert Marquee.mirror_rows() == [["a", "n"], ["b", "n"]]

      # The order proof: the observer records effects by physical insertion
      # order (ctid) inside the one destination transaction — the message
      # effect sits BETWEEN the two mapped effects.
      participants = Enum.map(DestinationObserver.rows(run_id), & &1.participant)

      assert participants == ["mapped", "message_local", "mapped", "checkpoint"]
      assert checkpoint_lsn() == 700
    end

    test "a failing change rolls the message effect back atomically" do
      bad = %Replicant.Change{
        op: :insert,
        schema: "public",
        table: Marquee.src(),
        record: %{"note" => "SECRET_4111"},
        commit_lsn: 710,
        ordinal: 2
      }

      assert {:error, %AshReplicant.Error{}} =
               Messages.MarqueeSink.handle_transaction(
                 txn(710, [ins("c", 0, 710), bad], [
                   msg("outbox", "rolled-back", 711, ordinal: 1, transactional?: true)
                 ])
               )

      assert outbox_contents() == []

      assert [[0]] =
               SQL.query!(
                 AshReplicant.TestRepo,
                 "SELECT count(*) FROM ash_replicant_checkpoints WHERE slot_name = $1 AND commit_lsn = $2",
                 [@slot, 710]
               ).rows
    end

    test "re-delivering the committed transaction is a watermark skip (zero new effects)" do
      delivered =
        txn(720, [ins("d", 0, 720)], [
          msg("outbox", "once", 721, ordinal: 1, transactional?: true)
        ])

      assert {:ok, 720} = Messages.MarqueeSink.handle_transaction(delivered)
      assert {:ok, 720} = Messages.MarqueeSink.handle_transaction(delivered)

      assert outbox_contents() == ["once"]
      assert Marquee.mirror_rows() == [["d", "n"]]
    end

    test "an unmapped transactional-message prefix halts inside the transaction" do
      assert {:error, %AshReplicant.Error{reason: :message_prefix_unmapped}} =
               Messages.MarqueeSink.handle_transaction(
                 txn(730, [ins("e", 1, 730)], [
                   msg("evil", "x", 731, ordinal: 0, transactional?: true)
                 ])
               )

      assert outbox_contents() == []
      assert Marquee.mirror_rows() == []
    end

    test "an ignored transactional-message prefix is inert" do
      assert {:ok, 740} =
               Messages.MarqueeSink.handle_transaction(
                 txn(740, [ins("f", 1, 740)], [
                   msg("noise", "x", 741, ordinal: 0, transactional?: true)
                 ])
               )

      assert outbox_contents() == []
      assert Marquee.mirror_rows() == [["f", "n"]]
    end
  end

  describe "standalone messages: effect + claim + watermark" do
    test "a database-local message applies effect, claim, and watermark in ONE transaction", %{
      run_id: run_id
    } do
      ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :message, :applied]])

      assert :ok =
               Messages.MarqueeSink.handle_message(msg("outbox", "standalone", 800), %{lsn: 800})

      assert_received {[:ash_replicant, :message, :applied], ^ref, measurements, meta}
      assert measurements.byte_size == byte_size("standalone")
      assert meta.commit_lsn == 800
      assert meta.resource == Messages.Outbox
      assert meta.transactional == false
      :telemetry.detach(ref)

      assert outbox_contents() == ["standalone"]
      assert checkpoint_lsn() == 800

      # ONE transaction: the message effect and the checkpoint watermark share
      # a txid (the observer records it per effect).
      rows = DestinationObserver.rows(run_id)

      assert Enum.at(rows, 0).participant == "message_local"
      assert Enum.at(rows, 1).participant == "checkpoint"

      assert Enum.at(rows, 0).transaction_id == Enum.at(rows, 1).transaction_id
    end

    test "re-delivery (crash between effect and ack) replays the claim — zero net effect" do
      assert :ok =
               Messages.MarqueeSink.handle_message(msg("outbox", "replay-me", 810), %{lsn: 810})

      assert :ok =
               Messages.MarqueeSink.handle_message(msg("outbox", "replay-me", 810), %{lsn: 810})

      assert outbox_contents() == ["replay-me"]

      assert [[1]] =
               SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM #{Messages.outbox()}").rows

      assert checkpoint_lsn() == 810
    end

    test "a digest mismatch halts value-free and never re-executes" do
      assert :ok =
               Messages.MarqueeSink.handle_message(msg("outbox", "original", 820), %{lsn: 820})

      assert {:error, %AshReplicant.Error{} = error} =
               Messages.MarqueeSink.handle_message(msg("outbox", "MUTATED", 820), %{lsn: 820})

      assert error.reason == :sink_failed
      refute inspect(error) =~ "MUTATED"
      refute Exception.message(error) =~ "MUTATED"
      assert outbox_contents() == ["original"]
      assert checkpoint_lsn() == 820
    end

    test "key rotation replays through the retained version (no hard cut)" do
      v1 = [{1, "rotation-version-one-key!!"}]
      v1_v2 = [{1, "rotation-version-one-key!!"}, {2, "rotation-version-two-key"}]

      Messages.with_digest_keys!(v1, fn ->
        assert :ok =
                 Messages.MarqueeSink.handle_message(msg("outbox", "rotated", 830), %{lsn: 830})
      end)

      # Active version is now v2: the fresh digest mismatches the v1-minted
      # claim, the retained v1 digest matches, the claim REPLAYS.
      Messages.with_digest_keys!(v1_v2, fn ->
        assert :ok =
                 Messages.MarqueeSink.handle_message(msg("outbox", "rotated", 830), %{lsn: 830})
      end)

      assert outbox_contents() == ["rotated"]
    end

    test "an unknown prefix halts fail-closed with the structural reason" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :halted]])

      assert {:error, %AshReplicant.Error{} = error} =
               Messages.MarqueeSink.handle_message(msg("evil", "nope", 850), %{lsn: 850})

      assert error.reason == :message_prefix_unmapped

      assert_received {[:ash_replicant, :sink, :halted], ^ref, _m, meta}
      assert meta.reason == :message_prefix_unmapped
      :telemetry.detach(ref)

      assert outbox_contents() == []
    end

    test "an ignored prefix acknowledges with the watermark and no effect" do
      assert :ok = Messages.MarqueeSink.handle_message(msg("noise", "ignored", 860), %{lsn: 860})

      assert outbox_contents() == []
      assert checkpoint_lsn() == 860
    end
  end
end

defmodule AshReplicant.MessagePipelineTest do
  @moduledoc """
  C1 pipeline tier: the live logical-replication stream — `messages: true`
  auto-enabled on a message-capable sink, transactional messages riding real
  WAL transactions, standalone messages acked at their own LSN, and the
  unknown-prefix halt killing the pipeline fail-closed.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshOnetime.Store.Postgres, as: OnetimeStore
  alias AshReplicant.Test.{AdmittedGeneration, DestinationObserver, Marquee, Messages, PG}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @slot "message_marquee_slot"

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()
    Messages.setup_schema!()
    run_id = "c1-pipeline-#{System.unique_integer([:positive])}"
    DestinationObserver.setup!(run_id, observer_triggers())

    Messages.reset_peer!()

    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      DestinationObserver.teardown!(observer_triggers())
      Messages.reset_peer!()
    end)

    {:ok, run_id: run_id}
  end

  defp observer_triggers do
    [
      %{table: Marquee.mirror(), participant: "mapped", operations: [:insert]},
      %{table: Messages.outbox(), participant: "message_local", operations: [:insert]},
      %{
        table: "ash_replicant_checkpoints",
        participant: "checkpoint",
        operations: [:insert, :update],
        commit_lsn_column: "commit_lsn"
      }
    ]
  end

  defp start! do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _m, _meta, _cfg -> send(test_pid, {:slot_active, ref}) end,
      nil
    )

    {:ok, _pid} =
      AshReplicant.start_link(
        sink: Messages.MarqueeSink,
        connection: Marquee.conn(),
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

  defp emit_transactional(content) do
    AshReplicant.TestRepo.transaction(fn ->
      Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('t1', 'a')")
      Marquee.q!("SELECT pg_logical_emit_message(true, $1, $2)", ["outbox", content])
      Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('t2', 'b')")
    end)
  end

  test "a transactional message rides the live transaction between the row changes", %{
    run_id: run_id
  } do
    start!()

    emit_transactional("live-txn-message")

    PG.wait_until(
      fn ->
        Enum.map(Messages.rows(Messages.outbox()), &Enum.at(&1, 0)) == ["live-txn-message"] and
          Marquee.mirror_rows() == [["t1", "a"], ["t2", "b"]]
      end,
      800
    )

    # Order by physical effect order: the message lands BETWEEN the two mapped
    # row writes, inside the ONE destination transaction.
    participants = Enum.map(DestinationObserver.rows(run_id), & &1.participant)

    assert Enum.take(participants, -4) == ["mapped", "message_local", "mapped", "checkpoint"]
  end

  test "a standalone message lands with its own watermark and telemetry" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :message, :applied]])
    start!()

    Marquee.q!("SELECT pg_logical_emit_message(false, 'outbox', 'live-standalone')")

    PG.wait_until(
      fn ->
        Enum.map(Messages.rows(Messages.outbox()), &Enum.at(&1, 0)) == ["live-standalone"]
      end,
      800
    )

    assert_received {[:ash_replicant, :message, :applied], ^ref, _m, meta}
    assert meta.transactional == false
    assert is_integer(meta.commit_lsn)
    :telemetry.detach(ref)

    PG.wait_until(
      fn ->
        [[lsn]] =
          Marquee.q!("SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1", [
            @slot
          ]).rows

        lsn == meta.commit_lsn
      end,
      400
    )
  end

  test "an ignored standalone prefix is acknowledged with no effect" do
    start!()

    Marquee.q!("SELECT pg_logical_emit_message(false, 'noise', 'ignored-live')")

    PG.wait_until(
      fn ->
        [[lsn]] =
          Marquee.q!("SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1", [
            @slot
          ]).rows

        is_integer(lsn) and lsn > 0
      end,
      800
    )

    assert Messages.rows(Messages.outbox()) == []
  end

  # Direct-drive admission for the external-peer recovery cells (the committed
  # claim worker needs a real, non-sandboxed connection — hence this tier).
  defp admit_direct! do
    generation = AdmittedGeneration.put!(Messages.MarqueeSink)

    identity = %Replicant.SessionIdentity{
      system_identifier: generation.source_identity.system_identifier,
      timeline_id: 1,
      current_lsn: 0,
      database: generation.source_identity.database
    }

    :ok =
      Messages.MarqueeSink.handle_session_identity(identity, %{
        slot_name: @slot,
        publication: generation.publication
      })

    generation
  end

  # Local repeated runs share this test database. The output fixture tables are
  # rebuilt per test, but AshOnetime's durable claims intentionally survive;
  # without draining already-expired test claims, the bounded cleanup below can
  # spend its whole batch on older rows and never reach the claim under test.
  defp drain_expired_claims!(target) do
    assert {:ok, %{idempotency: deleted}} = AshOnetime.Store.cleanup(target, 10_000)

    if deleted == 10_000, do: drain_expired_claims!(target), else: :ok
  end

  defp msg(prefix, content, lsn) do
    %Replicant.Decoder.Messages.Message{
      transactional?: false,
      lsn: lsn,
      prefix: prefix,
      content: content
    }
  end

  defp checkpoint_lsn do
    [[lsn]] =
      SQL.query!(
        AshReplicant.TestRepo,
        "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [@slot]
      ).rows

    lsn
  end

  test "an unknown standalone prefix halts the pipeline fail-closed" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :halted]])
    start!()

    Marquee.q!("SELECT pg_logical_emit_message(false, 'evil', 'unmapped-live')")

    PG.wait_until(
      fn ->
        receive do
          {[:ash_replicant, :sink, :halted], ^ref, _m, %{reason: :message_prefix_unmapped}} ->
            true
        after
          0 -> false
        end
      end,
      800
    )

    :telemetry.detach(ref)

    assert Messages.rows(Messages.outbox()) == []

    # Fail-closed: the generation is gone (the pipeline halted), and the slot
    # is immediately re-activatable.
    PG.wait_until(
      fn -> :persistent_term.get({AshReplicant, @slot}, :none) == :none end,
      400
    )
  end

  # The external-peer recovery cells: direct drives in the AUTO tier because
  # the committed-claim worker needs a real (non-sandbox) connection.
  test "a claim past retention re-executes after the cleanup reaper (the operator-sized replay window)" do
    admit_direct!()
    {:ok, target} = OnetimeStore.target(Messages.TransientOutbox, [])
    drain_expired_claims!(target)

    lsn = System.unique_integer([:positive]) * 10_000 + 7

    assert :ok =
             Messages.MarqueeSink.handle_message(msg("transient", "expires", lsn), %{lsn: lsn})

    Process.sleep(1_200)

    # Retention is enforced by the reaper, not the claim path: the operator's
    # cleanup pass deletes the expired claim, and the next delivery re-executes.
    assert {:ok, %{idempotency: deleted}} = AshOnetime.Store.cleanup(target, 100)
    assert deleted >= 1

    assert :ok =
             Messages.MarqueeSink.handle_message(msg("transient", "expires", lsn), %{lsn: lsn})

    assert [[2]] =
             SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM repl_transient_outbox").rows
  end

  describe "external peer routes: AshOnetime three-state recovery" do
    # Committed claims survive across runs, so every test mints under a
    # run-unique LSN — the identity axis that keeps claims distinct.
    setup do
      admit_direct!()
      Messages.reset_peer!()
      base = System.unique_integer([:positive]) * 10_000
      {:ok, base: base}
    end

    test "a successful execute finalizes exactly once", %{base: base} do
      lsn = base + 1

      assert :ok = Messages.MarqueeSink.handle_message(msg("peer", "peer-ok", lsn), %{lsn: lsn})
      assert Messages.peer_calls() == [:execute]

      assert [[1]] =
               SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM #{Messages.peer()}").rows

      assert checkpoint_lsn() == lsn
    end

    test "re-delivery replays without touching the peer", %{base: base} do
      lsn = base + 2

      assert :ok =
               Messages.MarqueeSink.handle_message(msg("peer", "peer-replay", lsn), %{lsn: lsn})

      assert :ok =
               Messages.MarqueeSink.handle_message(msg("peer", "peer-replay", lsn), %{lsn: lsn})

      assert Messages.peer_calls() == [:execute]

      assert [[1]] =
               SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM #{Messages.peer()}").rows
    end

    test "an ambiguous outcome halts value-free and the watermark does NOT advance", %{base: base} do
      lsn = base + 3
      Messages.peer_mode!(:unknown)

      assert {:error, %AshReplicant.Error{} = error} =
               Messages.MarqueeSink.handle_message(msg("peer", "peer-unknown", lsn), %{lsn: lsn})

      assert error.reason == :sink_failed
      refute inspect(error) =~ "peer-unknown"

      assert [[0]] =
               SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM #{Messages.peer()}").rows
    end

    test "re-delivery after ambiguity runs the recover path and finalizes once", %{base: base} do
      lsn = base + 4
      Messages.peer_mode!(:unknown)

      assert {:error, %AshReplicant.Error{}} =
               Messages.MarqueeSink.handle_message(msg("peer", "peer-recover", lsn), %{lsn: lsn})

      # Recovery mode returns a proven peer result; re-delivery resolves
      # through recover + finalize — exactly one local record of the effect.
      :persistent_term.put(Messages.peer_recover_mode_key(), :ok)

      assert :ok =
               Messages.MarqueeSink.handle_message(msg("peer", "peer-recover", lsn), %{lsn: lsn})

      # One ambiguous attempt (execute unknown, recover unknown), then the
      # re-delivery resolves through recover alone — the peer never re-sees
      # the key on a proven result.
      assert Messages.peer_calls() == [:execute, :recover, :recover]

      assert [[1]] =
               SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM #{Messages.peer()}").rows

      assert checkpoint_lsn() == lsn
    end

    test "recover proving absence re-executes the peer effect", %{base: base} do
      lsn = base + 5

      # First delivery: execute outcome unknown → halt with the claim
      # processing (committed independently by the external path).
      :persistent_term.put(Messages.peer_mode_key(), :unknown)
      :persistent_term.put(Messages.peer_recover_mode_key(), :unknown)

      assert {:error, %AshReplicant.Error{}} =
               Messages.MarqueeSink.handle_message(msg("peer", "peer-absent", lsn), %{lsn: lsn})

      # Re-delivery: recover proves the peer NEVER saw the key, so the effect
      # re-executes — now successfully — and finalizes.
      :persistent_term.put(Messages.peer_mode_key(), :ok)
      :persistent_term.put(Messages.peer_recover_mode_key(), :absent)

      assert :ok =
               Messages.MarqueeSink.handle_message(msg("peer", "peer-absent", lsn), %{lsn: lsn})

      assert Messages.peer_calls() == [:execute, :recover, :recover, :execute]

      assert [[1]] =
               SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM #{Messages.peer()}").rows
    end
  end
end
