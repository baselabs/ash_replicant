defmodule AshReplicant.IdentifierQuotingTest.QuoteMirrorOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.IdentifierQuotingTest.QuoteMirrorDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    # MIXED-CASE table name: unquoted SQL folds to lowercase and would hit the
    # DECOY `quoteorders` table; the quoting home must preserve case exactly —
    # `DELETE FROM "public"."QuoteOrders"` — through clear_mirror and the
    # `:mirror` truncate. (The embedded-quote construction cell lives at unit
    # level in apply_test: ecto's own identifier policy forbids `"` in table
    # names on the Ash path, so a pipeline fixture for it cannot exist.)
    table "QuoteOrders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("b5_quote_src")
    on_truncate(:mirror)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.IdentifierQuotingTest.QuoteMirrorDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.IdentifierQuotingTest.QuoteMirrorOrder
  end
end

defmodule AshReplicant.IdentifierQuotingTest.QuoteMirrorSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.IdentifierQuotingTest.QuoteMirrorDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "b5_quote_slot"
end

defmodule AshReplicant.IdentifierQuotingTest do
  @moduledoc """
  U3/D4 acceptance marquee — the ONE quoting home driving REAL SQL on the live
  substrate: a mixed-case mirror table (`QuoteOrders`) is addressed exactly (case
  preserved inside quotes) by both the snapshot clear_mirror DELETE and the
  `:mirror` truncate DELETE, while the lowercase DECOY (`quoteorders`) — the table
  unquoted case-folding SQL WOULD hit — survives untouched.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "b5_quote_slot"
  @publication "repl_b5_quote_pub"
  @src "b5_quote_src"

  setup do
    # LIFO: the drop-teardown registered below runs FIRST (still under :auto);
    # this mode reset runs LAST, after every query.
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("DROP TABLE IF EXISTS \"QuoteOrders\"")
    Marquee.q!("DROP TABLE IF EXISTS quoteorders")

    Marquee.q!("CREATE TABLE #{@src} (id text primary key, note text)")
    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    # The mixed-case mirror table, and the DECOY unquoted case-folding hits.
    Marquee.q!("CREATE TABLE \"QuoteOrders\" (id text primary key, note text)")
    Marquee.q!("CREATE TABLE quoteorders (id text primary key, note text)")

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS \"QuoteOrders\"")
      Marquee.q!("DROP TABLE IF EXISTS quoteorders")
      Marquee.teardown_schema!()
    end)

    :ok
  end

  defp attach do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:replicant, :connection, :slot_active],
        [:ash_replicant, :sink, :applied],
        [:ash_replicant, :sink, :halted]
      ],
      fn event, measurements, meta, _c ->
        send(test_pid, {:telemetry, ref, event, Map.merge(measurements, meta)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp start do
    AshReplicant.start_link(
      sink: AshReplicant.IdentifierQuotingTest.QuoteMirrorSink,
      connection: Marquee.conn(),
      publication: @publication,
      source_identity: Marquee.source_identity(),
      snapshot: true
    )
  end

  defp mirror do
    Marquee.q!("SELECT id, note FROM \"QuoteOrders\" ORDER BY id").rows
  end

  defp decoy do
    Marquee.q!("SELECT id, note FROM quoteorders ORDER BY id").rows
  end

  # S02 (ADR-0017): the snapshot no longer clears anything, so the mixed-case
  # mirror is FILLED, not wiped-and-filled. The quoting property this test
  # exists for is unchanged and now strictly stronger — the snapshot must write
  # only the mixed-case table, and the lower-case decoy is untouched by a path
  # that no longer issues an unqualified DELETE at all.
  test "the snapshot fills exactly the mixed-case mirror table, clearing nothing — the decoy survives" do
    ref = attach()

    Marquee.q!("INSERT INTO quoteorders VALUES ('decoy-seed', 'must-survive-snapshot')")
    Marquee.q!("INSERT INTO \"QuoteOrders\" VALUES ('stale', 'survives-absent-clear')")
    Marquee.q!("INSERT INTO #{@src} VALUES ('1', 'fresh')")

    assert {:ok, _pid} = start()
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    PG.wait_until(fn ->
      mirror() == [["1", "fresh"], ["stale", "survives-absent-clear"]]
    end)

    assert decoy() == [["decoy-seed", "must-survive-snapshot"]]

    refute_receive {:telemetry, ^ref, [:ash_replicant, :sink, :halted], _}, 0
  end

  test "a :mirror truncate deletes exactly the mixed-case mirror table — the decoy survives" do
    ref = attach()

    assert {:ok, _pid} = start()
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    Marquee.q!("INSERT INTO #{@src} VALUES ('1', 'row')")
    PG.wait_until(fn -> mirror() == [["1", "row"]] end)

    Marquee.q!("INSERT INTO quoteorders VALUES ('decoy-live', 'must-survive-truncate')")
    Marquee.q!("TRUNCATE #{@src}")

    PG.wait_until(fn -> mirror() == [] end)
    assert decoy() == [["decoy-live", "must-survive-truncate"]]
  end
end
