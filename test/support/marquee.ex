defmodule AshReplicant.Test.Marquee do
  @moduledoc "Fixtures for the effect-once marquee: source table + publication, mirror resource, sink."

  alias AshReplicant.TestRepo
  alias Ecto.Adapters.SQL

  @src "repl_src_orders"
  @mirror "repl_mirror_orders"
  @ledger "repl_apply_ledger"
  @pub "repl_marquee_pub"

  def src, do: @src
  def mirror, do: @mirror
  def ledger, do: @ledger
  def publication, do: @pub

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
end
