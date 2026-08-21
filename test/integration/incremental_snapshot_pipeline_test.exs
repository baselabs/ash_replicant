defmodule AshReplicant.Test.IncrementalPipelineDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.IncrementalPipelineOrder
  end
end

defmodule AshReplicant.Test.IncrementalPipelineOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.IncrementalPipelineDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "repl_incremental_mirror_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("repl_incremental_src_orders")
    snapshot_provenance(true)
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
    attribute :replica_fingerprint, :binary, public?: false, writable?: false
    attribute :replica_seen_attempt, :binary, public?: false, writable?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :replicant_mark_seen do
      public? false
      accept []
      require_atomic? false
      change AshReplicant.Snapshot.MarkSeen
    end

    destroy :replicant_retire_unseen do
      public? false
    end
  end
end

defmodule AshReplicant.IncrementalSnapshotPipelineSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.IncrementalPipelineDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "incremental_snapshot_pipeline_slot"
end

defmodule AshReplicant.IncrementalSnapshotPipelineTest do
  @moduledoc """
  The fetched Replicant 1.2.2 incremental lifecycle driven end to end against
  live PostgreSQL. The durable token is decoded through Replicant's public
  artifact, so direct callback fixtures cannot substitute for this proof.
  """

  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 120_000

  alias AshReplicant.Snapshot.State
  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "incremental_snapshot_pipeline_slot"
  @publication "repl_incremental_snapshot_pub"
  @source "repl_incremental_src_orders"
  @target "repl_incremental_mirror_orders"

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.drop_slot!(@slot)
    q!("DROP PUBLICATION IF EXISTS #{@publication}")
    q!("DROP TABLE IF EXISTS #{@source}")
    q!("DROP TABLE IF EXISTS #{@target}")
    q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    q!("CREATE TABLE #{@source} (id text primary key, note text)")
    q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@source}")

    q!("""
    CREATE TABLE #{@target} (
      id text primary key,
      note text,
      replica_fingerprint bytea,
      replica_seen_attempt bytea
    )
    """)

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      q!("DROP PUBLICATION IF EXISTS #{@publication}")
      q!("DROP TABLE IF EXISTS #{@source}")
      q!("DROP TABLE IF EXISTS #{@target}")
    end)

    :ok
  end

  test "real incremental callbacks persist a valid complete token then hand off to stream" do
    q!("""
    INSERT INTO #{@source} (id, note)
    SELECT g::text, 'seed-' || g::text FROM generate_series(1, 9) g
    """)

    assert {:ok, _pid} =
             AshReplicant.start_link(
               sink: AshReplicant.IncrementalSnapshotPipelineSink,
               connection: Marquee.conn(),
               publication: @publication,
               source_identity: Marquee.source_identity(),
               snapshot: [mode: :incremental, chunk_rows: 2, max_pending_chunks: 2]
             )

    PG.wait_until(fn -> target_count() == 9 and complete_checkpoint?() end, 1_200)

    [[progress, encoded_state, pre_stream_lsn]] =
      q!(
        "SELECT snapshot_progress, snapshot_state, commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [@slot]
      ).rows

    assert is_nil(pre_stream_lsn),
           "no stream watermark may commit before the snapshot hands off"

    assert {:ok, %Replicant.SnapshotProgress{complete?: true}} =
             Replicant.SnapshotProgress.decode(progress)

    keys = Application.fetch_env!(:ash_replicant, :snapshot_provenance_keys)

    assert {:ok,
            %State{
              mode: :incremental,
              status: :complete,
              progress_token_hash: progress_hash,
              completed_token_hash: token_hash,
              next_ordinal: 9
            }} = State.decode(encoded_state, keys)

    assert progress_hash == :crypto.hash(:sha256, progress)
    assert token_hash == :crypto.hash(:sha256, progress)

    q!("UPDATE #{@source} SET note = 'streamed' WHERE id = '9'")

    PG.wait_until(fn ->
      q!("SELECT note FROM #{@target} WHERE id = '9'").rows == [["streamed"]]
    end)

    assert [[commit_lsn]] =
             q!(
               "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
               [@slot]
             ).rows

    assert is_integer(commit_lsn) and commit_lsn > 0
    assert complete_checkpoint?()
  end

  test "slot-created crash before the first chunk resumes the sink-owned pending backfill" do
    q!("""
    INSERT INTO #{@source} (id, note)
    SELECT g::text, 'seed-' || g::text FROM generate_series(1, 500) g
    """)

    test_pid = self()
    handler = {__MODULE__, :crash_before_reader, make_ref()}

    :telemetry.attach(
      handler,
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _metadata, _config ->
        :telemetry.detach(handler)
        send(test_pid, {:crashed_before_reader, self()})
        Process.exit(self(), :kill)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _pid} =
             AshReplicant.start_link(
               sink: AshReplicant.IncrementalSnapshotPipelineSink,
               connection: Marquee.conn(),
               publication: @publication,
               source_identity: Marquee.source_identity(),
               snapshot: [mode: :incremental, chunk_rows: 25, max_pending_chunks: 2]
             )

    assert_receive {:crashed_before_reader, crashed_connection}, 15_000

    monitor = Process.monitor(crashed_connection)
    assert_receive {:DOWN, ^monitor, :process, ^crashed_connection, _reason}, 5_000
    refute Process.alive?(crashed_connection)

    PG.wait_until(fn -> target_count() == 500 and complete_checkpoint?() end, 1_500)

    assert q!("SELECT id, note FROM #{@target} ORDER BY id").rows ==
             q!("SELECT id, note FROM #{@source} ORDER BY id").rows
  end

  defp complete_checkpoint? do
    case q!(
           "SELECT snapshot_progress, snapshot_state FROM ash_replicant_checkpoints WHERE slot_name = $1",
           [@slot]
         ).rows do
      [[progress, encoded_state]] when is_binary(progress) and is_binary(encoded_state) ->
        keys = Application.fetch_env!(:ash_replicant, :snapshot_provenance_keys)

        match?(
          {:ok, %Replicant.SnapshotProgress{complete?: true}},
          Replicant.SnapshotProgress.decode(progress)
        ) and
          match?(
            {:ok, %State{mode: :incremental, status: :complete}},
            State.decode(encoded_state, keys)
          )

      _other ->
        false
    end
  end

  defp target_count, do: q!("SELECT count(*) FROM #{@target}").rows |> hd() |> hd()
  defp q!(sql, params \\ []), do: Marquee.q!(sql, params)
end
