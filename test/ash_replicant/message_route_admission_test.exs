defmodule AshReplicant.MessageRouteAdmissionTest do
  @moduledoc """
  C1 admission tier: the message-route manifest walk and the compile-shape of
  the generated sink. Pure reflection (no DB, no live pipeline).
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Destination
  alias AshReplicant.Test.Messages, as: Fixtures

  defp manifest_for(routes) do
    Destination.manifest(%{
      repo: AshReplicant.TestRepo,
      domains: [Fixtures.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      message_routes: routes
    })
  end

  describe "the generated sink" do
    test "unknown prefix bytes never enter an error shape" do
      source = File.read!("lib/ash_replicant/sink/impl.ex")

      refute source =~ "shape: message.prefix"
      refute source =~ "shape: prefix"
    end

    test "a sink with routes exposes handle_message/2; the route-less fixture does not" do
      assert Code.ensure_loaded?(Fixtures.Sink)
      assert function_exported?(Fixtures.Sink, :handle_message, 2)

      # The freeze-table row: route-less sinks keep the ABSENT posture.
      assert Code.ensure_loaded?(AshReplicant.Test.DestinationFixtures.Sink)
      refute function_exported?(AshReplicant.Test.DestinationFixtures.Sink, :handle_message, 2)
    end

    test "the baked config carries the routes and ignores" do
      config = Fixtures.Sink.__ash_replicant_config__()

      assert config.message_routes == [
               {"outbox", Fixtures.Outbox, :record},
               {"peer", Fixtures.PeerOutbox, :record},
               {"transient", Fixtures.TransientOutbox, :record}
             ]

      assert config.ignored_message_prefixes == ["noise"]
    end

    test "a host-defined handle_message hits the finality guard" do
      assert_raise CompileError, ~r/handle_message\/2 is final/, fn ->
        Code.compile_string("""
        defmodule AshReplicant.Test.PreUseMessageSink do
          def handle_message(_message, _ctx), do: :ok

          use AshReplicant.Sink,
            repo: AshReplicant.TestRepo,
            domains: [AshReplicant.Test.Messages.Domain],
            checkpoint_resource: AshReplicant.Test.Checkpoint,
            slot_name: "pre_use_message_slot",
            message_routes: [{"outbox", AshReplicant.Test.Messages.Outbox, :record}]
        end
        """)
      end
    end

    test "malformed route and ignore declarations fail compilation" do
      base = """
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Messages.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      """

      assert_raise ArgumentError, ~r/message_routes/, fn ->
        Code.compile_string("""
        defmodule AshReplicant.Test.BadRouteShapeSink do
          use AshReplicant.Sink,
            #{base}
            slot_name: "bad_route_shape_slot",
            message_routes: [{"", AshReplicant.Test.Messages.Outbox, :record}]
        end
        """)
      end

      assert_raise ArgumentError, ~r/duplicate/, fn ->
        Code.compile_string("""
        defmodule AshReplicant.Test.DupPrefixSink do
          use AshReplicant.Sink,
            #{base}
            slot_name: "dup_prefix_slot",
            message_routes: [
              {"outbox", AshReplicant.Test.Messages.Outbox, :record},
              {"outbox", AshReplicant.Test.Messages.PeerOutbox, :record}
            ]
        end
        """)
      end

      assert_raise ArgumentError, ~r/both routed and ignored/, fn ->
        Code.compile_string("""
        defmodule AshReplicant.Test.OverlapPrefixSink do
          use AshReplicant.Sink,
            #{base}
            slot_name: "overlap_prefix_slot",
            message_routes: [{"outbox", AshReplicant.Test.Messages.Outbox, :record}],
            ignored_message_prefixes: ["outbox"]
        end
        """)
      end

      assert_raise ArgumentError, ~r/ignored_message_prefixes/, fn ->
        Code.compile_string("""
        defmodule AshReplicant.Test.BadIgnoreSink do
          use AshReplicant.Sink,
            #{base}
            slot_name: "bad_ignore_slot",
            ignored_message_prefixes: ["dup", "dup"]
        end
        """)
      end
    end
  end

  describe "the manifest walk" do
    test "an append sink routes messages through the immutable append action without an AshOnetime profile" do
      assert {:ok, manifest} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [AshReplicant.Test.AppendDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint,
                 sink_kind: :append_log,
                 message_routes: [{"events", AshReplicant.Test.OrderEvent, :append}]
               })

      entry =
        Enum.find(
          manifest.entries,
          &(&1.resource == AshReplicant.Test.OrderEvent and &1.role == :append_message)
        )

      assert entry.action == :append
      assert entry.source == {:append_message_route, "events"}
      assert entry.replay_identity == nil
      assert entry.protection == nil
    end

    test "append message routes reject a different action or a tenant-scoped target" do
      assert {:error,
              {:destination_append_message_route_invalid, AshReplicant.Test.OrderEvent, :read}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [AshReplicant.Test.AppendDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint,
                 sink_kind: :append_log,
                 message_routes: [{"events", AshReplicant.Test.OrderEvent, :read}]
               })

      assert {:error,
              {:destination_append_message_route_invalid, AshReplicant.Test.TenantOrderEvent,
               :append}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [AshReplicant.Test.AppendDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint,
                 sink_kind: :append_log,
                 message_routes: [{"events", AshReplicant.Test.TenantOrderEvent, :append}]
               })
    end

    test "a routed action enters the graph as a :message root with the 6-axis replay identity" do
      assert {:ok, manifest} = manifest_for([{"outbox", Fixtures.Outbox, :record}])

      entry =
        Enum.find(manifest.entries, &(&1.resource == Fixtures.Outbox and &1.role == :message))

      assert entry.action == :record
      assert entry.source == {:message_route, "outbox"}
      assert entry.replay_identity.participant == Fixtures.Outbox

      assert entry.replay_identity.components == [
               :source_system_identifier,
               :source_database,
               :slot_name,
               :commit_lsn,
               :ordinal,
               :participant
             ]
    end

    test "a route to a missing action fails with the action-missing reason" do
      assert {:error, {:destination_action_missing, Fixtures.Outbox, :nope}} =
               manifest_for([{"outbox", Fixtures.Outbox, :nope}])
    end

    test "the malformed profiles fail with the message-route reason" do
      assert {:error, {:destination_message_route_invalid, Fixtures.NonceOutbox, :record}} =
               manifest_for([{"nonce", Fixtures.NonceOutbox, :record}])

      assert {:error, {:destination_message_route_invalid, Fixtures.UnprotectedOutbox, :record}} =
               manifest_for([{"bare", Fixtures.UnprotectedOutbox, :record}])

      assert {:error,
              {:destination_message_route_invalid, Fixtures.BadFingerprintOutbox, :record}} =
               manifest_for([{"fp", Fixtures.BadFingerprintOutbox, :record}])
    end

    test "a dropped retention or digest argument on the protection fails closed (struct-mutation probes)" do
      # The package's own verifiers reject these shapes at resource compile
      # time, so the red-capable probe for the adapter's profile check mutates
      # the normalized protection — the destination_test precedent.
      {:ok, manifest} = manifest_for([{"outbox", Fixtures.Outbox, :record}])

      entry =
        Enum.find(manifest.entries, &(&1.resource == Fixtures.Outbox and &1.role == :message))

      no_retention = put_in(entry.protection.retention, nil)

      assert {:error, {:destination_message_route_invalid, Fixtures.Outbox, :record}} =
               Destination.validate_onetime_entries([no_retention])

      bad_fingerprint = put_in(entry.protection.fingerprint, [])

      assert {:error, {:destination_message_route_invalid, Fixtures.Outbox, :record}} =
               Destination.validate_onetime_entries([bad_fingerprint])
    end

    test "an external-effect protection is admitted on a message route and still rejected on an auxiliary" do
      assert {:ok, manifest} = manifest_for([{"peer", Fixtures.PeerOutbox, :record}])

      assert Enum.any?(
               manifest.entries,
               &(&1.resource == Fixtures.PeerOutbox and &1.role == :message and
                   match?(
                     %{external_effect: AshReplicant.Test.Messages.PeerEffect},
                     &1.protection
                   ))
             )

      # The auxiliary rejection is unchanged: an external effect on a
      # row-mirror participant never admits.
      assert {:error, {:destination_participant_invalid, _module}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [AshReplicant.Test.DestinationFixtures.ExternalAuxiliaryDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end

    test "the message route's claim store relations join the onetime preflight set" do
      {:ok, manifest} = manifest_for([{"outbox", Fixtures.Outbox, :record}])

      assert Map.has_key?(manifest.onetime_prefixes_by_action, {Fixtures.Outbox, :record})
    end
  end

  describe "recovery horizon (O03)" do
    test "message_routes without :recovery_horizon fail compilation naming the option" do
      assert_raise ArgumentError, ~r/:recovery_horizon.*declare a recovery horizon/s, fn ->
        Code.compile_string("""
        defmodule AshReplicant.Test.NoHorizonSink do
          use AshReplicant.Sink,
            repo: AshReplicant.TestRepo,
            domains: [AshReplicant.Test.Messages.Domain],
            checkpoint_resource: AshReplicant.Test.Checkpoint,
            slot_name: "no_horizon_slot",
            message_routes: [{"outbox", AshReplicant.Test.Messages.Outbox, :record}]
        end
        """)
      end
    end

    test ":recovery_horizon without message_routes is rejected — nothing to protect" do
      assert_raise ArgumentError, ~r/no message routes to protect/, fn ->
        Code.compile_string("""
        defmodule AshReplicant.Test.UnprotectedHorizonSink do
          use AshReplicant.Sink,
            repo: AshReplicant.TestRepo,
            domains: [AshReplicant.Test.Domain],
            checkpoint_resource: AshReplicant.Test.Checkpoint,
            slot_name: "unprotected_horizon_slot",
            recovery_horizon: {24, :hour}
        end
        """)
      end
    end

    test ":recovery_horizon must be a positive bounded {count, unit} duration" do
      base = """
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Messages.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      """

      for bad <- [{0, :hour}, {-1, :hour}, {1, :decade}, {1.5, :hour}, "24h", 24] do
        assert_raise ArgumentError, ~r/positive bounded \{count, unit\} duration/, fn ->
          Code.compile_string("""
          defmodule AshReplicant.Test.BadHorizonSink do
            use AshReplicant.Sink,
              #{base}
              slot_name: "bad_horizon_slot",
              message_routes: [{"outbox", AshReplicant.Test.Messages.Outbox, :record}],
              recovery_horizon: #{inspect(bad)}
          end
          """)
        end
      end
    end

    test "the baked config carries recovery_horizon normalized to seconds" do
      config = Fixtures.Sink.__ash_replicant_config__()

      assert is_integer(config.recovery_horizon) and config.recovery_horizon > 0
    end

    test "min_route_retention walks the manifest's message protections" do
      {:ok, manifest} =
        manifest_for([
          {"outbox", Fixtures.Outbox, :record},
          {"transient", Fixtures.TransientOutbox, :record}
        ])

      # The transient probe declares one second — the binding floor.
      assert {:ok, 1} = AshReplicant.Horizon.min_route_retention(manifest)
    end

    test "classify_retention compares the floor against the declared horizon" do
      assert :ok = AshReplicant.Horizon.classify_retention(86_400, 3_600)
      assert :ok = AshReplicant.Horizon.classify_retention(3_600, 3_600)

      assert {:error, :retention_below_recovery_horizon} =
               AshReplicant.Horizon.classify_retention(3_599, 3_600)
    end
  end
end
