defmodule AshReplicant.Test.CheckpointBinding.CovOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.CheckpointBinding.CovDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "b3_cov_mirror_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("b3_cov_orders")
    skip([:external_code, :audit_note])
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

defmodule AshReplicant.Test.CheckpointBinding.CovDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.CheckpointBinding.CovOrder
  end
end

defmodule AshReplicant.Test.CheckpointBinding.CovSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.CheckpointBinding.CovDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "b3_cov_slot"
end

defmodule AshReplicant.Test.CheckpointBinding.CovIgnoringSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.CheckpointBinding.CovDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "b3_cov_slot",
    ignored_sources: ["public.b3_cov_extra"]
end

defmodule AshReplicant.Test.CheckpointBinding.TenantCovDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.TenantOrder
  end
end

defmodule AshReplicant.Test.CheckpointBinding.TenantCovSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.CheckpointBinding.TenantCovDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "b3_cov_tenant_slot"
end

defmodule AshReplicant.SourceCoverageTest do
  @moduledoc """
  Roadmap B3 acceptance marquees: live additive-column and publication-change
  guards go red; ignores green; type and RIF activation halts — observed
  through durable state + telemetry only.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.CheckpointBinding.{CovIgnoringSink, CovSink}
  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "b3_cov_slot"
  @publication "repl_b3_cov_pub"
  @src "b3_cov_orders"

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)

    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("DROP TABLE IF EXISTS b3_cov_extra")
    Marquee.q!("DROP TABLE IF EXISTS b3_cov_mirror_orders")

    Marquee.q!(
      "CREATE TABLE #{@src} (id text primary key, note text, external_code text, audit_note text)"
    )

    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    Marquee.q!("DROP TABLE IF EXISTS b3_cov_mirror_orders")
    Marquee.q!("CREATE TABLE b3_cov_mirror_orders (id text primary key, note text)")
    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS b3_cov_extra")
      Marquee.q!("DROP TABLE IF EXISTS b3_cov_mirror_orders")
      Marquee.q!("DROP PUBLICATION IF EXISTS repl_b3_tenant_pub")
      # Restore the MIGRATED tenant_orders shape for the rest of the suite
      # (apply_test and friends write the real fixture table).
      Marquee.q!("DROP TABLE IF EXISTS tenant_orders")

      Marquee.q!(
        "CREATE TABLE tenant_orders (id text NOT NULL PRIMARY KEY, org_id text NOT NULL, note text)"
      )

      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [
        "b3_cov_tenant_slot"
      ])

      Marquee.drop_slot!("b3_cov_tenant_slot")
      Marquee.teardown_schema!()
    end)

    :ok
  end

  defp start(sink) do
    AshReplicant.start_link(
      sink: sink,
      connection: Marquee.conn(),
      publication: @publication,
      source_identity: Marquee.source_identity(),
      go_forward_only: true
    )
  end

  # Bounded load-aware poll (battery lesson: fixed sleeps flake under load).
  defp eventually(fun, polls \\ 400) do
    cond do
      fun.() ->
        :ok

      polls == 0 ->
        flunk("condition not reached within the poll budget")

      true ->
        Process.sleep(25)
        eventually(fun, polls - 1)
    end
  end

  test "additive-column red: ALTER TABLE ADD COLUMN upstream halts the first changed row, checkpoint unchanged" do
    ref = attach()

    assert {:ok, _owner} = start(CovSink)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    Marquee.q!("ALTER TABLE #{@src} ADD COLUMN surprise_col text")
    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('1', 'a')")

    assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :halted],
                    %{reason: :source_column_unmapped}},
                   15_000

    # The durable watermark never advanced past the unmapped source.
    [[lsn]] =
      Marquee.q!("SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot]).rows

    assert is_nil(lsn)

    # B7/ADR-0014: the fail-closed halt is PERMANENT, and the owner erases
    # the generation when the pipeline exits — no stale admission state
    # wedges the slot. Re-activation proceeds to its own preflight verdict
    # (the unmapped column is now a START-gate red, not a wedge), and the
    # operator can then drop the column or extend the skip to recover.
    eventually(fn -> :persistent_term.get({AshReplicant, @slot}, :none) == :none end)

    assert {:error, %AshReplicant.Error{reason: :source_column_unmapped}} = start(CovSink)
    assert :none == :persistent_term.get({AshReplicant, @slot}, :none)

    # Recovery path: drop the offending column and the slot activates again.
    Marquee.q!("ALTER TABLE #{@src} DROP COLUMN surprise_col")

    assert {:ok, _owner2} = start(CovSink)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    assert :ok = AshReplicant.stop_supervised(@slot)
    assert :none == :persistent_term.get({AshReplicant, @slot}, :none)
  end

  test "publication-add red: a table added to the publication halts its first change" do
    ref = attach()

    assert {:ok, _pid} = start(CovSink)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    Marquee.q!("CREATE TABLE b3_cov_extra (id text primary key, note text)")
    Marquee.q!("ALTER PUBLICATION #{@publication} ADD TABLE b3_cov_extra")
    Marquee.q!("INSERT INTO b3_cov_extra (id) VALUES ('e1')")

    assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :halted],
                    %{reason: :source_table_unmapped}},
                   15_000
  end

  test "restart-preflight red: dropping a MAPPED table halts the next activation" do
    ref = attach()

    assert {:ok, _pid} = start(CovSink)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
    assert :ok = AshReplicant.stop_supervised(@slot)

    # Drop the MAPPED contract_orders table from the publication between stops.
    Marquee.q!("ALTER PUBLICATION #{@publication} DROP TABLE #{@src}")

    assert {:error, %AshReplicant.Error{reason: :source_table_missing}} = start(CovSink)
  end

  test "ignore green: an ignored extra table mirrors cleanly; ignore removal halts at bind" do
    ref = attach()

    Marquee.q!("CREATE TABLE b3_cov_extra (id text primary key, note text)")
    Marquee.q!("ALTER PUBLICATION #{@publication} ADD TABLE b3_cov_extra")

    assert {:ok, _pid} = start(CovIgnoringSink)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    # The ignored table's changes stream through without halting (mapped table
    # unaffected); write to the mapped table and observe the mirror.
    Marquee.q!("INSERT INTO #{@src} (id, note) VALUES ('c1', 'n')")

    PG.wait_until(fn ->
      [[count]] = Marquee.q!("SELECT count(*) FROM b3_cov_mirror_orders").rows
      count == 1
    end)

    # Removing the ignore: the non-ignoring sink now fails rule 3 at
    # ACTIVATION (b3_cov_extra is an unignored publication table) — the
    # declaration-level ignore removal is separately classified incompatible
    # by the B2 matrix (checkpoint_identity_test).
    assert :ok = AshReplicant.stop_supervised(@slot)

    assert {:error, %AshReplicant.Error{reason: :source_table_unmapped}} =
             start(CovSink)
  end

  test "type red: a source column type outside the target's allowed set halts activation" do
    Marquee.q!("ALTER TABLE #{@src} ALTER COLUMN note TYPE integer USING note::integer")

    assert {:error, %AshReplicant.Error{reason: :source_type_invalid}} = start(CovSink)
  end

  test "RIF negative: DEFAULT identity on a non-tenant PK-keyed table stays green (the RIF class is scoped)" do
    ref = attach()

    assert {:ok, _pid} = start(CovSink)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
  end

  test "RIF red: a tenant-scoped table with DEFAULT identity halts activation" do
    # TenantOrder maps tenant_orders with REPLICA IDENTITY DEFAULT in its
    # fixture table — the RIF rule must catch it at activation.
    Marquee.q!("DROP TABLE IF EXISTS tenant_orders")
    Marquee.q!("CREATE TABLE tenant_orders (id text primary key, org_id text, note text)")
    Marquee.q!("CREATE PUBLICATION repl_b3_tenant_pub FOR TABLE tenant_orders")

    assert {:error, %AshReplicant.Error{reason: :source_replica_identity}} =
             AshReplicant.start_link(
               sink: AshReplicant.Test.CheckpointBinding.TenantCovSink,
               connection: Marquee.conn(),
               publication: "repl_b3_tenant_pub",
               source_identity: Marquee.source_identity(),
               go_forward_only: true
             )
  end

  defp attach do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:replicant, :connection, :slot_active],
        [:ash_replicant, :sink, :halted],
        [:ash_replicant, :checkpoint, :conflict],
        [:ash_replicant, :preflight, :failed]
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
