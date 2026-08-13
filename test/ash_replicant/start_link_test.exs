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

      assert :ok = AshReplicant.stop_supervised("valid_slot")
    end)
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
