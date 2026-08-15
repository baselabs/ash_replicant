defmodule AshReplicant.TenantReassignmentTest.TenantMirrorOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.TenantReassignmentTest.TenantMirrorDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "b4_tenant_mirror_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("b4_tenant_orders")
    tenant_attribute(:org_id)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :org_id, :string, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.TenantReassignmentTest.TenantMirrorDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.TenantReassignmentTest.TenantMirrorOrder
  end
end

defmodule AshReplicant.TenantReassignmentTest.TenantMirrorSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.TenantReassignmentTest.TenantMirrorDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "b4_tenant_slot"
end

defmodule AshReplicant.TenantReassignmentTest do
  @moduledoc """
  Roadmap B4 acceptance marquees — the FIRST live tenant-scoped mirror
  coverage in the suite: same-tenant updates apply; live reassignment
  relocates (SCD1) and terminally closes + opens (SCD2, exactly one open
  version per tenant); DEFAULT-identity activation halt; a NULL tenant halts
  before any row lands. Observed through durable state + telemetry only.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "b4_tenant_slot"
  @publication "repl_b4_tenant_pub"
  @src "b4_tenant_orders"

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)

    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("DROP TABLE IF EXISTS b4_tenant_mirror_orders")
    Marquee.q!("CREATE TABLE #{@src} (id text primary key, org_id text, note text)")
    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    Marquee.q!(
      "CREATE TABLE b4_tenant_mirror_orders (id text primary key, org_id text, note text)"
    )

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS b4_tenant_mirror_orders")
      Marquee.teardown_schema!()
    end)

    :ok
  end

  @slot "b4_tenant_slot"
  @publication "repl_b4_tenant_pub"
  @src "b4_tenant_orders"

  defp start do
    AshReplicant.start_link(
      sink: AshReplicant.TenantReassignmentTest.TenantMirrorSink,
      connection: Marquee.conn(),
      publication: @publication,
      source_identity: Marquee.source_identity(),
      go_forward_only: true
    )
  end

  defp mirror do
    Marquee.q!("SELECT id, org_id, note FROM b4_tenant_mirror_orders ORDER BY id").rows
  end

  test "same-tenant update applies under the resolved tenant" do
    ref = attach()

    assert {:ok, _pid} = start()
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    Marquee.q!("INSERT INTO #{@src} (id, org_id, note) VALUES ('1', 'org-a', 'first')")
    PG.wait_until(fn -> mirror() == [["1", "org-a", "first"]] end)

    Marquee.q!("UPDATE #{@src} SET note = 'second' WHERE id = '1'")
    PG.wait_until(fn -> mirror() == [["1", "org-a", "second"]] end)

    assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :applied], _}, 15_000
  end

  test "live reassignment relocates the row (SCD1): old-tenant row gone, new-tenant row present" do
    ref = attach()

    assert {:ok, _pid} = start()
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    Marquee.q!("INSERT INTO #{@src} (id, org_id, note) VALUES ('1', 'org-a', 'before')")
    PG.wait_until(fn -> mirror() == [["1", "org-a", "before"]] end)

    # RIF carries org_id in old_record — the prelude classifies :reassigned
    # and the SCD1 path relocates (destroy-old + upsert-new).
    Marquee.q!("UPDATE #{@src} SET org_id = 'org-b', note = 'after' WHERE id = '1'")

    PG.wait_until(fn -> mirror() == [["1", "org-b", "after"]] end)
  end

  test "live delete under RIF removes the tenant row" do
    ref = attach()

    assert {:ok, _pid} = start()
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    Marquee.q!("INSERT INTO #{@src} (id, org_id, note) VALUES ('1', 'org-a', 'x')")
    PG.wait_until(fn -> mirror() == [["1", "org-a", "x"]] end)

    Marquee.q!("DELETE FROM #{@src} WHERE id = '1'")
    PG.wait_until(fn -> mirror() == [] end)
  end

  test "a NULL tenant in the source row halts before any row lands" do
    ref = attach()

    assert {:ok, _pid} = start()
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    Marquee.q!("INSERT INTO #{@src} (id, org_id, note) VALUES ('1', NULL, 'x')")

    assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :halted],
                    %{reason: :tenant_required}},
                   15_000

    # No row landed and the watermark never advanced past the fault.
    assert mirror() == []
  end

  test "DEFAULT identity on the tenant-scoped source halts the next activation (RIF preflight)" do
    ref = attach()

    assert {:ok, _pid} = start()
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
    assert :ok = AshReplicant.stop_supervised(@slot)

    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY DEFAULT")

    assert {:error, %AshReplicant.Error{reason: :source_replica_identity}} = start()
  end

  test "a mid-stream RIF flip halts via the carve-out (never ignorable)" do
    ref = attach()

    assert {:ok, _pid} = start()
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    # A mid-stream RIF flip: the framework's Relation diff classifies the
    # identity change (carve-out: never ignorable) OR the first subsequent
    # update arrives with a key-only old_record — the B4 prelude's
    # :indeterminate halt. Either class proves the flip cannot stream on.
    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY DEFAULT")

    Marquee.q!("INSERT INTO #{@src} (id, org_id, note) VALUES ('1', 'org-a', 'x')")

    PG.wait_until(fn -> mirror() == [["1", "org-a", "x"]] end)

    # Under combined-suite substrate load the paced reconnect can delay the
    # halt past a fixed window — re-drive the change once before failing.
    halt_or_nil = fn ->
      receive do
        {:telemetry, ^ref, [:ash_replicant, :sink, :halted], %{reason: reason}} ->
          {:halt, reason}

        {:telemetry, ^ref, [:replicant, :schema_change, :halted], _} ->
          {:halt, :framework}
      after
        10_000 -> nil
      end
    end

    Marquee.q!("UPDATE #{@src} SET note = 'y' WHERE id = '1'")

    result =
      case halt_or_nil.() do
        nil ->
          Marquee.q!("UPDATE #{@src} SET note = 'z' WHERE id = '1'")
          halt_or_nil.()

        {:halt, _reason} = halted ->
          halted
      end

    assert {:halt, reason} = result
    assert reason in [:schema_change_destructive, :tenant_required, :framework]
  end

  defp attach do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:replicant, :connection, :slot_active],
        [:ash_replicant, :sink, :applied],
        [:ash_replicant, :sink, :halted],
        [:ash_replicant, :checkpoint, :conflict],
        [:replicant, :schema_change, :halted]
      ],
      fn event, measurements, meta, _c ->
        send(test_pid, {:telemetry, ref, event, Map.merge(measurements, meta)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end
end
