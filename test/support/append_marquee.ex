defmodule AshReplicant.Test.AppendMarquee do
  @moduledoc """
  The LIVE append-log marquee (ADR-0018): its own source table, publication,
  event table and slots, so it never shares a resolver index or a checkpoint row
  with the state-mirror marquees.

  Tables are raw SQL (not `mix ash.codegen`) for the same reason every other
  integration marquee is: they are created and dropped per test module against
  a committing connection, outside the suite's sandbox.
  """

  alias AshReplicant.Test.Marquee
  alias AshReplicant.TestRepo
  alias Ecto.Adapters.SQL

  @src "repl_append_src"
  @noise "repl_append_noise"
  @events "repl_append_events"
  @pub "repl_append_pub"
  @stream_slot "append_stream_slot"
  @snapshot_slot "append_snapshot_slot"
  @batch_slot "append_batch_slot"

  def src, do: @src
  def noise_table, do: @noise
  def events_table, do: @events
  def publication, do: @pub
  def stream_slot, do: @stream_slot
  def snapshot_slot, do: @snapshot_slot
  def batch_slot, do: @batch_slot

  def q!(sql, params \\ []), do: SQL.query!(TestRepo, sql, params)

  def setup_schema! do
    q!("DROP PUBLICATION IF EXISTS #{@pub}")
    q!("DROP TABLE IF EXISTS #{@src}")
    q!("DROP TABLE IF EXISTS #{@noise}")
    q!("CREATE TABLE #{@src} (id text primary key, note text, body text)")
    q!("CREATE TABLE #{@noise} (id bigserial primary key, note text)")
    # A DELETE appends the admitted OLD record, and the log's whole value is
    # that the deleted payload is recorded — key-only old records would append
    # a delete of "something".
    q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    q!("CREATE PUBLICATION #{@pub} FOR TABLE #{@src}")

    q!("DROP TABLE IF EXISTS #{@events}")

    q!("""
    CREATE TABLE #{@events} (
      event_id uuid PRIMARY KEY,
      source_system_id text NOT NULL,
      source_database text NOT NULL,
      slot_name text NOT NULL,
      commit_lsn bigint NOT NULL,
      ordinal bigint NOT NULL,
      operation text NOT NULL,
      origin text NOT NULL,
      snapshot_attempt bytea,
      id text,
      note text,
      body text,
      message_prefix text,
      message_content bytea
    )
    """)

    # The defensive database constraint behind append-once (ADR-0018 §3). The
    # dedup-bypass mutation proof drives its absence.
    q!("""
    CREATE UNIQUE INDEX #{@events}_append_identity_index
    ON #{@events} (source_system_id, source_database, slot_name, commit_lsn, ordinal)
    """)

    :ok
  end

  def teardown_schema! do
    q!("DROP PUBLICATION IF EXISTS #{@pub}")
    q!("DROP TABLE IF EXISTS #{@src}")
    q!("DROP TABLE IF EXISTS #{@noise}")
    q!("DROP TABLE IF EXISTS #{@events}")
    :ok
  end

  @doc "The appended log, in delivery order, as `[operation, origin, id, note]` rows."
  def events do
    q!(
      "SELECT operation, origin, id, note FROM #{@events} " <>
        "ORDER BY commit_lsn ASC, ordinal ASC"
    ).rows
  end

  @doc "The appended identity tuples, in delivery order."
  def identities do
    q!(
      "SELECT source_system_id, source_database, slot_name, commit_lsn, ordinal " <>
        "FROM #{@events} ORDER BY commit_lsn ASC, ordinal ASC"
    ).rows
  end

  def message_events do
    q!(
      "SELECT operation, message_prefix, message_content, commit_lsn, ordinal, id " <>
        "FROM #{@events} ORDER BY commit_lsn ASC, ordinal ASC"
    ).rows
  end

  def event_count, do: q!("SELECT count(*) FROM #{@events}").rows |> hd() |> hd()

  def confirmed_flush(slot) do
    case q!(
           "SELECT confirmed_flush_lsn::text FROM pg_replication_slots WHERE slot_name = $1",
           [slot]
         ).rows do
      [[lsn]] when is_binary(lsn) -> Replicant.lsn_from_string(lsn)
      _other -> 0
    end
  end

  def advance_slot_to_current_wal!(slot) do
    q!(
      "SELECT end_lsn::text FROM pg_replication_slot_advance($1::name, pg_current_wal_lsn())",
      [slot]
    )
  end

  def snapshot_attempts do
    q!("SELECT DISTINCT snapshot_attempt FROM #{@events} WHERE origin = 'snapshot'").rows
  end

  @doc "The durable checkpoint row for a slot, or nil."
  def checkpoint(slot) do
    case q!(
           "SELECT commit_lsn, origin_floor FROM ash_replicant_checkpoints WHERE slot_name = $1",
           [slot]
         ) do
      %{rows: [[commit_lsn, origin_floor]]} ->
        %{commit_lsn: commit_lsn, origin_floor: origin_floor}

      _none ->
        nil
    end
  end

  def conn, do: Marquee.conn()
  def source_identity, do: Marquee.source_identity()
  def drop_slot!(slot), do: Marquee.drop_slot!(slot)

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.AppendMarquee.Event
    end
  end

  defmodule Event do
    @moduledoc "The live marquee's host-owned immutable append target."
    use Ash.Resource,
      domain: AshReplicant.Test.AppendMarquee.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "repl_append_events"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("repl_append_src")
      append_log(true)
      on_truncate(:append)
    end

    attributes do
      uuid_primary_key :event_id
      attribute :source_system_id, :string, allow_nil?: false, public?: true
      attribute :source_database, :string, allow_nil?: false, public?: true
      attribute :slot_name, :string, allow_nil?: false, public?: true
      attribute :commit_lsn, :integer, allow_nil?: false, public?: true
      attribute :ordinal, :integer, allow_nil?: false, public?: true
      attribute :operation, :string, allow_nil?: false, public?: true
      attribute :origin, :string, allow_nil?: false, public?: true
      attribute :snapshot_attempt, :binary, public?: true
      attribute :id, :string, public?: true
      attribute :note, :string, public?: true
      attribute :body, :string, public?: true
      attribute :message_prefix, :string, public?: true
      attribute :message_content, :binary, public?: true
    end

    identities do
      identity :append_identity, [
        :source_system_id,
        :source_database,
        :slot_name,
        :commit_lsn,
        :ordinal
      ]
    end

    actions do
      defaults [:read]

      create :append do
        accept [
          :source_system_id,
          :source_database,
          :slot_name,
          :commit_lsn,
          :ordinal,
          :operation,
          :origin,
          :snapshot_attempt,
          :id,
          :note,
          :body,
          :message_prefix,
          :message_content
        ]
      end
    end
  end

  defmodule StreamSink do
    @moduledoc "Go-forward intent: the origin floor comes from the slot-origin callback."
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.AppendMarquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_stream_slot",
      sink_kind: :append_log,
      initial_state: :go_forward,
      message_routes: [{"events", AshReplicant.Test.AppendMarquee.Event, :append}]
  end

  defmodule SnapshotSink do
    @moduledoc "Snapshot intent: the floor is the backfill's own consistent point."
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.AppendMarquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_snapshot_slot",
      sink_kind: :append_log,
      initial_state: :snapshot,
      message_routes: [{"events", AshReplicant.Test.AppendMarquee.Event, :append}]
  end

  defmodule BatchSink do
    @moduledoc "Go-forward append sink used by the live batch-delivery proof."
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.AppendMarquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "append_batch_slot",
      sink_kind: :append_log,
      initial_state: :go_forward,
      message_routes: [{"events", AshReplicant.Test.AppendMarquee.Event, :append}]
  end
end
