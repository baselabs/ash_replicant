defmodule AshReplicant.StartLinkTest do
  use ExUnit.Case, async: false

  # The unreachable-port fixtures (port 1) deliberately let Postgrex fail to
  # connect and RETRY — its protocol-level [error] logs are expected test
  # behavior, not uncontrolled errors, but they match the structural
  # battery's no-error gate. Capture them (shown only on failure).
  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias AshReplicant.Destination.Generation
  alias AshReplicant.Test.DestinationFixtures

  defmodule DupSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.DuplicateDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "dup_slot"
  end

  defmodule ValidSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "valid_slot"
  end

  defmodule LeaseSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "lease_slot"
  end

  @source_identity [system_identifier: "741852963", database: "postgres"]

  defp start_opts(extra \\ []) do
    Keyword.merge(
      [
        sink: ValidSink,
        connection: [
          hostname: "127.0.0.1",
          port: 1,
          username: "postgres",
          database: "postgres"
        ],
        publication: "valid_pub",
        source_identity: @source_identity,
        go_forward_only: true
      ],
      extra
    )
  end

  setup do
    for slot <- ["valid_slot", "lease_slot", "runtime_drift_slot"] do
      AshReplicant.stop_supervised(slot)
      :persistent_term.erase({AshReplicant, slot})
    end

    on_exit(fn ->
      for slot <- ["valid_slot", "lease_slot", "runtime_drift_slot"] do
        AshReplicant.stop_supervised(slot)
        :persistent_term.erase({AshReplicant, slot})
      end

      :persistent_term.erase({LeaseSink, :observer})
    end)

    :ok
  end

  test "a duplicate {schema,table} across the sink's domains fails closed before starting a pipeline" do
    assert {:error, {:duplicate_source, {"public", "dup_orders"}}} =
             AshReplicant.start_link(
               sink: DupSink,
               connection: [
                 hostname: "localhost",
                 port: 5599,
                 username: "postgres",
                 database: "postgres"
               ],
               publication: "dup_pub",
               source_identity: @source_identity
             )

    # fail-closed: no index cached (slot_name is baked in DupSink), no pipeline.
    assert :persistent_term.get({AshReplicant, "dup_slot"}, :none) == :none
  end

  test "a rejected Replicant configuration leaves no resolver generation cached" do
    result =
      AshReplicant.start_link(
        sink: ValidSink,
        connection: [
          hostname: "localhost",
          port: 5599,
          username: "postgres",
          database: "postgres"
        ],
        publication: "invalid publication with spaces!",
        source_identity: @source_identity
      )

    assert result == {:error, :invalid_identifier}
    assert :persistent_term.get({AshReplicant, "valid_slot"}, :none) == :none
  end

  test "a concurrent duplicate start cannot replace or erase the winner generation" do
    capture_log(fn ->
      [first, second] =
        for _ <- 1..2 do
          Task.async(fn -> AshReplicant.start_link(start_opts()) end)
        end

      # Two full activation chains against the deliberately-unreachable port
      # can exceed any fixed await under battery load — this test flaked at
      # the 5s default (2026-08-15) and once more at 15s under the no-DB
      # battery; the race under test is the START GATE (the return-value
      # asserts below fire the moment both tasks return), so the ceiling only
      # bounds waiting, never the outcome. 60s.
      results = [Task.await(first, 60_000), Task.await(second, 60_000)]

      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _pid}, &1))
      assert [duplicate] = Enum.reject(results, &match?({:ok, _pid}, &1))
      assert duplicate == {:error, :slot_already_active}
      assert Process.alive?(winner)

      generation = :persistent_term.get({AshReplicant, "valid_slot"}, :none)

      assert %Generation{
               reference: generation_ref,
               sink: ValidSink,
               sink_config: sink_config,
               sink_config_digest: config_digest,
               resolver_index: index,
               manifest_digest: manifest_digest,
               code_modules: code_modules,
               code_fingerprint: code_fingerprint,
               dynamic_repo: AshReplicant.TestRepo
             } = generation

      assert is_reference(generation_ref)
      assert sink_config == ValidSink.__ash_replicant_config__()
      assert byte_size(config_digest) == 32
      assert byte_size(manifest_digest) == 32
      assert ValidSink in code_modules
      assert byte_size(code_fingerprint) == 32
      assert map_size(index) >= 1

      Process.sleep(25)
      assert :persistent_term.get({AshReplicant, "valid_slot"}) == generation
      assert :ok = AshReplicant.stop_supervised("valid_slot")
    end)
  end

  describe "checkpoint operator functions (validation + lease refusals)" do
    test "adopt_checkpoint validates its arguments value-free" do
      identity = [system_identifier: "741852963", database: "postgres"]

      for bad <- [-1, "x", 1.5] do
        assert {:error, %AshReplicant.Error{reason: :checkpoint_adopt_invalid}} =
                 AshReplicant.adopt_checkpoint(ValidSink, identity, bad)
      end

      for bad_identity <- [
            nil,
            [],
            [system_identifier: "", database: "postgres"],
            [system_identifier: "1"]
          ] do
        assert {:error, _} = AshReplicant.adopt_checkpoint(ValidSink, bad_identity, 5)
      end

      assert {:error, %AshReplicant.Error{reason: :checkpoint_adopt_invalid}} =
               AshReplicant.adopt_checkpoint(:not_a_sink, identity, 5)
    end

    test "acknowledge_checkpoint_timeline validates the timeline value" do
      identity = [system_identifier: "741852963", database: "postgres"]

      for bad <- [-1, "x", nil] do
        assert {:error, %AshReplicant.Error{reason: :checkpoint_adopt_invalid}} =
                 AshReplicant.acknowledge_checkpoint_timeline(ValidSink, identity, bad)
      end
    end

    test "operator functions refuse a live slot (offline-only)" do
      identity = [system_identifier: "741852963", database: "postgres"]

      capture_log(fn ->
        assert {:ok, _pid} = AshReplicant.start_link(start_opts())

        assert {:error, %AshReplicant.Error{op: :slot_already_active}} =
                 AshReplicant.adopt_checkpoint(ValidSink, identity, 5)

        assert {:error, %AshReplicant.Error{op: :slot_already_active}} =
                 AshReplicant.reset_checkpoint(ValidSink, identity)

        assert {:error, %AshReplicant.Error{op: :slot_already_active}} =
                 AshReplicant.acknowledge_checkpoint_timeline(ValidSink, identity, 1)

        assert :ok = AshReplicant.stop_supervised("valid_slot")
      end)
    end
  end

  test "source identity is required and compared without returning values" do
    assert {:error, :source_identity_required} =
             AshReplicant.start_link(Keyword.delete(start_opts(), :source_identity))

    for identity <- [
          nil,
          [],
          [system_identifier: "", database: "postgres"],
          [system_identifier: "1"]
        ] do
      assert {:error, :source_identity_required} =
               AshReplicant.start_link(start_opts(source_identity: identity))
    end

    log =
      capture_log(fn ->
        assert {:ok, _pid} = AshReplicant.start_link(start_opts())
        assert function_exported?(ValidSink, :handle_session_identity, 2)

        context = %{slot_name: "valid_slot", publication: ["valid_pub"]}

        # The accepted path now BINDS the checkpoint row (B2) — without a live
        # DB it fails closed into a value-free error; the accepted-path :ok
        # proof lives in the integration marquees (checkpoint_binding_test).
        assert match?(
                 {:error, %AshReplicant.Error{}},
                 ValidSink.handle_session_identity(
                   %Replicant.SessionIdentity{
                     system_identifier: "741852963",
                     timeline_id: 1,
                     current_lsn: 0,
                     database: "postgres"
                   },
                   context
                 )
               )

        assert {:error, :source_identity_mismatch} =
                 ValidSink.handle_session_identity(
                   %Replicant.SessionIdentity{
                     system_identifier: "sentinel-system-value",
                     timeline_id: 1,
                     current_lsn: 0,
                     database: "sentinel-database-value"
                   },
                   context
                 )

        for {identity, mismatched_context} <- [
              {%Replicant.SessionIdentity{
                 system_identifier: "sentinel-system-value",
                 timeline_id: 1,
                 current_lsn: 0,
                 database: "postgres"
               }, context},
              {%Replicant.SessionIdentity{
                 system_identifier: "741852963",
                 timeline_id: 1,
                 current_lsn: 0,
                 database: "sentinel-database-value"
               }, context},
              {%Replicant.SessionIdentity{
                 system_identifier: "741852963",
                 timeline_id: 1,
                 current_lsn: 0,
                 database: "postgres"
               }, %{context | slot_name: "wrong-slot"}},
              {%Replicant.SessionIdentity{
                 system_identifier: "741852963",
                 timeline_id: 1,
                 current_lsn: 0,
                 database: "postgres"
               }, %{context | publication: ["wrong-publication"]}}
            ] do
          assert {:error, :source_identity_mismatch} =
                   ValidSink.handle_session_identity(identity, mismatched_context)
        end

        assert :ok = AshReplicant.stop_supervised("valid_slot")
        assert :none == :persistent_term.get({AshReplicant, "valid_slot"}, :none)
      end)

    refute log =~ "sentinel-system-value"
    refute log =~ "sentinel-database-value"
  end

  test "the generated identity guard cannot be overridden by a host sink" do
    log =
      capture_log(fn ->
        [{sink, _bytecode}] =
          Code.compile_string("""
          defmodule AshReplicant.Test.OverrideIdentitySink do
            use AshReplicant.Sink,
              repo: AshReplicant.TestRepo,
              domains: [AshReplicant.Test.Domain],
              checkpoint_resource: AshReplicant.Test.Checkpoint,
              slot_name: "override_identity_slot"

            @identity_overridable Module.overridable?(__MODULE__, {:handle_session_identity, 2})
            def identity_overridable?, do: @identity_overridable
          end
          """)

        refute sink.identity_overridable?()

        assert {:ok, _pid} = AshReplicant.start_link(start_opts(sink: sink))

        assert {:error, :source_identity_mismatch} =
                 sink.handle_session_identity(
                   %Replicant.SessionIdentity{
                     system_identifier: "wrong",
                     database: "wrong",
                     timeline_id: 1,
                     current_lsn: 0
                   },
                   %{slot_name: "override_identity_slot", publication: ["valid_pub"]}
                 )

        assert :ok = AshReplicant.stop_supervised("override_identity_slot")
      end)

    refute log =~ "wrong"
  end

  test "missing sink fails structurally without exposing connection options" do
    sentinel = "sentinel-connection-password"

    log =
      capture_log(fn ->
        assert {:error, :sink_required} =
                 AshReplicant.start_link(
                   connection: [password: sentinel],
                   publication: "valid_pub",
                   source_identity: @source_identity
                 )
      end)

    refute log =~ sentinel
  end

  test "generation cleanup only erases the generation that lost activation" do
    key = {AshReplicant, "valid_slot"}
    loser = make_ref()

    # Stop the PIPELINE inside the capture window (not stop_supervised — this
    # test needs the generation alive after): the port-1 connection retries with
    # backoff, and an error logged after the window closes trips the structural
    # gate's uncontrolled-error grep.
    capture_log(fn ->
      assert {:ok, _pid} = AshReplicant.start_link(start_opts())
      assert :ok = Replicant.stop("valid_slot")
    end)

    assert %Generation{reference: winner} = runtime = :persistent_term.get(key)

    assert :ok = AshReplicant.erase_generation("valid_slot", loser)
    assert runtime == :persistent_term.get(key)
    assert :ok = AshReplicant.erase_generation("valid_slot", winner)
    assert :none == :persistent_term.get(key, :none)
  end

  test "transport-only Replicant options are forwarded instead of silently discarded" do
    for {key, bad_value} <- [
          streaming: :invalid,
          max_inflight_lag: -1,
          max_command_retries: -1,
          failover: :invalid
        ] do
      assert {:error, :config_invalid} = AshReplicant.start_link(start_opts([{key, bad_value}]))
      assert :persistent_term.get({AshReplicant, "valid_slot"}, :none) == :none
    end

    capture_log(fn ->
      assert {:ok, _pid} =
               AshReplicant.start_link(
                 start_opts(
                   streaming: [max_concurrent_txns: 2],
                   max_inflight_lag: 1_024,
                   max_command_retries: 2,
                   failover: false
                 )
               )

      assert :ok = AshReplicant.stop_supervised("valid_slot")

      # These modes are owned by Replicant but unsupported by AshReplicant. Bad
      # values would be rejected if forwarded, so a successful start proves the
      # adapter withheld them.
      assert {:ok, _pid} =
               AshReplicant.start_link(start_opts(messages: :invalid, batch_delivery: :invalid))

      assert :ok = AshReplicant.stop_supervised("valid_slot")
    end)
  end

  test "incremental snapshot remains guarded and rejected starts leave no cache" do
    opts =
      start_opts(
        go_forward_only: false,
        snapshot: [mode: :incremental, chunk_rows: 10, max_pending_chunks: 2]
      )

    assert {:error, :snapshot_unsupported} = AshReplicant.start_link(opts)
    assert :persistent_term.get({AshReplicant, "valid_slot"}, :none) == :none

    refute function_exported?(ValidSink, :handle_batch, 1)
    refute function_exported?(ValidSink, :handle_message, 2)
    refute function_exported?(ValidSink, :snapshot_progress, 0)
  end

  test "a foreign effective dynamic Repo is rejected before activation state" do
    previous = AshReplicant.TestRepo.put_dynamic_repo(DestinationFixtures.ForeignRepo)

    try do
      assert {:error, {:invalid_destination_config, :effective_repo}} =
               AshReplicant.start_link(start_opts())

      assert :none == :persistent_term.get({AshReplicant, "valid_slot"}, :none)
    after
      AshReplicant.TestRepo.put_dynamic_repo(previous)
    end
  end

  test "a foreign effective dynamic Repo is rejected at callback entry" do
    capture_log(fn ->
      assert {:ok, _pid} = AshReplicant.start_link(start_opts())
      # Pipeline-only stop inside the window (the callback below needs the
      # generation alive); keeps the retrying port-1 connection from logging
      # past the window into the structural gate's uncontrolled-error grep.
      assert :ok = Replicant.stop("valid_slot")
    end)

    task =
      Task.async(fn ->
        previous =
          AshReplicant.TestRepo.put_dynamic_repo(DestinationFixtures.ForeignRepo)

        try do
          ValidSink.checkpoint()
        after
          AshReplicant.TestRepo.put_dynamic_repo(previous)
        end
      end)

    assert {:error, %AshReplicant.Error{reason: :config_invalid, op: :callback}} =
             Task.await(task, 15_000)
  end

  test "stop waits for a mutating callback to leave the destination lease" do
    observer = self()

    capture_log(fn ->
      assert {:ok, _pid} = AshReplicant.start_link(start_opts(sink: LeaseSink))
      # Pipeline-only stop inside the window; the lease callback below runs
      # against the generation, and a surviving port-1 connection would log its
      # retry error past the window (structural-gate flake).
      assert :ok = Replicant.stop("lease_slot")
    end)

    callback =
      Task.async(fn ->
        result =
          AshReplicant.run_callback("lease_slot", LeaseSink, :mutate, fn config ->
            send(observer, {:inside_callback, self(), config.dynamic_repo})

            receive do
              :release_callback -> {:ok, 777}
            end
          end)

        {result, AshReplicant.TestRepo.get_dynamic_repo()}
      end)

    # Callback entry re-validates the admitted generation: a manifest walk plus
    # a bytecode fingerprint of the ~56-module closure (file reads through the
    # serialized code server). ~4ms warm; observed >1s once under battery IO
    # load (coincident with a substrate checkpoint), so budget for load — the
    # assert still proves entry + dynamic repo, which is its actual subject.
    assert_receive {:inside_callback, callback_pid, AshReplicant.TestRepo}, 15_000

    stopper = Task.async(fn -> AshReplicant.stop_supervised("lease_slot") end)
    # Negative window: the lease is HELD, so the stopper must not finish. Load
    # only makes a held lease more likely to still be held — keep it tight.
    assert Task.yield(stopper, 50) == nil

    send(callback_pid, :release_callback)
    assert {{:ok, 777}, AshReplicant.TestRepo} = Task.await(callback, 15_000)
    assert :ok = Task.await(stopper, 15_000)
    assert :none == :persistent_term.get({AshReplicant, "lease_slot"}, :none)
  end

  test "a hot-loaded sink config is never merged into the admitted generation" do
    module = AshReplicant.Test.RuntimeDriftSink
    previous_ignore = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      compile_runtime_sink(module, [AshReplicant.Test.Domain])

      capture_log(fn ->
        assert {:ok, _pid} = AshReplicant.start_link(start_opts(sink: module))
        # Pipeline-only stop inside the window (generation must survive for the
        # drift assert below; the retrying port-1 connection must not log past
        # the window into the structural gate's grep).
        assert :ok = Replicant.stop("runtime_drift_slot")
      end)

      compile_runtime_sink(module, [DestinationFixtures.NamedDefaultDomain])

      handle_schema_change = Function.capture(module, :handle_schema_change, 2)

      assert {:error, %AshReplicant.Error{reason: :config_invalid}} =
               handle_schema_change.(
                 %Replicant.SchemaChange{
                   kind: :additive,
                   change: :column_added,
                   schema: "public",
                   table: "orders",
                   detail: "structural"
                 },
                 %{}
               )

      assert %Generation{sink_config: admitted_config} =
               :persistent_term.get({AshReplicant, "runtime_drift_slot"})

      assert admitted_config.domains == [AshReplicant.Test.Domain]

      sink_config = Function.capture(module, :__ash_replicant_config__, 0)

      assert sink_config.().domains == [
               DestinationFixtures.NamedDefaultDomain
             ]

      assert :ok = AshReplicant.stop_supervised("runtime_drift_slot")
    after
      Code.put_compiler_option(:ignore_module_conflict, previous_ignore)
      :persistent_term.erase({AshReplicant, "runtime_drift_slot"})
      :code.purge(module)
      :code.delete(module)
    end
  end

  test "hot-loaded code with unchanged sink config is rejected by the fingerprint" do
    module = AshReplicant.Test.RuntimeDriftSink
    previous_ignore = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      compile_runtime_sink(module, [AshReplicant.Test.Domain], :first)

      capture_log(fn ->
        assert {:ok, _pid} = AshReplicant.start_link(start_opts(sink: module))
        # Pipeline-only stop inside the window (generation must survive for the
        # fingerprint-drift assert below; same structural-gate flake guard).
        assert :ok = Replicant.stop("runtime_drift_slot")
      end)

      compile_runtime_sink(module, [AshReplicant.Test.Domain], :second)
      handle_schema_change = Function.capture(module, :handle_schema_change, 2)

      assert {:error, %AshReplicant.Error{reason: :config_invalid}} =
               handle_schema_change.(
                 %Replicant.SchemaChange{
                   kind: :additive,
                   change: :column_added,
                   schema: "public",
                   table: "orders",
                   detail: "structural"
                 },
                 %{}
               )

      assert :ok = AshReplicant.stop_supervised("runtime_drift_slot")
    after
      Code.put_compiler_option(:ignore_module_conflict, previous_ignore)
      :persistent_term.erase({AshReplicant, "runtime_drift_slot"})
      :code.purge(module)
      :code.delete(module)
    end
  end

  test "all generated public callbacks are final and no effect override hook exists" do
    [{sink, _bytecode}] =
      Code.compile_string("""
      defmodule AshReplicant.Test.FinalCallbacksSink do
        use AshReplicant.Sink,
          repo: AshReplicant.TestRepo,
          domains: [AshReplicant.Test.Domain],
          checkpoint_resource: AshReplicant.Test.Checkpoint,
          slot_name: "final_callbacks_slot"

        @callback_overrides for callback <- #{inspect(final_callbacks())},
                               into: %{},
                               do: {callback, Module.overridable?(__MODULE__, callback)}
        @effect_hook_defined Module.defines?(__MODULE__, {:__ash_replicant_effect__, 3})

        def callback_overrides, do: @callback_overrides
        def effect_hook_defined?, do: @effect_hook_defined
      end
      """)

    assert Enum.all?(sink.callback_overrides(), fn {_callback, overridable?} ->
             not overridable?
           end)

    refute sink.effect_hook_defined?()
  end

  test "attempting to redefine any generated callback fails compilation" do
    for {{name, arity}, definition} <- callback_definitions() do
      module = Module.concat(AshReplicant.Test, "Final#{name}#{arity}Sink")

      assert_raise CompileError, ~r/AshReplicant sink callback #{name}\/#{arity} is final/, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use AshReplicant.Sink,
            repo: AshReplicant.TestRepo,
            domains: [AshReplicant.Test.Domain],
            checkpoint_resource: AshReplicant.Test.Checkpoint,
            slot_name: "final_#{name}_#{arity}_slot"

          #{definition}
        end
        """)
      end
    end
  end

  defp final_callbacks do
    [
      handle_session_identity: 2,
      checkpoint: 0,
      handle_transaction: 1,
      sink_kind: 0,
      handle_schema_change: 2,
      handle_snapshot: 2,
      handle_snapshot_complete: 1
    ]
  end

  defp callback_definitions do
    %{
      {:handle_session_identity, 2} =>
        "def handle_session_identity(_identity, _context), do: :ok",
      {:checkpoint, 0} => "def checkpoint, do: {:ok, nil}",
      {:handle_transaction, 1} => "def handle_transaction(_transaction), do: {:ok, 0}",
      {:sink_kind, 0} => "def sink_kind, do: :append_log",
      {:handle_schema_change, 2} => "def handle_schema_change(_change, _context), do: :ok",
      {:handle_snapshot, 2} => "def handle_snapshot(_changes, _context), do: :ok",
      {:handle_snapshot_complete, 1} => "def handle_snapshot_complete(lsn), do: {:ok, lsn}"
    }
  end

  defp compile_runtime_sink(module, domains, marker \\ :stable) do
    Code.compile_string("""
    defmodule #{inspect(module)} do
      use AshReplicant.Sink,
        repo: AshReplicant.TestRepo,
        domains: #{inspect(domains)},
        checkpoint_resource: AshReplicant.Test.Checkpoint,
        slot_name: "runtime_drift_slot"

      def runtime_marker, do: #{inspect(marker)}
    end
    """)
  end
end
