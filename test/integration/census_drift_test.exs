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

defmodule AshReplicant.Test.CensusDrift.ClaimSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.CensusDrift.Domain, AshReplicant.Test.Messages.Domain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "c01_census_slot",
    message_routes: [{"outbox", AshReplicant.Test.Messages.Outbox, :record}],
    recovery_horizon: {1, :second}
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

  alias AshReplicant.{Destination, Error}
  alias AshReplicant.Sink.Impl
  alias AshReplicant.Test.CensusDrift.{ClaimSink, Sink}
  alias AshReplicant.Test.{LeaseEvents, Marquee, Messages, PG}
  alias Ecto.Adapters.SQL
  alias Replicant.SchemaChange

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

  defp start(census \\ @census, sink \\ Sink) do
    AshReplicant.start_link(
      sink: sink,
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
    Destination.with_repo_binding(config, fn ->
      config.repo.transaction(fn ->
        assert %{rows: [[1]]} = SQL.query!(config.repo, "SELECT 1", [])
        monitor = Process.monitor(parent)
        send(parent, {:read_checked_out, barrier})

        receive do
          {:release_read, ^barrier} -> :ok
          {:DOWN, ^monitor, :process, ^parent, _reason} -> :ok
        end

        Process.demonitor(monitor, [:flush])
        :ok
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
  def hold_transaction(
        event,
        measurements,
        %{query: "begin"} = metadata,
        {parent, {:census, owner}, barrier}
      )
      when owner != self() do
    case :sys.get_state(owner, :infinity) do
      %{census_run: %{pid: worker}} when worker == self() ->
        Process.flag(:trap_exit, true)
        hold_transaction(event, measurements, metadata, {parent, worker, barrier})

      _other ->
        :ok
    end
  end

  def hold_transaction(_event, _measurements, %{query: "begin"}, {parent, target, barrier})
      when target == self() do
    :telemetry.detach({__MODULE__, barrier})
    monitor = Process.monitor(parent)
    send(parent, {:transaction_checked_out, barrier, self()})

    receive do
      {:release_transaction, ^barrier} ->
        send(parent, {:transaction_released, barrier, self()})
        :ok

      {:DOWN, ^monitor, :process, ^parent, _reason} ->
        :ok
    end

    Process.demonitor(monitor, [:flush])
    :ok
  end

  def hold_transaction(_event, _measurements, _metadata, _config), do: :ok

  defp stop_while_paused(target, barrier, monitor) do
    LeaseEvents.attach()
    assert_receive {:transaction_checked_out, ^barrier, ^target}, 5_000

    result =
      try do
        stopper = Task.async(fn -> AshReplicant.stop_supervised(@slot) end)
        assert_receive {:lease_queued, pid} when pid == stopper.pid, 5_000
        {stopper, nil}
      after
        send(target, {:release_transaction, barrier})
      end

    await_transaction_release(target, barrier, monitor)
    result
  end

  defp await_transaction_release(target, barrier, monitor) do
    receive do
      {:transaction_released, ^barrier, ^target} ->
        :ok

      {:DOWN, ^monitor, :process, ^target, _reason} ->
        flunk("transaction owner exited before accepting its release")
    end
  end

  # These joins prove resource lifetime, not end-to-end latency. Lease queue
  # acknowledgements prove contention before any held operation is released.
  defp stop_result(stopper, nil), do: Task.await(stopper, :infinity)
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

  for iteration <- 1..50 do
    @tag timeout: 120_000
    test "a busy real stream keeps passing the census, iteration #{iteration}" do
      assert_busy_stream_census()
    end
  end

  defp assert_busy_stream_census do
    ref = attach()
    assert {:ok, owner} = start(interval_ms: 50, jitter_ratio: 0.0, timeout_ms: 10_000)
    assert_receive {:census, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
    await_bound()
    assert_receive {:census, ^ref, [:ash_replicant, :census, :passed], _}, 15_000
    :telemetry.detach({__MODULE__, ref})
    ref = attach()
    [{stream, _}] = Registry.lookup(Replicant.Registry, {@slot, :assembler})
    handler = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ash_replicant, :test_repo, :query],
        &__MODULE__.hold_stream/4,
        {parent, stream}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    try do
      insert_stream_row(0)

      for iteration <- 1..2 do
        assert_receive {:stream_checked_out, ^stream, barrier}, 15_000

        try do
          # Keep another real transaction queued while this admitted delivery
          # owns a connection. Two NEW passes must finish before it releases:
          # serial leases deterministically fail this concurrency property.
          discard_passes(ref)
          insert_stream_row(iteration)
          assert_receive {:census, ^ref, [:ash_replicant, :census, :passed], _}, 15_000
          assert_receive {:census, ^ref, [:ash_replicant, :census, :passed], _}, 15_000
          assert Process.alive?(owner)
          assert_no_census_fault(ref)
          refute_received {:census, ^ref, [:ash_replicant, :census, :halted], _}
        after
          send(stream, {:release_stream, barrier})
        end

        assert_receive {:stream_committed, ^stream}, 15_000
      end

      assert_receive {:stream_checked_out, ^stream, barrier}, 15_000
      send(stream, {:release_stream, barrier})
      assert_receive {:stream_committed, ^stream}, 15_000
      assert [[3]] = Marquee.q!("SELECT count(*) FROM c01_census_mirror_orders").rows
      assert Process.alive?(owner)
      assert :ok = AshReplicant.stop_supervised(@slot)
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def hold_stream(_event, _measurements, %{query: "begin"}, {parent, stream})
      when stream == self() do
    barrier = make_ref()
    monitor = Process.monitor(parent)
    send(parent, {:stream_checked_out, stream, barrier})

    receive do
      {:release_stream, ^barrier} -> :ok
      {:DOWN, ^monitor, :process, ^parent, _reason} -> :ok
    end

    Process.demonitor(monitor, [:flush])
  end

  def hold_stream(_event, _measurements, %{query: "commit"}, {parent, stream})
      when stream == self(),
      do: send(parent, {:stream_committed, stream})

  def hold_stream(_event, _measurements, _metadata, _config), do: :ok

  defp insert_stream_row(number) do
    Marquee.q!("INSERT INTO #{@src} (id, org_id, note) VALUES ($1, $2, $3)", [
      Integer.to_string(number),
      "stream-org",
      "stream-note"
    ])
  end

  defp discard_passes(ref) do
    receive do
      {:census, ^ref, [:ash_replicant, :census, :passed], _} -> discard_passes(ref)
    after
      0 -> :ok
    end
  end

  defp assert_no_census_fault(ref) do
    reason =
      receive do
        {:census, ^ref, [:ash_replicant, :census, :faulted], metadata} ->
          Map.get(metadata, :reason, :unknown)
      after
        0 -> :none
      end

    # Separate source sites retain the closed fault class in CI's value-free
    # failure formatter, without printing metadata or captured database output.
    case reason do
      :none -> :ok
      :checkpoint_unbound -> flunk("busy census checkpoint was unbound")
      :census_timeout -> flunk("busy census timed out")
      :census_source_unreachable -> flunk("busy census source was unreachable")
      :census_checker_fault -> flunk("busy census checker faulted")
      _other -> flunk("busy census emitted an unknown fault class")
    end
  end

  test "stop drains admitted reads before their destination connection outlives the pipeline" do
    LeaseEvents.attach()
    assert {:ok, _owner} = start(enabled?: false)
    await_bound()

    parent = self()
    barrier = make_ref()

    reader =
      Task.async(fn ->
        AshReplicant.run_callback(@slot, Sink, fn config ->
          hold_admitted_read(config, parent, barrier)
        end)
      end)

    {stopper, early_stop} =
      try do
        assert_receive {:read_checked_out, ^barrier}, 5_000

        stopper = Task.async(fn -> AshReplicant.stop_supervised(@slot) end)
        assert_receive {:lease_queued, pid} when pid == stopper.pid, 5_000
        {stopper, nil}
      after
        send(reader.pid, {:release_read, barrier})
        Task.await(reader, :infinity)
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

        AshReplicant.run_callback(@slot, Sink, fn config ->
          Impl.handle_schema_change(
            config,
            %SchemaChange{
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
    {stopper, early_stop} = stop_while_paused(callback.pid, barrier, callback.ref)

    assert {:error, %Error{reason: :schema_change_destructive}} = Task.await(callback, :infinity)

    assert stop_result(stopper, early_stop) == :ok
    assert is_nil(early_stop), "stop returned while a terminal write held a real connection"
  end

  test "stop drains the actual census worker instead of killing its checked-out connection" do
    LeaseEvents.attach()
    Messages.setup_schema!()

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Messages.teardown_schema!()
    end)

    assert {:ok, owner} =
             start([interval_ms: 60_000, jitter_ratio: 0.0, timeout_ms: 10_000], ClaimSink)

    await_bound()

    # A pre-witness checkpoint takes the real census rebind transaction.
    Marquee.q!(
      "UPDATE ash_replicant_checkpoints SET digest_key_state = NULL WHERE slot_name = $1",
      [@slot]
    )

    barrier = make_ref()
    pause_transaction({:census, owner}, barrier)

    # An unrelated caller's real BEGIN must neither consume nor wait at the
    # census barrier. Telemetry runs inline, so any wrong-holder message is
    # already observable when this transaction returns.
    assert {:ok, %{rows: [[1]]}} =
             AshReplicant.TestRepo.transaction(fn ->
               SQL.query!(AshReplicant.TestRepo, "SELECT 1", [])
             end)

    refute_received {:transaction_checked_out, ^barrier, _other}
    %{census_timer: %{token: token}} = :sys.get_state(owner, :infinity)
    send(owner, {:census_tick, token})
    assert_receive {:transaction_checked_out, ^barrier, worker}, 5_000
    assert %{census_run: %{pid: ^worker}} = :sys.get_state(owner, :infinity)
    monitor = Process.monitor(worker)

    {stopper, early_stop} =
      try do
        stopper = Task.async(fn -> AshReplicant.stop_supervised(@slot) end)
        assert_receive {:lease_queued, pid} when pid == stopper.pid, 5_000
        {stopper, nil}
      after
        send(worker, {:release_transaction, barrier})
      end

    await_transaction_release(worker, barrier, monitor)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end

    assert stop_result(stopper, early_stop) == :ok
    assert is_nil(early_stop), "stop killed a census worker while it held a real connection"
  end

  test "stop waits for the owner's terminal transaction after the transport exits" do
    assert {:ok, owner} = start(enabled?: false)
    await_bound()
    barrier = make_ref()
    monitor = Process.monitor(owner)
    pause_transaction(owner, barrier)

    assert :ok = Replicant.stop(@slot)
    {stopper, early_stop} = stop_while_paused(owner, barrier, monitor)

    receive do
      {:DOWN, ^monitor, :process, ^owner, reason} -> assert reason == :normal
    end

    assert stop_result(stopper, early_stop) == :ok
    assert is_nil(early_stop), "stop returned while its owner held a real connection"

    assert [["operator_stopped"]] =
             Marquee.q!(
               "SELECT terminal_cause FROM ash_replicant_checkpoints WHERE slot_name = $1",
               [@slot]
             ).rows
  end

  test "owner cleanup reasserts its terminal fact after a late admitted checkpoint clear" do
    assert {:ok, owner} = start(enabled?: false)
    await_bound()
    parent = self()
    barrier = make_ref()
    monitor = Process.monitor(owner)
    handler = {__MODULE__, barrier}

    :ok =
      :telemetry.attach(
        handler,
        [:ash_replicant, :test_repo, :query],
        &__MODULE__.observe_owner_commit/4,
        {parent, owner, barrier}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    callback =
      Task.async(fn ->
        AshReplicant.run_callback(@slot, Sink, fn config ->
          send(parent, {:advance_admitted, barrier})

          receive do
            {:advance, ^barrier} -> clear_terminal(config)
          end
        end)
      end)

    try do
      assert_receive {:advance_admitted, ^barrier}, 5_000
      assert :ok = Replicant.stop(@slot)
      assert_receive {:owner_committed, ^barrier}, 5_000
      send(callback.pid, {:advance, barrier})
      assert :ok = Task.await(callback, :infinity)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 15_000

      assert [["pipeline_terminated"]] =
               Marquee.q!(
                 "SELECT terminal_cause FROM ash_replicant_checkpoints WHERE slot_name = $1",
                 [@slot]
               ).rows
    after
      send(callback.pid, {:advance, barrier})
    end
  end

  @doc false
  def observe_owner_commit(_event, _measurements, %{query: "commit"}, {parent, owner, barrier})
      when owner == self(),
      do: send(parent, {:owner_committed, barrier})

  def observe_owner_commit(_event, _measurements, _metadata, _config), do: :ok

  defp clear_terminal(config) do
    Destination.with_repo_binding(config, fn ->
      Ash.create!(
        config.checkpoint_resource,
        %{
          source_system_id: config.source_identity.system_identifier,
          source_database: config.source_identity.database,
          slot_name: @slot,
          terminal_cause: nil,
          terminal_class: nil,
          terminal_at: nil
        },
        action: :upsert,
        upsert?: true,
        upsert_identity: :source_slot,
        upsert_fields: [:terminal_cause, :terminal_class, :terminal_at],
        authorize?: false,
        context: Destination.action_context(config),
        return_notifications?: true
      )
    end)

    :ok
  end

  test "a busy stream cannot starve stop or admit a late reader ahead of it" do
    LeaseEvents.attach()
    ref = attach()
    assert {:ok, owner} = start(enabled?: false)
    assert_receive {:census, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000
    await_bound()
    [{stream, _}] = Registry.lookup(Replicant.Registry, {@slot, :assembler})
    parent = self()
    barrier = make_ref()
    pause_transaction(stream, barrier)
    insert_stream_row(0)
    assert_receive {:transaction_checked_out, ^barrier, ^stream}, 5_000
    stopper = Task.async(fn -> AshReplicant.stop_supervised(@slot) end)

    try do
      assert_receive {:lease_queued, pid} when pid == stopper.pid, 5_000
      insert_stream_row(1)

      late =
        Task.async(fn ->
          AshReplicant.run_callback(@slot, Sink, fn _config ->
            send(parent, :late_reader_admitted)
          end)
        end)

      assert_receive {:lease_queued, pid} when pid == late.pid, 5_000
      send(stream, {:release_transaction, barrier})
      assert :ok = Task.await(stopper, :infinity)
      assert {:error, %Error{reason: :config_invalid}} = Task.await(late, :infinity)
      refute_received :late_reader_admitted
      refute Process.alive?(owner)
      assert :none == :persistent_term.get({AshReplicant, @slot}, :none)
    after
      send(stream, {:release_transaction, barrier})
    end
  end

  test "host-tree shutdown drains a census connection and leaves no worker or pipeline" do
    LeaseEvents.attach()
    Messages.setup_schema!()
    on_exit(fn -> Messages.teardown_schema!() end)

    opts = [
      sink: ClaimSink,
      connection: Marquee.conn(),
      publication: @publication,
      source_identity: Marquee.source_identity(),
      go_forward_only: true,
      census: [interval_ms: 60_000, jitter_ratio: 0.0, timeout_ms: 60_000]
    ]

    spec = AshReplicant.PipelineOwner.child_spec(opts)
    assert spec.shutdown == :infinity

    host =
      start_supervised!(%{
        id: :census_host,
        start: {Supervisor, :start_link, [[spec], [strategy: :one_for_one]]},
        type: :supervisor
      })

    [{_, owner, _, _}] = Supervisor.which_children(host)
    {worker, barrier} = paused_census(owner)
    %{pipeline_pid: pipeline} = :sys.get_state(owner, :infinity)
    monitors = monitor_all([owner, worker, pipeline])
    shutdown = Task.async(fn -> Supervisor.stop(host, :normal, :infinity) end)

    try do
      assert_receive {:lease_queued, ^owner}, 5_000
      refute_received {:DOWN, _, :process, ^worker, _}
      send(worker, {:release_transaction, barrier})
      assert :ok = Task.await(shutdown, :infinity)
      await_all(monitors)
      assert :none == :persistent_term.get({AshReplicant, @slot}, :none)
      assert_no_live_pipeline()
    after
      send(worker, {:release_transaction, barrier})
    end
  end

  test "direct GenServer termination drains the same admitted census" do
    LeaseEvents.attach()
    Messages.setup_schema!()
    on_exit(fn -> Messages.teardown_schema!() end)
    assert {:ok, owner} = start([interval_ms: 60_000, timeout_ms: 60_000], ClaimSink)
    {worker, barrier} = paused_census(owner)
    %{pipeline_pid: pipeline} = :sys.get_state(owner, :infinity)
    monitors = monitor_all([owner, worker, pipeline])
    stopper = Task.async(fn -> GenServer.stop(owner, :normal, :infinity) end)

    try do
      assert_receive {:lease_queued, ^owner}, 5_000
      send(worker, {:release_transaction, barrier})
      assert :ok = Task.await(stopper, :infinity)
      await_all(monitors)
      assert :none == :persistent_term.get({AshReplicant, @slot}, :none)
    after
      send(worker, {:release_transaction, barrier})
    end
  end

  @tag capture_log: true
  test "application shutdown drains owners before terminating the lease registry" do
    LeaseEvents.attach()
    ref = attach()
    Messages.setup_schema!()
    on_exit(fn -> Messages.teardown_schema!() end)
    assert {:ok, owner} = start([interval_ms: 60_000, timeout_ms: 60_000], ClaimSink)
    {worker, barrier} = paused_census(owner)
    %{pipeline_pid: pipeline} = :sys.get_state(owner, :infinity)
    monitors = monitor_all([owner, worker, pipeline])
    stopper = Task.async(fn -> Application.stop(:ash_replicant) end)

    try do
      assert_receive {:lease_queued, drainer}, 5_000
      queued = :sys.get_state(AshReplicant.Lease).requests |> Map.values()
      assert %{mode: :exclusive, slot: @slot} = Enum.find(queued, &(&1.pid == drainer))
      refute_received {:DOWN, _, :process, ^worker, _}
      send(worker, {:release_transaction, barrier})
      await_all(monitors)
      assert :none == :persistent_term.get({AshReplicant, @slot}, :none)
      refute_received {:census, ^ref, [:ash_replicant, :census, :faulted], _}
      refute_received {:census, ^ref, [:ash_replicant, :census, :halted], _}
    after
      send(worker, {:release_transaction, barrier})

      try do
        assert :ok = Task.await(stopper, :infinity)
      after
        {:ok, _apps} = Application.ensure_all_started(:ash_replicant)
      end
    end
  end

  @tag capture_log: true
  test "the census deadline fires independently while the owner waits to drain" do
    LeaseEvents.attach()
    Messages.setup_schema!()
    on_exit(fn -> Messages.teardown_schema!() end)
    assert {:ok, owner} = start([interval_ms: 60_000, timeout_ms: 60_000], ClaimSink)
    {worker, barrier} = paused_census(owner)
    %{guard: guard, census_run: %{token: token}} = :sys.get_state(owner, :infinity)
    monitor = Process.monitor(worker)
    assert {:trap_exit, true} = Process.info(worker, :trap_exit)
    Process.exit(owner, :shutdown)

    try do
      assert_receive {:lease_queued, ^owner}, 5_000
      # Deliver the real deadline event to its independent owner. This makes
      # the mailbox/lease interleaving deterministic without timing the test.
      send(guard, {:census_deadline, token})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 15_000
      AshReplicant.PipelineOwner.stop(owner)
      assert_no_live_pipeline()
    after
      send(worker, {:release_transaction, barrier})
    end
  end

  @tag capture_log: true
  test "an untrappable owner death cannot orphan the census or its transport" do
    Messages.setup_schema!()
    on_exit(fn -> Messages.teardown_schema!() end)
    assert {:ok, owner} = start([interval_ms: 60_000, timeout_ms: 60_000], ClaimSink)
    {worker, _barrier} = paused_census(owner)
    %{pipeline_pid: pipeline, guard: guard} = :sys.get_state(owner, :infinity)
    worker_monitor = Process.monitor(worker)
    monitors = monitor_all([owner, pipeline, guard])
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 15_000
    await_all(monitors)
    assert_no_live_pipeline()
  end

  @tag capture_log: true
  test "a lost census guard cannot strand an exit-trapping worker or its owner" do
    Messages.setup_schema!()
    on_exit(fn -> Messages.teardown_schema!() end)
    assert {:ok, owner} = start([interval_ms: 60_000, timeout_ms: 60_000], ClaimSink)
    {worker, barrier} = paused_census(owner)
    assert {:trap_exit, true} = Process.info(worker, :trap_exit)
    %{pipeline_pid: pipeline, guard: guard} = :sys.get_state(owner, :infinity)
    worker_monitor = Process.monitor(worker)
    monitors = monitor_all([owner, pipeline, guard])

    try do
      Process.exit(guard, :kill)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 15_000
      refute AshReplicant.PipelineGuard.timed_out?(guard, make_ref())
      await_all(monitors)
      assert :none == :persistent_term.get({AshReplicant, @slot}, :none)
      assert_no_live_pipeline()
    after
      send(worker, {:release_transaction, barrier})
    end
  end

  defp paused_census(owner) do
    await_bound()

    Marquee.q!(
      "UPDATE ash_replicant_checkpoints SET digest_key_state = NULL WHERE slot_name = $1",
      [@slot]
    )

    barrier = make_ref()
    pause_transaction({:census, owner}, barrier)
    %{census_timer: %{token: token}} = :sys.get_state(owner, :infinity)
    send(owner, {:census_tick, token})
    assert_receive {:transaction_checked_out, ^barrier, worker}, 5_000
    {worker, barrier}
  end

  defp monitor_all(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp await_all(monitors) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 15_000
    end
  end

  defp assert_no_live_pipeline do
    # Registry retires entries through its own monitor, independently of
    # our process joins. Any registered process that is still alive fails.
    for {pid, _value} <- Registry.lookup(Replicant.Registry, {@slot, :pipeline}) do
      refute Process.alive?(pid)
    end
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
