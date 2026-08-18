defmodule AshReplicant.PipelineOwnerTest do
  @moduledoc """
  Roadmap B7 lifecycle invariants, database-free. The port-1 connection
  deliberately fails and retries (Postgrex protocol errors are expected,
  captured here) — the owner's contract is about PROCESS lifetimes, which
  never need a live database.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias AshReplicant.Destination.Generation
  alias AshReplicant.PipelineOwner

  defmodule OwnerSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "owner_slot"
  end

  @slot "owner_slot"
  @key {AshReplicant, @slot}
  @source_identity [system_identifier: "741852963", database: "postgres"]

  defp start_opts(extra \\ []) do
    Keyword.merge(
      [
        sink: OwnerSink,
        connection: [
          hostname: "127.0.0.1",
          port: 1,
          username: "postgres",
          database: "postgres"
        ],
        publication: "owner_pub",
        source_identity: @source_identity,
        go_forward_only: true
      ],
      extra
    )
  end

  # Load-aware bounded poll (the battery lesson: fixed sleeps flake under
  # host load; the ceiling only bounds waiting, never the outcome).
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

  setup do
    AshReplicant.stop_supervised(@slot)
    :persistent_term.erase(@key)

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      :persistent_term.erase(@key)
    end)

    :ok
  end

  describe "child_spec — the adapter owner under a host supervisor" do
    test "is a :temporary per-slot child whose id carries the slot name" do
      spec = PipelineOwner.child_spec(start_opts())

      assert spec.id == {PipelineOwner, @slot}
      assert spec.restart == :temporary
      assert spec.start == {PipelineOwner, :start_link, [start_opts()]}
    end

    test "starts under a host supervisor and a tree shutdown leaves no stale generation" do
      capture_log(fn ->
        {:ok, sup} =
          Supervisor.start_link([PipelineOwner.child_spec(start_opts())],
            strategy: :one_for_one
          )

        eventually(fn -> match?(%Generation{}, :persistent_term.get(@key, :none)) end)

        %Generation{owner: owner} = :persistent_term.get(@key)
        assert Process.alive?(owner)

        state = :sys.get_state(owner)
        assert state.slot_name == @slot
        assert is_pid(state.pipeline_pid)
        assert Process.alive?(state.pipeline_pid)

        # The host tree's shutdown stops the owner AND its pipeline (the
        # owner does not outlive its supervisor leaving an orphan stream).
        Supervisor.stop(sup)

        eventually(fn -> :persistent_term.get(@key, :none) == :none end)
        eventually(fn -> not Process.alive?(owner) end)
      end)
    end

    test "a duplicate slot child in one tree is a supervisor-level start error" do
      capture_log(fn ->
        spec = PipelineOwner.child_spec(start_opts())
        parent = self()

        # The duplicate id kills the supervisor process during its own init,
        # and the linked exit takes down any non-trapping caller — so the
        # runner traps and reports whatever start_link observes.
        spawn(fn ->
          Process.flag(:trap_exit, true)

          result =
            try do
              Supervisor.start_link([spec, spec], strategy: :one_for_one)
            catch
              :exit, reason -> {:exit, reason}
            end

          send(parent, {:duplicate_start, result})
        end)

        assert_receive {:duplicate_start, result}, 5_000

        # A trapping caller gets the structured duplicate-id error (a
        # non-trapping caller instead dies of the linked exit).
        assert {:error, {:start_spec, {:duplicate_child_name, child_id}}} = result
        assert child_id == {PipelineOwner, @slot}
      end)
    end
  end

  test "an independent pipeline halt erases the generation, exits the owner, and frees the slot" do
    capture_log(fn ->
      assert {:ok, owner} = AshReplicant.start_link(start_opts())
      assert %Generation{owner: ^owner} = :persistent_term.get(@key)

      # The same permanent teardown path a sink fail-closed halt takes.
      :ok = Replicant.Supervisor.halt(@slot, :owner_test_halt)

      eventually(fn -> :persistent_term.get(@key, :none) == :none end)
      eventually(fn -> not Process.alive?(owner) end)

      # No stale :slot_already_active wedge: re-activation is immediate.
      assert {:ok, _owner2} = AshReplicant.start_link(start_opts())
      assert :ok = AshReplicant.stop_supervised(@slot)
      assert :none == :persistent_term.get(@key, :none)
    end)
  end

  test "a stop_supervised normal stop leaves no owner and no generation" do
    capture_log(fn ->
      assert {:ok, owner} = AshReplicant.start_link(start_opts())
      assert :ok = AshReplicant.stop_supervised(@slot)

      assert :none == :persistent_term.get(@key, :none)
      eventually(fn -> not Process.alive?(owner) end)
    end)
  end

  test "an owner crash fails callbacks closed and the stale entry is replaceable" do
    capture_log(fn ->
      assert {:ok, owner} = AshReplicant.start_link(start_opts())

      # Unlink first: the owner is linked to this test process via start_link,
      # and an untrappable kill must not take the test down with it.
      Process.unlink(owner)
      true = Process.exit(owner, :kill)
      eventually(fn -> not Process.alive?(owner) end)

      # The dead-owner entry may persist physically, but it ADMITS nothing.
      assert %Generation{owner: ^owner} = :persistent_term.get(@key)

      assert {:error, %AshReplicant.Error{reason: :config_invalid, op: :callback}} =
               OwnerSink.checkpoint()

      # A fresh start replaces the stale entry (and reaps the orphan pipeline).
      assert {:ok, owner2} = AshReplicant.start_link(start_opts())
      assert owner2 != owner
      assert %Generation{owner: ^owner2} = :persistent_term.get(@key)

      assert :ok = AshReplicant.stop_supervised(@slot)
    end)
  end

  test "a duplicate start against a live owner cannot overwrite live configuration" do
    capture_log(fn ->
      assert {:ok, owner} = AshReplicant.start_link(start_opts())
      assert {:error, :slot_already_active} = AshReplicant.start_link(start_opts())
      assert %Generation{owner: ^owner} = :persistent_term.get(@key)

      assert :ok = AshReplicant.stop_supervised(@slot)
    end)
  end

  test "offline operator functions treat a dead-owner generation as absent" do
    capture_log(fn ->
      assert {:ok, owner} = AshReplicant.start_link(start_opts())

      Process.unlink(owner)
      true = Process.exit(owner, :kill)
      eventually(fn -> not Process.alive?(owner) end)

      assert %Generation{} = :persistent_term.get(@key)

      # The stale entry no longer wedges offline recovery. The operation
      # itself cannot run without a database, so the observable is the GATE:
      # the attempt passes the offline check (and reaps the stale entry on
      # the way in) instead of refusing with :slot_already_active.
      result =
        try do
          AshReplicant.adopt_checkpoint(OwnerSink, @source_identity, 5)
        rescue
          _error -> :raised
        end

      refute match?({:error, %AshReplicant.Error{op: :slot_already_active}}, result)
      assert :none == :persistent_term.get(@key, :none)
    end)
  end
end
