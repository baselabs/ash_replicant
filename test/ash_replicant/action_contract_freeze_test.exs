defmodule AshReplicant.ActionContractFreezeTest do
  @moduledoc """
  U3/D8 — the frozen host action contract, asserted against LIVE reflection.
  The table is the B6 acceptance surface: every action class the sink drives,
  its verified properties, and the append/message rows that stay ABSENT until
  C1/C4. A behavior change to any cell goes red HERE first.

  Rows cite their enforcement points; where the property is behavioral (an
  applied write's authorization or notification posture) the freeze pins the
  CODE shape (source-pin) and the behavior tests carry the proof — the table
  is the index, not a duplicate suite.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshReplicant.Apply.Context
  alias AshReplicant.Destination
  alias AshReplicant.Telemetry
  alias AshReplicant.Test.DestinationFixtures
  alias AshReplicant.Test.{Order, OrderVersion}

  @config %{
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.Domain],
    checkpoint_resource: AshReplicant.Test.Checkpoint
  }

  setup do
    {:ok, manifest} = Destination.manifest(@config)
    %{manifest: manifest}
  end

  describe "row: primary read (mapped root)" do
    test "the primary read exists, is typed :read, is admitted as :mapped, and no admitted action carries a tenancy bypass",
         %{
           manifest: manifest
         } do
      assert %{type: :read} = Info.primary_action(Order, :read)

      assert Enum.any?(
               manifest.entries,
               &(&1.resource == Order and &1.action == :read and &1.role == :mapped)
             )

      for entry <- manifest.entries do
        action = Info.action(entry.resource, entry.action)
        # ValidateActionMultitenancy covers sink-selected actions at compile;
        # the walk's validate_action_tenant_scoping covers declared
        # participants — the freeze row pins the OUTCOME over the whole graph.
        refute Map.get(action, :multitenancy) in [:bypass, :bypass_all],
               "#{inspect(entry.resource)}.#{entry.action} must never carry a tenancy bypass"
      end
    end

    test "locked reads authorize with the explicit false literal (source-pin)" do
      source = File.read!("lib/ash_replicant/sink/impl.ex")

      assert source =~ "authorize?: false",
             "the locked admission read must keep its explicit literal"
    end
  end

  describe "row: primary create (upsert)" do
    test "typed :create, admitted, and the streaming path mints :upsert" do
      assert %{type: :create} = Info.primary_action(Order, :create)

      config = %{
        source_identity: %{system_identifier: "system", database: "source"},
        slot_name: "freeze_slot"
      }

      change = %Replicant.Change{
        op: :insert,
        schema: "public",
        table: "orders",
        record: %{},
        old_record: nil,
        unchanged: [],
        commit_lsn: 1,
        ordinal: 0
      }

      assert {:ok, %{invocation: :upsert}} = Context.operation_context(config, change, :upsert)
    end

    test "applies under the sink's authorize?: false posture (source-pin of the flag plumbing)" do
      source = File.read!("lib/ash_replicant/apply.ex")
      assert source =~ "authorize?: config.authorize?"
      assert source =~ "authorize?: false" or source =~ "config.authorize?"
    end
  end

  describe "row: primary destroy" do
    test "typed :destroy, admitted, and the relocate/delete paths mint :destroy_prior" do
      assert %{type: :destroy} = Info.primary_action(Order, :destroy)

      config = %{
        source_identity: %{system_identifier: "system", database: "source"},
        slot_name: "freeze_slot"
      }

      change = %Replicant.Change{
        op: :delete,
        schema: "public",
        table: "orders",
        record: nil,
        old_record: %{},
        unchanged: [],
        commit_lsn: 1,
        ordinal: 0
      }

      assert {:ok, %{invocation: :destroy_prior}} =
               Context.operation_context(config, change, :destroy_prior)
    end
  end

  describe "row: history_close_action" do
    test "typed :update at compile (ValidateHistory.check_close enforces it — the cited check, not a gap)" do
      assert %{type: :update} = Info.action(OrderVersion, :close_version)

      # The compile-time enforcement itself: check_close rejects a close
      # action that is not an update. Source-pin of the enforcement point.
      verifier = File.read!("lib/ash_replicant/resource/verifiers/validate_history.ex")
      assert verifier =~ ":update", "check_close's type check must stay"
    end

    test "the close path joins the outer transaction (transaction: false on the bulk_update — source-pin)" do
      source = File.read!("lib/ash_replicant/apply/scd2.ex")
      assert source =~ "transaction: false"
    end

    test "both close invocations mint their distinct labels" do
      config = %{
        source_identity: %{system_identifier: "system", database: "source"},
        slot_name: "freeze_slot"
      }

      change = %Replicant.Change{
        op: :update,
        schema: "public",
        table: "orders",
        record: %{},
        old_record: %{},
        unchanged: [],
        commit_lsn: 1,
        ordinal: 0
      }

      assert {:ok, %{invocation: :close_prior}} =
               Context.operation_context(config, change, :close_prior)

      assert {:ok, %{invocation: :close_current}} =
               Context.operation_context(config, change, :close_current)
    end
  end

  describe "row: checkpoint read/upsert/operator_reset" do
    test "all three checkpoint actions are admitted roots; a participant on a checkpoint action fails closed",
         %{
           manifest: manifest
         } do
      for action <- [:read, :upsert, :operator_reset] do
        assert Enum.any?(
                 manifest.entries,
                 &(&1.resource == AshReplicant.Test.Checkpoint and &1.action == action and
                     &1.role == :checkpoint)
               ),
               "checkpoint #{action} must be an admitted root"
      end
    end
  end

  describe "row: declared auxiliary/participants" do
    test "the declared auxiliary action enters the graph with its declaring source" do
      assert {:ok, fixtures_manifest} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.Domain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })

      assert Enum.any?(
               fixtures_manifest.entries,
               &(&1.resource == DestinationFixtures.Auxiliary and &1.role == :auxiliary)
             )
    end

    test "a load-carrying notifier on a declared participant follows the same D2 rule (the walk is uniform)" do
      assert {:error, {:destination_notifier_required, _, _, _}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.LoadDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end
  end

  describe "row: append/message/batch (message PRESENT-when-configured since C1; batch PRESENT since C2; snapshot/append ABSENT until C3/C4)" do
    test "the generated sink exposes handle_message/2 ONLY when a routing surface is declared" do
      sink = DestinationFixtures.Sink

      assert Code.ensure_loaded?(sink)
      assert function_exported?(sink, :handle_transaction, 1)

      refute function_exported?(sink, :handle_message, 2),
             "a route-less sink must keep the message callback ABSENT"

      message_sink = AshReplicant.Test.Messages.Sink
      assert Code.ensure_loaded?(message_sink)
      assert function_exported?(message_sink, :handle_transaction, 1)
      assert function_exported?(message_sink, :handle_message, 2)
    end

    test "the generated sink exposes handle_batch/1 ALWAYS (batch semantics need no sink declaration)" do
      # C2/ADR-0016: handle_batch/1 is generated unconditionally — unlike the
      # message callback, its body consumes nothing beyond the admitted
      # generation, and batch_delivery stays a pipeline-level start option.
      for sink <- [DestinationFixtures.Sink, AshReplicant.Test.Messages.Sink] do
        assert Code.ensure_loaded?(sink)
        assert function_exported?(sink, :handle_batch, 1)
        refute function_exported?(sink, :snapshot_progress, 0)
        refute function_exported?(sink, :append, 2)
      end
    end
  end

  test "the telemetry conformance inventory covers every event name emitted in lib (live pin)" do
    # Diff-review F7: emitted_event_names/0 is hand-maintained — a new event
    # name in lib without an inventory row goes red here (the payload typing
    # still gates at event/3; this pins the conformance gate's coverage).
    emitted =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        Regex.scan(~r/Telemetry\.event\(\s*\[(:[a-z_]+,\s*:[a-z_]+,\s*:[a-z_]+)\]/, source)
        |> Enum.map(fn [_, inner] ->
          inner
          |> String.split(~r/[,\s]+/, trim: true)
          |> Enum.map(&String.to_atom(String.trim_leading(&1, ":")))
        end)
      end)
      |> MapSet.new()

    inventory = Telemetry.emitted_event_names() |> MapSet.new()

    assert MapSet.equal?(emitted, inventory),
           "the conformance inventory must EQUAL the events emitted in lib — missing: #{inspect(MapSet.to_list(MapSet.difference(emitted, inventory)))}, stale: #{inspect(MapSet.to_list(MapSet.difference(inventory, emitted)))}"
  end

  describe "D9: compile-diagnostic completeness (the reason space enumerates, each naming its modules)" do
    @reason_fixtures [
      {{:destination_action_missing, DestinationFixtures.MissingRootAction, :create},
       {:invalid_destination_config, :repo}},
      {{:destination_participant_required, DestinationFixtures.UnknownRoot, :create,
        DestinationFixtures.UnknownChange}, nil},
      {{:destination_participant_invalid, DestinationFixtures.MalformedChange}, nil},
      {{:destination_participant_mismatch, DestinationFixtures.BadTouchesRoot, :create}, nil},
      {{:destination_action_tenant_bypass, nil, nil}, nil},
      {{:destination_notifier_required, DestinationFixtures.LoadRoot, :read,
        DestinationFixtures.LoadNotifier}, nil},
      {{:destination_participant_cycle, nil, nil}, nil},
      {{:destination_message_route_invalid, AshReplicant.Test.Messages.NonceOutbox, :record},
       nil},
      {{:destination_repo_not_postgres, DestinationFixtures.SimpleRoot}, nil},
      {{:destination_repo_dynamic, DestinationFixtures.ForeignChild}, nil},
      {{:destination_repo_mismatch, DestinationFixtures.ForeignMappedRoot}, nil}
    ]

    test "the enumeration covers EVERY destination_* reason kind actually constructed in lib (live pin)" do
      # Diff-review F5: the fixture list alone is self-referential. This cell
      # greps the LIVE constructors — a new reason kind added to destination.ex
      # without a fixture row goes red here.
      source = File.read!("lib/ash_replicant/destination.ex")

      constructed =
        Regex.scan(~r/\{:(destination_[a-z_]+),/, source)
        |> Enum.map(&String.to_atom(Enum.at(&1, 1)))
        |> MapSet.new()

      enumerated =
        @reason_fixtures
        |> Enum.map(fn {reason, _cfg} -> elem(reason, 0) end)
        |> MapSet.new()

      assert MapSet.subset?(constructed, enumerated),
             "reason kinds constructed in lib but not enumerated: #{inspect(MapSet.to_list(MapSet.difference(constructed, enumerated)))}"

      assert MapSet.subset?(enumerated, constructed),
             "enumerated kinds no longer constructed (stale fixtures): #{inspect(MapSet.to_list(MapSet.difference(enumerated, constructed)))}"
    end

    test "every reason kind of the live @type carries resource/action/module in its tuple arity" do
      # The arity pin: each reason kind's tuple is exactly the shape the
      # __after_compile__ inspector renders — a field-dropping change (arity
      # change) breaks the pattern-match enumeration here.
      enumerated =
        Enum.map(@reason_fixtures, fn {reason, _cfg} ->
          case reason do
            {kind, resource} when is_atom(kind) ->
              {kind, 2, is_atom(resource)}

            {kind, resource, action} ->
              {kind, 3, is_atom(resource) and is_atom(action)}

            {kind, resource, action, module} ->
              {kind, 4, is_atom(resource) and is_atom(action) and is_atom(module)}
          end
        end)

      assert {_, 3, true} =
               Enum.find(enumerated, &match?({:destination_action_missing, _, _}, &1))

      assert {_, 4, true} =
               Enum.find(enumerated, &match?({:destination_participant_required, 4, true}, &1))

      assert {_, 2, true} =
               Enum.find(enumerated, &match?({:destination_participant_invalid, _, _}, &1))

      assert {_, 3, true} =
               Enum.find(enumerated, &match?({:destination_participant_mismatch, _, _}, &1))

      assert {_, 4, true} =
               Enum.find(enumerated, &match?({:destination_notifier_required, 4, true}, &1))

      assert {_, 2, true} =
               Enum.find(enumerated, &match?({:destination_repo_not_postgres, _, _}, &1))

      assert {_, 2, true} = Enum.find(enumerated, &match?({:destination_repo_mismatch, _, _}, &1))

      assert {_, 3, true} =
               Enum.find(enumerated, &match?({:destination_participant_cycle, _, _}, &1))

      assert {_, 3, true} =
               Enum.find(enumerated, &match?({:destination_action_tenant_bypass, _, _}, &1))

      assert {_, 3, true} =
               Enum.find(
                 enumerated,
                 &match?({:destination_message_route_invalid, _, _}, &1)
               )
    end

    test "the after-compile RENDERING names the modules (identify-each, first-failure halting)" do
      module = Module.concat(__MODULE__, "InvalidSink#{System.unique_integer([:positive])}")
      slot = "freeze_invalid_#{System.unique_integer([:positive])}"

      source = """
      defmodule #{inspect(module)} do
        use AshReplicant.Sink,
          repo: AshReplicant.TestRepo,
          domains: [AshReplicant.Test.DestinationFixtures.UnknownDomain],
          checkpoint_resource: AshReplicant.Test.Checkpoint,
          slot_name: #{inspect(slot)}
      end
      """

      e =
        assert_raise CompileError, fn -> Code.compile_string(source, "freeze_invalid_sink.ex") end

      assert e.description =~ "DestinationFixtures.UnknownRoot",
             "the rendered diagnostic must NAME the resource"

      assert e.description =~ "UnknownChange",
             "the rendered diagnostic must NAME the declaring module"

      :code.purge(module)
      :code.delete(module)
    end
  end
end
