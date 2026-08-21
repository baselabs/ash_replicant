defmodule AshReplicant.AppendOriginTest do
  @moduledoc """
  The append sink's kind, its declared initial state, and the immutable origin
  floor (ADR-0018 §1 and §5).

  §5 is the quietest clause in the ADR: a go-forward append log makes NO
  completeness claim about data before its floor, and the only way that claim
  stays honest is if the floor is written ONCE and every later reconnect origin
  is treated as a moving resume fact rather than a new floor. A slot CREATED
  under an existing floor proves replacement and halts as a gap. Replicant does
  not filtered-WAL idle-advance append sinks, so a reused origin above the
  durable destination watermark also proves a gap.
  """

  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Error
  alias AshReplicant.Test.AdmittedGeneration
  alias AshReplicant.Test.OrderEvent

  @sys "7673383468368400428"
  @db "ash_replicant_test"

  defmodule GoForwardSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.AppendDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_go_forward",
      sink_kind: :append_log,
      initial_state: :go_forward
  end

  defmodule SnapshotIntentSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.AppendDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_snapshot_intent",
      sink_kind: :append_log,
      initial_state: :snapshot
  end

  defmodule MirrorSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_mirror_control"
  end

  defmodule MessageRouteOnlyDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.SecretEvent
    end
  end

  defmodule MessageRouteOnlySink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.AppendOriginTest.MessageRouteOnlyDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_message_route_only",
      sink_kind: :append_log,
      initial_state: :go_forward,
      message_routes: [{"events", AshReplicant.Test.OrderEvent, :append}]
  end

  describe "sink_kind/0 is exclusive and compile-declared (ADR-0018 §1)" do
    test "an append sink reports :append_log; a plain sink stays :state_mirror" do
      assert GoForwardSink.sink_kind() == :append_log
      assert SnapshotIntentSink.sink_kind() == :append_log
      assert MirrorSink.sink_kind() == :state_mirror
    end

    test "only a go-forward append sink exposes handle_slot_origin/2" do
      # Replicant only pays for the extra connect query when the callback
      # exists, so a snapshot-intent or mirror sink must NOT export it.
      assert function_exported?(GoForwardSink, :handle_slot_origin, 2)
      refute function_exported?(SnapshotIntentSink, :handle_slot_origin, 2)
      refute function_exported?(MirrorSink, :handle_slot_origin, 2)
    end

    test "an append sink must declare exactly one initial-state intent" do
      assert_raise ArgumentError, ~r/initial_state/, fn ->
        defmodule Elixir.AshReplicant.AppendOriginTest.NoIntent do
          use AshReplicant.Sink,
            repo: AshReplicant.TestRepo,
            domains: [AshReplicant.Test.AppendDomain],
            checkpoint_resource: AshReplicant.Test.Checkpoint,
            slot_name: "append_no_intent",
            sink_kind: :append_log
        end
      end
    end

    test "a state-mirror sink may not declare an initial-state intent" do
      assert_raise ArgumentError, ~r/initial_state/, fn ->
        defmodule Elixir.AshReplicant.AppendOriginTest.MirrorIntent do
          use AshReplicant.Sink,
            repo: AshReplicant.TestRepo,
            domains: [AshReplicant.Test.Domain],
            checkpoint_resource: AshReplicant.Test.Checkpoint,
            slot_name: "append_mirror_intent",
            initial_state: :go_forward
        end
      end
    end

    test "an unknown sink kind is a compile error" do
      assert_raise ArgumentError, ~r/sink_kind/, fn ->
        defmodule Elixir.AshReplicant.AppendOriginTest.BadKind do
          use AshReplicant.Sink,
            repo: AshReplicant.TestRepo,
            domains: [AshReplicant.Test.Domain],
            checkpoint_resource: AshReplicant.Test.Checkpoint,
            slot_name: "append_bad_kind",
            sink_kind: :event_stream
        end
      end
    end
  end

  describe "the origin floor (ADR-0018 §5)" do
    setup do
      generation =
        AdmittedGeneration.put!(GoForwardSink,
          source_identity: %{system_identifier: @sys, database: @db}
        )

      config = AshReplicant.runtime_config(generation)
      bind_checkpoint!(config)
      on_exit(fn -> :persistent_term.erase({AshReplicant, config.slot_name}) end)
      %{config: config}
    end

    test "a NEW slot's consistent point becomes the immutable floor", %{config: config} do
      assert :ok = GoForwardSink.handle_slot_origin(9_000, origin_context(false))
      assert checkpoint_row(config).origin_floor == 9_000
    end

    test "a REUSED slot's effective start origin becomes the floor too", %{config: config} do
      assert :ok = GoForwardSink.handle_slot_origin(9_000, origin_context(true))
      assert checkpoint_row(config).origin_floor == 9_000
    end

    test "a later reconnect origin is a resume FACT and never replaces the floor", %{
      config: config
    } do
      assert :ok = GoForwardSink.handle_slot_origin(9_000, origin_context(false))
      advance_checkpoint!(config, 9_500)

      assert :ok = GoForwardSink.handle_slot_origin(9_500, origin_context(true))

      row = checkpoint_row(config)
      assert row.origin_floor == 9_000
      assert row.commit_lsn == 9_500
    end

    test "a RECREATED slot at the durable frontier still halts as a gap", %{
      config: config
    } do
      assert :ok = GoForwardSink.handle_slot_origin(9_000, origin_context(false))
      advance_checkpoint!(config, 9_500)

      # `reused?: false` means this slot was created THIS session. The previous
      # slot is gone. Use an origin exactly equal to the durable frontier so the
      # assertion isolates slot replacement from the independent
      # `origin > frontier` gap check.
      assert {:error, %Error{reason: :append_origin_gap}} =
               GoForwardSink.handle_slot_origin(9_500, origin_context(false))
    end

    test "a reused slot whose origin exceeds the durable frontier halts as a gap", %{
      config: config
    } do
      assert :ok = GoForwardSink.handle_slot_origin(9_000, origin_context(false))
      advance_checkpoint!(config, 9_500)

      assert {:error, %Error{reason: :append_origin_gap}} =
               GoForwardSink.handle_slot_origin(12_000, origin_context(true))

      assert checkpoint_row(config).origin_floor == 9_000
    end

    test "an appended event ahead of the durable checkpoint halts as a divergent frontier", %{
      config: config
    } do
      assert :ok = GoForwardSink.handle_slot_origin(9_000, origin_context(false))
      advance_checkpoint!(config, 9_500)
      append_event!(config, 9_900)

      # Append and checkpoint commit atomically, so an event above the
      # watermark can only mean a torn write — never resume over it.
      assert {:error, %Error{reason: :append_frontier_divergent}} =
               GoForwardSink.handle_slot_origin(9_500, origin_context(true))
    end

    test "the frontier includes append resources reachable only through message routes" do
      generation =
        AdmittedGeneration.put!(MessageRouteOnlySink,
          source_identity: %{system_identifier: @sys, database: @db}
        )

      config = AshReplicant.runtime_config(generation)
      bind_checkpoint!(config)
      on_exit(fn -> :persistent_term.erase({AshReplicant, config.slot_name}) end)

      assert :ok =
               MessageRouteOnlySink.handle_slot_origin(9_000, %{
                 slot_name: config.slot_name,
                 reused?: false
               })

      advance_checkpoint!(config, 9_500)
      append_event!(config, 9_900)

      assert {:error, %Error{reason: :append_frontier_divergent}} =
               MessageRouteOnlySink.handle_slot_origin(9_500, %{
                 slot_name: config.slot_name,
                 reused?: true
               })
    end

    test "the floor halt is value-free", %{config: config} do
      assert :ok = GoForwardSink.handle_slot_origin(9_000, origin_context(false))
      advance_checkpoint!(config, 9_500)

      {:error, error} = GoForwardSink.handle_slot_origin(12_000, origin_context(false))

      rendered = Exception.message(error)
      refute rendered =~ "12000"
      refute rendered =~ @sys
    end
  end

  describe "activation rejects a mixed or contradictory sink (ADR-0018 §1, §5)" do
    test "a sink whose mapped resources disagree with its kind is rejected" do
      assert {:error, :sink_kind_mixed} =
               AshReplicant.start_link(
                 sink: AshReplicant.AppendOriginTest.MixedSink,
                 source_identity: [system_identifier: @sys, database: @db],
                 publication: ["test_publication"]
               )
    end

    test "a state-mirror sink mapping append targets is rejected" do
      assert {:error, :sink_kind_mixed} =
               AshReplicant.start_link(
                 sink: AshReplicant.AppendOriginTest.MirrorOverAppendSink,
                 source_identity: [system_identifier: @sys, database: @db],
                 publication: ["test_publication"]
               )
    end

    test "a :snapshot-intent append sink started go-forward is rejected" do
      assert {:error, :initial_state_mismatch} =
               AshReplicant.start_link(
                 sink: SnapshotIntentSink,
                 source_identity: [system_identifier: @sys, database: @db],
                 publication: ["test_publication"]
               )
    end

    test "a :go_forward append sink started with a snapshot is rejected" do
      assert {:error, :initial_state_mismatch} =
               AshReplicant.start_link(
                 sink: GoForwardSink,
                 source_identity: [system_identifier: @sys, database: @db],
                 publication: ["test_publication"],
                 snapshot: true
               )
    end
  end

  defmodule MixedDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      # Distinct SOURCE tables on purpose: two resources mapping one source is
      # already rejected as a duplicate source, which would mask the sink-kind
      # gate under test.
      resource AshReplicant.Test.Account
      resource AshReplicant.Test.OrderEvent
    end
  end

  defmodule MixedSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.AppendOriginTest.MixedDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_mixed",
      sink_kind: :append_log,
      initial_state: :go_forward
  end

  defmodule MirrorOverAppendSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.AppendDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_mirror_over_append"
  end

  # --- helpers ---

  defp origin_context(reused?),
    do: %{slot_name: "append_go_forward", reused?: reused?}

  defp bind_checkpoint!(config) do
    Ash.create!(
      config.checkpoint_resource,
      %{source_system_id: @sys, source_database: @db, slot_name: config.slot_name},
      action: :upsert,
      upsert?: true,
      upsert_identity: :source_slot,
      upsert_fields: [],
      authorize?: false
    )
  end

  defp advance_checkpoint!(config, lsn) do
    Ash.create!(
      config.checkpoint_resource,
      %{
        source_system_id: @sys,
        source_database: @db,
        slot_name: config.slot_name,
        commit_lsn: lsn
      },
      action: :upsert,
      upsert?: true,
      upsert_identity: :source_slot,
      upsert_fields: [:commit_lsn],
      authorize?: false
    )
  end

  defp checkpoint_row(config) do
    Ash.get!(
      config.checkpoint_resource,
      %{source_system_id: @sys, source_database: @db, slot_name: config.slot_name},
      authorize?: false
    )
  end

  defp append_event!(config, lsn) do
    Ash.create!(
      OrderEvent,
      %{
        source_system_id: @sys,
        source_database: @db,
        slot_name: config.slot_name,
        commit_lsn: lsn,
        ordinal: 0,
        operation: "insert",
        origin: "stream",
        id: "o1"
      },
      action: :append,
      authorize?: false
    )
  end
end
