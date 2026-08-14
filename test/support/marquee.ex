defmodule AshReplicant.Test.Marquee do
  @moduledoc "Fixtures for the effect-once marquee: source table + publication, mirror resource, sink."

  alias AshReplicant.TestRepo
  alias Ecto.Adapters.SQL

  @src "repl_src_orders"
  @mirror "repl_mirror_orders"
  @auxiliary "repl_mirror_auxiliary"
  @pub "repl_marquee_pub"

  # SCD2 marquee: its OWN source, publication, version, and auxiliary tables, so its
  # pipeline (own slot `marquee_scd2_slot`, own `Scd2Sink`) never collides with the SCD1
  # marquee's `repl_src_orders`/`Marquee.Order` under `Resolver.build_index`'s fail-closed
  # duplicate-source guard, and its WAL never cross-feeds the SCD1 slot.
  @scd2_src "repl_scd2_src_orders"
  @scd2_version "repl_version_orders"
  @scd2_auxiliary "repl_version_auxiliary"
  @scd2_pub "repl_scd2_pub"

  # Cloaked-SCD2 version table (Challenge 9). Its `pan` source column encrypts into
  # `encrypted_pan` (AshCloak removes the plaintext attribute). Driven via the apply path
  # directly (no pipeline/slot), so it needs no source table or publication of its own.
  @scd2_cloak_version "repl_version_cloak_orders"

  def src, do: @src
  def mirror, do: @mirror
  def auxiliary, do: @auxiliary
  def publication, do: @pub
  def scd2_src, do: @scd2_src
  def scd2_version, do: @scd2_version
  def scd2_auxiliary, do: @scd2_auxiliary
  def scd2_publication, do: @scd2_pub
  def scd2_cloak_version, do: @scd2_cloak_version
  def escape_key, do: {__MODULE__, :escape_transaction}
  def observer_key, do: {__MODULE__, :observer}
  def scd2_fault_key, do: {__MODULE__, :scd2_between_effects_fault}

  @doc "Create the source table, mirror and auxiliary tables, and publication."
  def setup_schema! do
    q!("DROP PUBLICATION IF EXISTS #{@pub}")
    q!("DROP TABLE IF EXISTS #{@src}")
    q!("CREATE TABLE #{@src} (id text primary key, note text, body text)")
    q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    q!("CREATE PUBLICATION #{@pub} FOR TABLE #{@src}")
    q!("DROP TABLE IF EXISTS #{@mirror}")
    q!("CREATE TABLE #{@mirror} (id text primary key, note text, body text)")
    q!("DROP TABLE IF EXISTS #{@auxiliary}")
    q!("CREATE TABLE #{@auxiliary} (id uuid primary key)")
    :ok
  end

  # Two-table same-participant marquee: BOTH source tables share ONE publication
  # and ONE auxiliary participant atom — the v1 snapshot shape where a per-table
  # ordinal space would mint identical operation keys across tables (one shared
  # consistent point, same participant, same claims prefix). Own tables,
  # publication, and slot so it never collides with the SCD1/SCD2 marquees'
  # resolver indexes.
  @multi_src_a "repl_multi_src_a"
  @multi_src_b "repl_multi_src_b"
  @multi_mirror_a "repl_multi_mirror_a"
  @multi_mirror_b "repl_multi_mirror_b"
  @multi_auxiliary "repl_multi_auxiliary"
  @multi_pub "repl_multi_pub"
  @multi_slot "multi_table_snapshot_slot"

  def multi_src_a, do: @multi_src_a
  def multi_src_b, do: @multi_src_b
  def multi_mirror_a, do: @multi_mirror_a
  def multi_mirror_b, do: @multi_mirror_b
  def multi_auxiliary, do: @multi_auxiliary
  def multi_publication, do: @multi_pub
  def multi_slot, do: @multi_slot

  def setup_multi_schema! do
    q!("DROP PUBLICATION IF EXISTS #{@multi_pub}")

    for src <- [@multi_src_a, @multi_src_b] do
      q!("DROP TABLE IF EXISTS #{src}")
      q!("CREATE TABLE #{src} (id text primary key, note text)")
      q!("ALTER TABLE #{src} REPLICA IDENTITY FULL")
    end

    q!("CREATE PUBLICATION #{@multi_pub} FOR TABLE #{@multi_src_a}, #{@multi_src_b}")

    for mirror <- [@multi_mirror_a, @multi_mirror_b] do
      q!("DROP TABLE IF EXISTS #{mirror}")
      q!("CREATE TABLE #{mirror} (id text primary key, note text)")
    end

    q!("DROP TABLE IF EXISTS #{@multi_auxiliary}")
    q!("CREATE TABLE #{@multi_auxiliary} (id uuid primary key)")
    :ok
  end

  def teardown_multi_schema! do
    q!("DROP PUBLICATION IF EXISTS #{@multi_pub}")

    for table <- [@multi_src_a, @multi_src_b, @multi_mirror_a, @multi_mirror_b, @multi_auxiliary] do
      q!("DROP TABLE IF EXISTS #{table}")
    end

    :ok
  end

  def multi_mirror_rows(mirror),
    do: q!("SELECT id, note FROM #{mirror} ORDER BY id").rows

  def multi_auxiliary_count,
    do: q!("SELECT count(*) FROM #{@multi_auxiliary}").rows |> hd() |> hd()

  @doc "Remove the SCD1 integration fixture's publication and tables."
  def teardown_schema! do
    q!("DROP PUBLICATION IF EXISTS #{@pub}")
    q!("DROP TABLE IF EXISTS #{@src}")
    q!("DROP TABLE IF EXISTS #{@mirror}")
    q!("DROP TABLE IF EXISTS #{@auxiliary}")
    :ok
  end

  def q!(sql, params \\ []), do: SQL.query!(TestRepo, sql, params)

  @doc """
  The `replicant` replication connection, DERIVED from the TestRepo config — so the WAL slot
  always targets the SAME database (`ash_replicant_test`, `config/test.exs`) the source tables
  and mirror live in. Never hardcode the database here: a divergence between the pool's DB and
  the slot's DB is exactly the class of bug this indirection prevents.
  """
  def conn do
    TestRepo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :database])
  end

  @doc "Actual PostgreSQL source identity expected from the replication session."
  def source_identity do
    [[system_identifier, database]] =
      q!("SELECT system_identifier::text, current_database() FROM pg_control_system()").rows

    [system_identifier: system_identifier, database: database]
  end

  @doc "Drop the slot, retrying while the walsender still holds it (async release after socket close)."
  def drop_slot!(slot) do
    Enum.reduce_while(1..80, :ok, fn _i, _acc ->
      try do
        q!(
          "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = $1",
          [slot]
        )

        {:halt, :ok}
      rescue
        Postgrex.Error ->
          Process.sleep(25)
          {:cont, :error}
      end
    end)
  end

  @doc "Rows currently in the mirror, ordered by id."
  def mirror_rows, do: q!("SELECT id, note FROM #{@mirror} ORDER BY id").rows

  @doc """
  Create the SCD2 marquee schema: source table (REPLICA IDENTITY FULL) + publication, the
  version table with BOTH unique indexes the mirror needs — the partial open-version index
  (`WHERE valid_to_lsn IS NULL`, one open version per business key) AND the
  `(order_id, valid_from_lsn)` index that backs the `:order_version` upsert identity
  (ON CONFLICT needs a matching constraint) — plus its auxiliary table.
  """
  def setup_scd2_schema! do
    q!("DROP PUBLICATION IF EXISTS #{@scd2_pub}")
    q!("DROP TABLE IF EXISTS #{@scd2_src}")
    q!("CREATE TABLE #{@scd2_src} (order_id text primary key, amount text)")
    q!("ALTER TABLE #{@scd2_src} REPLICA IDENTITY FULL")
    q!("CREATE PUBLICATION #{@scd2_pub} FOR TABLE #{@scd2_src}")

    q!("DROP TABLE IF EXISTS #{@scd2_version}")

    q!("""
    CREATE TABLE #{@scd2_version} (
      id uuid primary key,
      order_id text not null,
      amount text,
      valid_from_lsn bigint not null,
      valid_to_lsn bigint,
      valid_from_ts timestamptz,
      valid_to_ts timestamptz,
      is_current boolean not null default true
    )
    """)

    q!(
      "CREATE UNIQUE INDEX #{@scd2_version}_open_uniq ON #{@scd2_version} (order_id) WHERE valid_to_lsn IS NULL"
    )

    q!(
      "CREATE UNIQUE INDEX #{@scd2_version}_bk_from ON #{@scd2_version} (order_id, valid_from_lsn)"
    )

    q!("DROP TABLE IF EXISTS #{@scd2_auxiliary}")
    q!("CREATE TABLE #{@scd2_auxiliary} (id uuid primary key)")
    :ok
  end

  @doc """
  Create the cloaked-SCD2 version table (Challenge 9): the plaintext `pan` source column
  lands in the AshCloak-managed `encrypted_pan bytea` column. Same dual-unique-index shape
  as the plain version table. No source table/publication — driven via the apply path.
  """
  def setup_scd2_cloak_schema! do
    q!("DROP TABLE IF EXISTS #{@scd2_cloak_version}")

    q!("""
    CREATE TABLE #{@scd2_cloak_version} (
      id uuid primary key,
      order_id text not null,
      amount text,
      encrypted_pan bytea,
      valid_from_lsn bigint not null,
      valid_to_lsn bigint,
      valid_from_ts timestamptz,
      valid_to_ts timestamptz,
      is_current boolean not null default true
    )
    """)

    q!(
      "CREATE UNIQUE INDEX #{@scd2_cloak_version}_open_uniq ON #{@scd2_cloak_version} (order_id) WHERE valid_to_lsn IS NULL"
    )

    q!(
      "CREATE UNIQUE INDEX #{@scd2_cloak_version}_bk_from ON #{@scd2_cloak_version} (order_id, valid_from_lsn)"
    )

    :ok
  end

  @doc "A business key's version rows (as maps), ordered by valid_from_lsn — the SCD2 chain."
  def scd2_versions(order_id) do
    q!(
      "SELECT valid_from_lsn, valid_to_lsn, is_current, amount FROM #{@scd2_version} WHERE order_id = $1 ORDER BY valid_from_lsn",
      [order_id]
    ).rows
    |> Enum.map(fn [from, to, current, amount] ->
      %{from: from, to: to, current: current, amount: amount}
    end)
  end

  @doc "Raw, fully-ordered snapshot of the whole version table for byte-identity (dedup) checks."
  def scd2_versions_snapshot do
    q!(
      "SELECT order_id, valid_from_lsn, valid_to_lsn, valid_from_ts, valid_to_ts, is_current, amount FROM #{@scd2_version} ORDER BY order_id, valid_from_lsn"
    ).rows
  end

  @doc "A business key's cloaked version rows (raw `encrypted_pan` ciphertext included)."
  def scd2_cloak_versions(order_id) do
    q!(
      "SELECT valid_from_lsn, valid_to_lsn, is_current, encrypted_pan FROM #{@scd2_cloak_version} WHERE order_id = $1 ORDER BY valid_from_lsn",
      [order_id]
    ).rows
    |> Enum.map(fn [from, to, current, enc] ->
      %{from: from, to: to, current: current, encrypted_pan: enc}
    end)
  end

  defmodule EscapeRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :ash_replicant, adapter: Ecto.Adapters.Postgres
  end

  def escape_repo_config do
    TestRepo.config()
    |> Keyword.put(:pool, DBConnection.ConnectionPool)
    |> Keyword.put(:pool_size, 1)
  end

  defmodule RecordAuxiliary do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    alias AshOnetime.Resource.Info, as: OnetimeInfo
    alias AshReplicant.DestinationParticipant
    alias AshReplicant.DestinationParticipant.{ActionRef, Context, ReplayIdentity}
    alias Ecto.Adapters.SQL

    @impl Ash.Resource.Change
    def change(changeset, opts, _context) do
      auxiliary = Keyword.fetch!(opts, :resource)
      escape_table = Keyword.fetch!(opts, :escape_table)

      changeset
      |> Ash.Changeset.before_action(fn changeset ->
        maybe_fault_between_effects!(opts)
        maybe_escape_transaction!(escape_table, opts)
        changeset
      end)
      |> Ash.Changeset.after_action(fn changeset, result ->
        private_arguments = private_arguments(auxiliary, changeset, opts)

        Ash.create!(auxiliary, %{},
          action: :record,
          authorize?: false,
          transaction?: false,
          return_notifications?: true,
          private_arguments: private_arguments,
          context: %{data_layer: changeset.context[:data_layer] || %{}}
        )

        {:ok, result}
      end)
    end

    defp private_arguments(auxiliary, changeset, opts) do
      if OnetimeInfo.protected?(auxiliary, :record) do
        participant = Keyword.fetch!(opts, :participant)

        {:ok, operation_key} =
          DestinationParticipant.operation_key(changeset, participant)

        %{operation_key: operation_key}
      else
        %{}
      end
    end

    @impl AshReplicant.DestinationParticipant
    def destination_participants(opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: Keyword.fetch!(opts, :resource),
            action: :record,
            replay_identity: %ReplayIdentity{
              participant: Keyword.fetch!(opts, :participant),
              components: [
                :source_system_identifier,
                :source_database,
                :slot_name,
                :commit_lsn,
                :ordinal,
                :participant
              ]
            }
          }
        ]}}
    end

    defp maybe_fault_between_effects!(opts) do
      case Keyword.get(opts, :fault_key) do
        nil ->
          :ok

        key ->
          case :persistent_term.get(key, false) do
            true ->
              :persistent_term.put(key, false)
              raise "injected structural participant fault"

            {:after, 0} ->
              :persistent_term.put(key, false)
              raise "injected structural participant fault"

            {:after, remaining} when is_integer(remaining) and remaining > 0 ->
              :persistent_term.put(key, {:after, remaining - 1})

            _other ->
              :ok
          end
      end
    end

    defp maybe_escape_transaction!(escape_table, opts) do
      case Keyword.get(opts, :escape_key) do
        nil ->
          :ok

        key ->
          escape_transaction!(escape_table, opts, key, :persistent_term.get(key, false))
      end
    end

    defp escape_transaction!(_escape_table, _opts, _key, false), do: :ok

    defp escape_transaction!(escape_table, opts, key, true) do
      :persistent_term.put(key, false)

      [[sink_transaction_id]] =
        SQL.query!(AshReplicant.TestRepo, "SELECT txid_current()", []).rows

      observer = :persistent_term.get(Keyword.fetch!(opts, :observer_key))
      send(observer, {:sink_transaction_id, sink_transaction_id})

      result =
        Task.async(fn ->
          SQL.query!(
            AshReplicant.Test.Marquee.EscapeRepo,
            "INSERT INTO \"#{escape_table}\" (id) VALUES ($1)",
            [Ash.UUID.generate() |> Ecto.UUID.dump!()]
          )
        end)
        |> Task.await(15_000)

      send(observer, {:escape_inserted, result.num_rows})
    end
  end

  defmodule StoreResponse do
    @moduledoc false
    @behaviour AshOnetime.ResponseClassifier
    @behaviour AshReplicant.DestinationParticipant

    @impl AshOnetime.ResponseClassifier
    def classify(result, _context), do: {:store, result}

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %AshReplicant.DestinationParticipant.Context{}),
      do: {:ok, :no_database}
  end

  defmodule Auxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Marquee.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "repl_mirror_auxiliary"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        argument :operation_key, :string, allow_nil?: false, public?: false
        accept []
      end
    end

    onetime do
      protect :record do
        strategy :idempotency

        scope([
          {:static, "ash_replicant:destination-participant:1"},
          {:static, "scd1_auxiliary"}
        ])

        key({:argument, :operation_key})
        fingerprint(arguments: [:operation_key])

        response(AshOnetime.Codec.Resource,
          fields: [:id],
          classify: AshReplicant.Test.Marquee.StoreResponse
        )

        retention({1, :day})
      end
    end
  end

  defmodule Scd2Auxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Marquee.Scd2Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "repl_version_auxiliary"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        accept []
      end
    end
  end

  defmodule Order do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Marquee.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "repl_mirror_orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("repl_src_orders")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
      attribute :body, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, update: :*]

      create :create do
        primary? true
        accept [:id, :note, :body]
        touches_resources [AshReplicant.Test.Marquee.Auxiliary]

        change {AshReplicant.Test.Marquee.RecordAuxiliary,
                resource: AshReplicant.Test.Marquee.Auxiliary,
                participant: :scd1_auxiliary,
                escape_table: "repl_mirror_auxiliary",
                escape_key: {AshReplicant.Test.Marquee, :escape_transaction},
                observer_key: {AshReplicant.Test.Marquee, :observer}}
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.Marquee.Order
      resource AshReplicant.Test.Marquee.Auxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule Sink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "marquee_slot"
  end

  defmodule VersionOrder do
    @moduledoc """
    SCD2 mirror resource for the effect-once marquee (`table repl_version_orders`,
    `source_table repl_scd2_src_orders`). Lives in its OWN `Scd2Domain` so it never shares a
    `build_index` with the SCD1 `Marquee.Order` (which claims `repl_src_orders`).
    """
    use Ash.Resource,
      domain: AshReplicant.Test.Marquee.Scd2Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "repl_version_orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("repl_scd2_src_orders")
      history_strategy(:scd2)
      history_business_key([:order_id])
      upsert_identity(:order_version)
      history_close_action(:close_version)
      history_current_attribute(:is_current)
      history_valid_from_timestamp_attribute(:valid_from_ts)
      history_valid_to_timestamp_attribute(:valid_to_ts)
    end

    attributes do
      uuid_primary_key :id
      attribute :order_id, :string, allow_nil?: false, public?: true
      attribute :amount, :string, public?: true
      attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
      attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
      attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: true, public?: true
      attribute :valid_to_ts, :utc_datetime_usec, allow_nil?: true, public?: true
      attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
    end

    identities do
      identity :order_version, [:order_id, :valid_from_lsn]
    end

    actions do
      defaults [:read, :destroy, update: :*]

      create :create do
        primary? true

        accept [
          :order_id,
          :amount,
          :valid_from_lsn,
          :valid_to_lsn,
          :valid_from_ts,
          :valid_to_ts,
          :is_current
        ]

        touches_resources [AshReplicant.Test.Marquee.Scd2Auxiliary]

        change {AshReplicant.Test.Marquee.RecordAuxiliary,
                resource: AshReplicant.Test.Marquee.Scd2Auxiliary,
                participant: :scd2_auxiliary,
                escape_table: "repl_version_auxiliary",
                fault_key: {AshReplicant.Test.Marquee, :scd2_between_effects_fault},
                observer_key: {AshReplicant.Test.Marquee, :observer}}
      end

      update :close_version do
        accept [:valid_to_lsn, :valid_to_ts, :is_current]
      end
    end
  end

  defmodule Scd2Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.Marquee.VersionOrder
      resource AshReplicant.Test.Marquee.Scd2Auxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule Scd2Sink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Scd2Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "marquee_scd2_slot"
  end

  defmodule MultiAuxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Marquee.MultiDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "repl_multi_auxiliary"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        argument :operation_key, :string, allow_nil?: false, public?: false
        accept []
      end
    end

    onetime do
      protect :record do
        strategy :idempotency

        scope([
          {:static, "ash_replicant:destination-participant:1"},
          {:static, "multi_auxiliary"}
        ])

        key({:argument, :operation_key})
        fingerprint(arguments: [:operation_key])

        response(AshOnetime.Codec.Resource,
          fields: [:id],
          classify: AshReplicant.Test.Marquee.StoreResponse
        )

        retention({1, :day})
      end
    end
  end

  defmodule MultiOrderA do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Marquee.MultiDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "repl_multi_mirror_a"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("repl_multi_src_a")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, update: :*]

      create :create do
        primary? true
        accept [:id, :note]
        touches_resources [AshReplicant.Test.Marquee.MultiAuxiliary]

        change {AshReplicant.Test.Marquee.RecordAuxiliary,
                resource: AshReplicant.Test.Marquee.MultiAuxiliary,
                participant: :multi_auxiliary,
                escape_table: "repl_multi_auxiliary"}
      end
    end
  end

  defmodule MultiOrderB do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Marquee.MultiDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "repl_multi_mirror_b"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("repl_multi_src_b")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, update: :*]

      create :create do
        primary? true
        accept [:id, :note]
        touches_resources [AshReplicant.Test.Marquee.MultiAuxiliary]

        change {AshReplicant.Test.Marquee.RecordAuxiliary,
                resource: AshReplicant.Test.Marquee.MultiAuxiliary,
                participant: :multi_auxiliary,
                escape_table: "repl_multi_auxiliary"}
      end
    end
  end

  defmodule MultiDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.Marquee.MultiOrderA
      resource AshReplicant.Test.Marquee.MultiOrderB
      resource AshReplicant.Test.Marquee.MultiAuxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule MultiSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.MultiDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "multi_table_snapshot_slot"
  end

  defmodule CloakVersionOrder do
    @moduledoc """
    AshCloak-enabled SCD2 version resource (Challenge 9). `pan` is cloak-encrypted
    (AshCloak removes the plaintext attribute, adds `encrypted_pan :binary` + a decrypt
    calculation). The `:close_version` action does NOT accept `pan`, so AshCloak attaches no
    encrypt change to it — the atomic bulk_update close must run with zero cloak involvement
    (no `OriginalDataNotAvailable`). Its own `Scd2CloakDomain`; driven via the apply path.
    """
    use Ash.Resource,
      domain: AshReplicant.Test.Marquee.Scd2CloakDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource, AshCloak]

    postgres do
      table "repl_version_cloak_orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("repl_scd2_cloak_src")
      sensitive([:pan])
      history_strategy(:scd2)
      history_business_key([:order_id])
      upsert_identity(:order_version)
      history_close_action(:close_version)
      history_current_attribute(:is_current)
      history_valid_from_timestamp_attribute(:valid_from_ts)
      history_valid_to_timestamp_attribute(:valid_to_ts)
    end

    cloak do
      vault AshReplicant.Test.CloakVault
      attributes [:pan]
    end

    attributes do
      uuid_primary_key :id
      attribute :order_id, :string, allow_nil?: false, public?: true
      attribute :amount, :string, public?: true
      attribute :pan, :string, public?: true
      attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
      attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
      attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: true, public?: true
      attribute :valid_to_ts, :utc_datetime_usec, allow_nil?: true, public?: true
      attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
    end

    identities do
      identity :order_version, [:order_id, :valid_from_lsn]
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      update :close_version do
        accept [:valid_to_lsn, :valid_to_ts, :is_current]
      end
    end
  end

  defmodule Scd2CloakDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.Marquee.CloakVersionOrder
    end
  end
end
