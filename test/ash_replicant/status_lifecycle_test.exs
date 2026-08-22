defmodule AshReplicant.StatusLifecycleTest do
  @moduledoc """
  O02 (issue #12): the six lifecycle states as LIVE transitions of the real
  `AshReplicant.PipelineOwner` — the tombstone writers, the adoption-window
  safety of the `:status` call, and the concurrent start/stop/crash matrix.
  Database-free (the `PipelineOwnerTest` port-1 precedent): the source
  connection deliberately fails, the census faults on the substrate-touching
  checks, and the durable tombstone leg is covered by the integration suite.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias AshReplicant.Destination.Generation
  alias AshReplicant.PipelineOwner

  defmodule LifecycleSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "status_lifecycle_slot"
  end

  @slot "status_lifecycle_slot"
  @entry {AshReplicant, @slot}
  @tombstone_key {AshReplicant.Status, @slot}
  @source_identity [system_identifier: "741852963", database: "postgres"]

  defp start_opts(extra) do
    Keyword.merge(
      [
        sink: LifecycleSink,
        connection: [
          hostname: "127.0.0.1",
          port: 1,
          username: "postgres",
          database: "postgres",
          connect_timeout: 50,
          queue_target: 50,
          queue_interval: 50,
          timeout: 100
        ],
        publication: "status_lifecycle_pub",
        source_identity: @source_identity,
        go_forward_only: true
      ],
      extra
    )
  end

  defp eventually(fun, polls \\ 400) do
    cond do
      fun.() -> :ok
      polls == 0 -> flunk("condition not reached within the poll budget")
      true -> Process.sleep(25) && eventually(fun, polls - 1)
    end
  end

  defp tombstone, do: :persistent_term.get(@tombstone_key, nil)

  setup do
    AshReplicant.stop_supervised(@slot)
    :persistent_term.erase(@entry)
    :persistent_term.erase(@tombstone_key)

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      :persistent_term.erase(@entry)
      :persistent_term.erase(@tombstone_key)
    end)

    :ok
  end

  describe "activating" do
    test "a status call in the adoption window answers activating and keeps the owner alive" do
      caller = self()

      spawn_link(fn ->
        # The entry is written before the adoption cast; against port 1 the
        # pipeline start (and the whole activation chain) is slow enough that
        # this polls in on the window reliably, and the assertion also holds
        # after adoption completes.
        send(caller, {:started, AshReplicant.start_link(start_opts(census: [enabled?: false]))})
      end)

      assert_receive {:started, {:ok, owner}}, 10_000

      eventually(fn -> match?(%Generation{}, :persistent_term.get(@entry, :none)) end)

      # THE adoption-window tripwire: the pending owner must answer a status
      # call (not exit {:bad_call, :status}) — and once admitted, the answer
      # is a live state, never a terminal one.
      assert AshReplicant.status(LifecycleSink) in [:catching_up, :healthy]
      assert Process.alive?(owner)

      assert :ok = AshReplicant.stop_supervised(@slot)
    end

    test "a never-adopted pending owner reports activating through the internal facts call" do
      # Direct pending-owner construction (the start_link handshake's first
      # leg) makes the window deterministic without racing activation.
      {:ok, owner} = GenServer.start(PipelineOwner, {:pending, self(), start_opts([])})

      assert %{phase: :pending} = GenServer.call(owner, :ash_replicant_status)

      # The pending owner must survive the call (the default GenServer
      # behavior would exit {:bad_call, ...} and kill a healthy activation).
      assert Process.alive?(owner)
      GenServer.stop(owner)
    end
  end

  describe "degraded → halted (the census fault budget)" do
    test "census faults degrade, and the budget halt persists a value-free tombstone" do
      capture_log(fn ->
        assert {:ok, _owner} =
                 AshReplicant.start_link(
                   start_opts(
                     census: [
                       interval_ms: 50,
                       timeout_ms: 100,
                       max_consecutive_faults: 2
                     ]
                   )
                 )

        # Below the budget the pipeline is live and degraded (public
        # catching_up — never healthy: census is the health authority).
        eventually(fn -> match?(:catching_up, AshReplicant.status(LifecycleSink)) end)

        # At the budget the owner halts and the tombstone carries the
        # closed census reason.
        eventually(fn ->
          match?({:halted, :census_unverifiable}, AshReplicant.status(LifecycleSink))
        end)

        assert %AshReplicant.Status.Tombstone{cause: :census_unverifiable, class: :halt} =
                 tombstone()

        assert :none == :persistent_term.get(@entry, :none)
      end)
    end
  end

  describe "halted — an unexplained pipeline death" do
    test "a pipeline halt without a recorded cause writes the generic tombstone" do
      capture_log(fn ->
        assert {:ok, _owner} =
                 AshReplicant.start_link(start_opts(census: [enabled?: false]))

        eventually(fn -> match?(%Generation{}, :persistent_term.get(@entry, :none)) end)

        :ok = Replicant.Supervisor.halt(@slot, :status_lifecycle_test)

        eventually(fn ->
          match?({:halted, :pipeline_terminated}, AshReplicant.status(LifecycleSink))
        end)

        assert %AshReplicant.Status.Tombstone{cause: :pipeline_terminated, class: :halt} =
                 tombstone()
      end)
    end

    test "a precise recorded cause is not stomped by the generic writer" do
      capture_log(fn ->
        assert {:ok, _owner} =
                 AshReplicant.start_link(start_opts(census: [enabled?: false]))

        eventually(fn -> match?(%Generation{}, :persistent_term.get(@entry, :none)) end)

        # The sink-side precise writer's node-local record, as a halt in
        # flight would leave it: the generic :DOWN writer must leave it be.
        :persistent_term.put(@tombstone_key, %AshReplicant.Status.Tombstone{
          cause: :schema_change_destructive,
          class: :halt,
          at: DateTime.utc_now()
        })

        :ok = Replicant.Supervisor.halt(@slot, :status_lifecycle_test)

        eventually(fn -> :none == :persistent_term.get(@entry, :none) end)

        assert %AshReplicant.Status.Tombstone{cause: :schema_change_destructive} = tombstone()
      end)
    end
  end

  describe "stopped" do
    test "an operator stop persists the stopped tombstone and reports not started" do
      capture_log(fn ->
        assert {:ok, _owner} =
                 AshReplicant.start_link(start_opts(census: [enabled?: false]))

        eventually(fn -> match?(%Generation{}, :persistent_term.get(@entry, :none)) end)

        assert :ok = AshReplicant.stop_supervised(@slot)

        assert %AshReplicant.Status.Tombstone{cause: :operator_stopped, class: :stopped} =
                 tombstone()

        assert :not_started = AshReplicant.status(LifecycleSink)
        assert %{lifecycle: :stopped} = AshReplicant.Status.derive(LifecycleSink, 50)
      end)
    end

    test "a tree shutdown writes no tombstone" do
      capture_log(fn ->
        {:ok, sup} =
          Supervisor.start_link(
            [PipelineOwner.child_spec(start_opts(census: [enabled?: false]))],
            strategy: :one_for_one
          )

        eventually(fn -> match?(%Generation{}, :persistent_term.get(@entry, :none)) end)

        Supervisor.stop(sup)

        eventually(fn -> :none == :persistent_term.get(@entry, :none) end)
        assert tombstone() in [nil, :none]
        assert :not_started = AshReplicant.status(LifecycleSink)
      end)
    end
  end

  describe "superseded" do
    test "a dead owner is superseded — a fault, never ready, and replaceable" do
      capture_log(fn ->
        assert {:ok, owner} =
                 AshReplicant.start_link(start_opts(census: [enabled?: false]))

        eventually(fn -> match?(%Generation{}, :persistent_term.get(@entry, :none)) end)

        true = Process.exit(owner, :kill)
        eventually(fn -> not Process.alive?(owner) end)

        assert {:halted, :owner_lost} = AshReplicant.status(LifecycleSink)
        assert %{lifecycle: :superseded} = AshReplicant.Status.derive(LifecycleSink, 50)

        # A successful replacement clears the stale entry's fault state.
        assert {:ok, _owner2} =
                 AshReplicant.start_link(start_opts(census: [enabled?: false]))

        assert AshReplicant.status(LifecycleSink) in [:catching_up, :healthy]

        assert :ok = AshReplicant.stop_supervised(@slot)
      end)
    end
  end

  describe "concurrent transitions" do
    test "concurrent start and stop converge on a legal state" do
      capture_log(fn ->
        opts = start_opts(census: [enabled?: false])

        tasks =
          for _ <- 1..4 do
            Task.async(fn -> AshReplicant.start_link(opts) end)
          end

        stopper = Task.async(fn -> AshReplicant.stop_supervised(@slot) end)

        for task <- tasks do
          _ = Task.await(task, 10_000)
        end

        _ = Task.await(stopper, 10_000)

        # Whatever interleaving won, the answer is one of the legal shapes
        # and never a lie: no live entry with a dead owner reporting ready.
        status = AshReplicant.status(LifecycleSink)
        assert status in [:catching_up, :healthy, {:halted, :owner_lost}, :not_started]

        assert :ok = AshReplicant.stop_supervised(@slot)
      end)
    end

    test "a crashing owner under status polling never reports healthy" do
      capture_log(fn ->
        assert {:ok, owner} =
                 AshReplicant.start_link(start_opts(census: [enabled?: false]))

        poller =
          Task.async(fn ->
            for _ <- 1..40 do
              assert AshReplicant.status(LifecycleSink) != :healthy
              Process.sleep(10)
            end

            :ok
          end)

        true = Process.exit(owner, :kill)

        :ok = Task.await(poller, 10_000)

        assert {:halted, :owner_lost} = AshReplicant.status(LifecycleSink)

        assert :ok = AshReplicant.stop_supervised(@slot)
      end)
    end
  end
end
