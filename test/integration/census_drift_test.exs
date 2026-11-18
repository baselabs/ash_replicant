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

  @slot "c01_census_slot"
  @publication "repl_c01_census_pub"
  @src "c01_census_orders"

  # Fast enough to observe inside a test, generous enough that a real catalog
  # probe never trips the bounded-dispatch timeout on a loaded host.
  @census [interval_ms: 300, jitter_ratio: 0.0, timeout_ms: 250, max_consecutive_faults: 100]

  setup do
    PG.auto_sandbox!()

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

  defp hold_admitted_read(config, parent, barrier) do
    AshReplicant.Destination.with_repo_binding(config, fn ->
      config.repo.transaction(fn ->
        assert %{rows: [[1]]} = Ecto.Adapters.SQL.query!(config.repo, "SELECT 1", [])
        send(parent, {:read_checked_out, barrier})

        receive do
          {:release_read, ^barrier} -> :ok
        after
          10_000 -> flunk("admitted read was never released")
        end
      end)
    end)
  end

  defp pause_transaction(target, barrier) do
    handler = {__MODULE__, barrier}

    :ok =
      :telemetry.attach(
        handler,
        [:ash_replicant, :test_repo, :query],
        &__MODULE__.hold_transaction/4,
        {self(), target, barrier}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def hold_transaction(_event, _measurements, %{query: "begin"}, {parent, target, barrier})
      when target == self() do
    send(parent, {:transaction_checked_out, barrier})

    receive do
      {:release_transaction, ^barrier} -> :ok
    after
      10_000 -> flunk("destination transaction was never released")
    end
  end

  def hold_transaction(_event, _measurements, _metadata, _config), do: :ok

  defp stop_while_paused(target, barrier) do
    try do
      assert_receive {:transaction_checked_out, ^barrier}, 5_000
      stopper = Task.async(fn -> AshReplicant.stop_supervised(@slot) end)
      {stopper, Task.yield(stopper, 250)}
    after
      send(target, {:release_transaction, barrier})
    end
  end

  defp stop_result(stopper, nil), do: Task.await(stopper, 5_000)
  defp stop_result(_stopper, {:ok, result}), do: result

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

  test "stop drains admitted reads before their destination connection outlives the pipeline" do
    assert {:ok, _owner} = start(enabled?: false)
    await_bound()

    parent = self()
    barrier = make_ref()

    reader =
      Task.async(fn ->
        AshReplicant.run_callback(@slot, Sink, :read, fn config ->
          hold_admitted_read(config, parent, barrier)
        end)
      end)

    {stopper, early_stop} =
      try do
        assert_receive {:read_checked_out, ^barrier}, 5_000

        stopper = Task.async(fn -> AshReplicant.stop_supervised(@slot) end)
        {stopper, Task.yield(stopper, 250)}
      after
        send(reader.pid, {:release_read, barrier})
        assert {:ok, :ok} = Task.await(reader, 5_000)
      end

    assert stop_result(stopper, early_stop) == :ok
    assert is_nil(early_stop), "stop returned while an admitted read held a real connection"
  end

  test "stop drains a mutating callback's terminal write with its admitted effect" do
    assert {:ok, _owner} = start(enabled?: false)
    await_bound()
    barrier = make_ref()

    callback =
      Task.async(fn ->
        receive do
          {:start_callback, ^barrier} -> :ok
        end

        AshReplicant.run_callback(@slot, Sink, :mutate, fn config ->
          AshReplicant.Sink.Impl.handle_schema_change(
            config,
            %Replicant.SchemaChange{
              kind: :destructive,
              change: :column_dropped,
              schema: "public",
              table: @src
            },
            %{}
          )
        end)
      end)

    pause_transaction(callback.pid, barrier)
    send(callback.pid, {:start_callback, barrier})
    {stopper, early_stop} = stop_while_paused(callback.pid, barrier)

    assert {:error, %AshReplicant.Error{reason: :schema_change_destructive}} =
             Task.await(callback, 5_000)

    assert stop_result(stopper, early_stop) == :ok
    assert is_nil(early_stop), "stop returned while a terminal write held a real connection"
  end

  test "stop waits for the owner's terminal transaction after the transport exits" do
    assert {:ok, owner} = start(enabled?: false)
    await_bound()
    barrier = make_ref()
    monitor = Process.monitor(owner)
    pause_transaction(owner, barrier)

    assert :ok = Replicant.stop(@slot)
    {stopper, early_stop} = stop_while_paused(owner, barrier)

    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
    assert stop_result(stopper, early_stop) == :ok
    assert is_nil(early_stop), "stop returned while its owner held a real connection"
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
