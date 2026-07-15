defmodule AshReplicant.Test.Marquee do
  @moduledoc "Fixtures for the effect-once marquee: source table + publication, mirror resource, sink."

  alias AshReplicant.TestRepo
  alias Ecto.Adapters.SQL

  @src "repl_src_orders"
  @mirror "repl_mirror_orders"
  @ledger "repl_apply_ledger"
  @pub "repl_marquee_pub"

  # SCD2 marquee: its OWN source table + publication + version table + ledger, so its
  # pipeline (own slot `marquee_scd2_slot`, own `Scd2Sink`) never collides with the SCD1
  # marquee's `repl_src_orders`/`Marquee.Order` under `Resolver.build_index`'s fail-closed
  # duplicate-source guard, and its WAL never cross-feeds the SCD1 slot.
  @scd2_src "repl_scd2_src_orders"
  @scd2_version "repl_version_orders"
  @scd2_ledger "repl_scd2_apply_ledger"
  @scd2_pub "repl_scd2_pub"

  # Cloaked-SCD2 version table (Challenge 9). Its `pan` source column encrypts into
  # `encrypted_pan` (AshCloak removes the plaintext attribute). Driven via the apply path
  # directly (no pipeline/slot), so it needs no source table or publication of its own.
  @scd2_cloak_version "repl_version_cloak_orders"

  def src, do: @src
  def mirror, do: @mirror
  def ledger, do: @ledger
  def publication, do: @pub
  def scd2_src, do: @scd2_src
  def scd2_version, do: @scd2_version
  def scd2_ledger, do: @scd2_ledger
  def scd2_publication, do: @scd2_pub
  def scd2_cloak_version, do: @scd2_cloak_version

  @doc "Create the source table (REPLICA IDENTITY FULL), mirror table, apply-ledger, publication."
  def setup_schema! do
    q!("DROP PUBLICATION IF EXISTS #{@pub}")
    q!("DROP TABLE IF EXISTS #{@src}")
    q!("CREATE TABLE #{@src} (id text primary key, note text, body text)")
    q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    q!("CREATE PUBLICATION #{@pub} FOR TABLE #{@src}")
    q!("DROP TABLE IF EXISTS #{@mirror}")
    q!("CREATE TABLE #{@mirror} (id text primary key, note text, body text)")
    q!("DROP TABLE IF EXISTS #{@ledger}")
    q!("CREATE TABLE #{@ledger} (commit_lsn bigint not null)")
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

  @doc "Per-commit_lsn applied count from the no-PK ledger — the dup=0 signal."
  def applied_counts do
    q!("SELECT commit_lsn, count(*) FROM #{@ledger} GROUP BY commit_lsn").rows
    |> Map.new(fn [lsn, n] -> {lsn, n} end)
  end

  @doc """
  Create the SCD2 marquee schema: source table (REPLICA IDENTITY FULL) + publication, the
  version table with BOTH unique indexes the mirror needs — the partial open-version index
  (`WHERE valid_to_lsn IS NULL`, one open version per business key) AND the
  `(order_id, valid_from_lsn)` index that backs the `:order_version` upsert identity
  (ON CONFLICT needs a matching constraint) — and the append-only apply ledger.
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

    q!("DROP TABLE IF EXISTS #{@scd2_ledger}")
    q!("CREATE TABLE #{@scd2_ledger} (commit_lsn bigint not null)")
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

  @doc "Per-commit_lsn applied count from the SCD2 ledger — the SCD2 dup=0 signal."
  def scd2_applied_counts do
    q!("SELECT commit_lsn, count(*) FROM #{@scd2_ledger} GROUP BY commit_lsn").rows
    |> Map.new(fn [lsn, n] -> {lsn, n} end)
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
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.Marquee.Order
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule Sink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "marquee_slot",
      apply_ledger: "repl_apply_ledger"
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
      defaults [:read, :destroy, create: :*, update: :*]

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
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule Scd2Sink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Scd2Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "marquee_scd2_slot",
      apply_ledger: "repl_scd2_apply_ledger"
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
