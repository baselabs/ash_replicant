defmodule AshReplicant.Test.CensusDrift.Order do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.CensusDrift.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "c01_census_mirror_orders"
    repo AshReplicant.TestRepo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  replicant do
    source_table("c01_census_orders")
    tenant_attribute(:org_id)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true
    attribute :org_id, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.CensusDrift.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.CensusDrift.Order
  end
end

defmodule AshReplicant.Test.CensusDrift.Sink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.CensusDrift.Domain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "c01_census_slot"
end

defmodule AshReplicant.CensusDriftTest do
  @moduledoc """
  C01 (ADR-0019) live acceptance: drift that appears AFTER activation is
  detected by the owner's census on a QUIET stream — no reconnect, no restart,
  and no affected row to trigger the per-change guards.

  Each drift here is a real substrate mutation (an upstream publication change,
  a tampered durable contract), and the observable is the census halt itself.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshReplicant.Test.CensusDrift.Sink
  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "c01_census_slot"
  @publication "repl_c01_census_pub"
  @src "c01_census_orders"

  # Fast enough to observe inside a test, generous enough that a real catalog
  # probe never trips the bounded-dispatch timeout on a loaded host.
  @census [interval_ms: 300, jitter_ratio: 0.0, timeout_ms: 250, max_consecutive_faults: 100]

  setup do
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)
    Sandbox.mode(AshReplicant.TestRepo, :auto)

    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("DROP TABLE IF EXISTS c01_census_extra")
    Marquee.q!("DROP TABLE IF EXISTS c01_census_mirror_orders")

    Marquee.q!("CREATE TABLE #{@src} (id text primary key, org_id text not null, note text)")
    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")

    Marquee.q!(
      "CREATE TABLE c01_census_mirror_orders (id text primary key, org_id text not null, note text)"
    )

    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS c01_census_extra")
      Marquee.q!("DROP TABLE IF EXISTS c01_census_mirror_orders")
      Marquee.teardown_schema!()
    end)

    :ok
  end

  defp start(census \\ @census) do
    AshReplicant.start_link(
      sink: Sink,
      connection: Marquee.conn(),
      publication: @publication,
      source_identity: Marquee.source_identity(),
      go_forward_only: true,
      census: census
    )
  end

  defp attach do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:replicant, :connection, :slot_active],
        [:ash_replicant, :census, :passed],
        [:ash_replicant, :census, :faulted],
        [:ash_replicant, :census, :halted]
      ],
      fn event, measurements, meta, _c ->
        send(test_pid, {:census, ref, event, Map.merge(measurements, meta)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp await_bound do
    PG.wait_until(fn ->
      [[count]] =
        Marquee.q!("SELECT count(*) FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot]).rows

      count == 1
    end)
  end

  test "a quiet, undrifted stream censuses HEALTHY repeatedly without a restart" do
    ref = attach()

    assert {:ok, owner} = start()
    assert_receive {:census, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
    await_bound()

    # Two consecutive passes: the schedule really repeats, and a healthy
    # pipeline is never halted by its own monitor.
    assert_receive {:census, ^ref, [:ash_replicant, :census, :passed], first}, 15_000
    assert first.slot_name == @slot
    assert_receive {:census, ^ref, [:ash_replicant, :census, :passed], _second}, 15_000

    assert Process.alive?(owner)
    assert :ok = AshReplicant.stop_supervised(@slot)
  end

  test "coverage drift AFTER activation halts the pipeline with no restart and no affected row" do
    ref = attach()

    assert {:ok, owner} = start()
    assert_receive {:census, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
    await_bound()
    assert_receive {:census, ^ref, [:ash_replicant, :census, :passed], _}, 15_000

    assert [[watermark]] =
             Marquee.q!(
               "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
               [@slot]
             ).rows

    assert is_nil(watermark)

    # The upstream drift: a new table joins the publication. Nothing is written
    # to it, so no change ever reaches the sink — before C01 this stayed
    # invisible until the next reconnect.
    Marquee.q!("CREATE TABLE c01_census_extra (id text primary key)")
    Marquee.q!("ALTER PUBLICATION #{@publication} ADD TABLE c01_census_extra")

    assert_receive {:census, ^ref, [:ash_replicant, :census, :halted],
                    %{kind: :coverage, reason: :source_table_unmapped}},
                   15_000

    # Fail closed: pipeline stopped, generation erased, owner gone — and the
    # durable watermark never advanced.
    PG.wait_until(fn -> :persistent_term.get({AshReplicant, @slot}, :none) == :none end)
    PG.wait_until(fn -> not Process.alive?(owner) end)

    assert [[^watermark]] =
             Marquee.q!(
               "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
               [@slot]
             ).rows

    assert [[0]] = Marquee.q!("SELECT count(*) FROM c01_census_mirror_orders").rows
  end

  test "quiet RIF drift AFTER activation halts through the coverage census" do
    ref = attach()

    assert {:ok, owner} = start()
    assert_receive {:census, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
    await_bound()
    assert_receive {:census, ^ref, [:ash_replicant, :census, :passed], _}, 15_000

    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY DEFAULT")

    assert_receive {:census, ^ref, [:ash_replicant, :census, :halted],
                    %{kind: :coverage, reason: :source_replica_identity}},
                   15_000

    PG.wait_until(fn -> :persistent_term.get({AshReplicant, @slot}, :none) == :none end)
    PG.wait_until(fn -> not Process.alive?(owner) end)
    assert [[0]] = Marquee.q!("SELECT count(*) FROM c01_census_mirror_orders").rows
  end

  test "a tampered durable contract halts via the checkpoint census" do
    ref = attach()

    assert {:ok, owner} = start()
    assert_receive {:census, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
    await_bound()

    # The mutation: the stored publication contract becomes undecodable. The
    # bind classifier already refuses this at reconnect; the census now refuses
    # it between reconnects.
    Marquee.q!(
      "UPDATE ash_replicant_checkpoints SET publication_contract = $1 WHERE slot_name = $2",
      [<<0, 1, 2, 3>>, @slot]
    )

    assert_receive {:census, ^ref, [:ash_replicant, :census, :halted],
                    %{kind: :checkpoint, reason: :publication_contract_incompatible}},
                   15_000

    PG.wait_until(fn -> :persistent_term.get({AshReplicant, @slot}, :none) == :none end)
    PG.wait_until(fn -> not Process.alive?(owner) end)
  end
end
