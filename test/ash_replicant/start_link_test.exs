defmodule AshReplicant.StartLinkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
    AshReplicant.stop_supervised("valid_slot")
    :persistent_term.erase({AshReplicant, "valid_slot"})

    on_exit(fn ->
      AshReplicant.stop_supervised("valid_slot")
      :persistent_term.erase({AshReplicant, "valid_slot"})
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

      results = [Task.await(first), Task.await(second)]

      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _pid}, &1))
      assert [duplicate] = Enum.reject(results, &match?({:ok, _pid}, &1))
      assert duplicate == {:error, :slot_already_active}
      assert Process.alive?(winner)

      generation = :persistent_term.get({AshReplicant, "valid_slot"}, :none)
      assert %{generation: generation_ref, resolver_index: index} = generation
      assert is_reference(generation_ref)
      assert map_size(index) >= 1

      Process.sleep(25)
      assert :persistent_term.get({AshReplicant, "valid_slot"}) == generation
      assert :ok = AshReplicant.stop_supervised("valid_slot")
    end)
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

        assert :ok =
                 ValidSink.handle_session_identity(
                   %Replicant.SessionIdentity{
                     system_identifier: "741852963",
                     timeline_id: 1,
                     current_lsn: 0,
                     database: "postgres"
                   },
                   context
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
    winner = make_ref()
    loser = make_ref()
    runtime = %{generation: winner, resolver_index: %{winner: true}}
    :persistent_term.put(key, runtime)

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
end
