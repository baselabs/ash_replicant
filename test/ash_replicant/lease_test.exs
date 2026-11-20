defmodule AshReplicant.LeaseTest do
  use ExUnit.Case, async: false

  alias AshReplicant.Lease

  setup do
    %{slot: "lease_test_#{System.unique_integer([:positive])}"}
  end

  defp holder(slot, mode) do
    parent = self()

    task =
      Task.async(fn ->
        ticket = Lease.request(slot, mode)
        send(parent, {:requested, self(), ticket})
        Lease.await(ticket)
        send(parent, {:holding, self()})

        receive do
          :release -> Lease.release(ticket)
        end
      end)

    on_exit(fn ->
      monitor = Process.monitor(task.pid)
      Process.exit(task.pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
      end
    end)

    assert_receive {:requested, pid, _ticket} when pid == task.pid, 5_000
    task
  end

  defp refute_holding(%Task{pid: pid}) do
    refute_received {:holding, ^pid}
  end

  defp release(task) do
    send(task.pid, :release)
    assert :ok = Task.await(task)
  end

  test "shared holders run together and a queued writer blocks later readers", %{slot: slot} do
    first = holder(slot, :shared)
    second = holder(slot, :shared)
    assert_receive {:holding, pid} when pid == first.pid, 5_000
    assert_receive {:holding, pid} when pid == second.pid, 5_000

    exclusive = holder(slot, :exclusive)
    late = holder(slot, :shared)
    refute_holding(exclusive)
    refute_holding(late)
    release(first)
    refute_holding(exclusive)
    release(second)
    assert_receive {:holding, pid} when pid == exclusive.pid, 5_000
    refute_holding(late)
    release(exclusive)
    assert_receive {:holding, pid} when pid == late.pid, 5_000
    release(late)
  end

  test "all consecutive shared waiters wake directly on exclusive release", %{slot: slot} do
    exclusive = holder(slot, :exclusive)
    assert_receive {:holding, pid} when pid == exclusive.pid, 5_000
    readers = for _ <- 1..8, do: holder(slot, :shared)
    release(exclusive)

    for reader <- readers do
      assert_receive {:holding, pid} when pid == reader.pid, 5_000
    end

    Enum.each(readers, &release/1)
  end

  test "a dead shared holder releases the exclusive waiter", %{slot: slot} do
    first = holder(slot, :shared)
    assert_receive {:holding, pid} when pid == first.pid, 5_000
    exclusive = holder(slot, :exclusive)
    assert is_nil(Task.shutdown(first, :brutal_kill))
    assert_receive {:holding, pid} when pid == exclusive.pid, 5_000
    release(exclusive)
  end

  test "a dead exclusive holder releases the readers", %{slot: slot} do
    exclusive = holder(slot, :exclusive)
    assert_receive {:holding, pid} when pid == exclusive.pid, 5_000
    reader = holder(slot, :shared)
    assert is_nil(Task.shutdown(exclusive, :brutal_kill))
    assert_receive {:holding, pid} when pid == reader.pid, 5_000
    release(reader)
  end

  test "a dead queued writer cannot strand later readers", %{slot: slot} do
    first = holder(slot, :shared)
    assert_receive {:holding, pid} when pid == first.pid, 5_000
    abandoned = holder(slot, :exclusive)
    assert is_nil(Task.shutdown(abandoned, :brutal_kill))
    late = holder(slot, :shared)
    assert_receive {:holding, pid} when pid == late.pid, 5_000
    release(late)
    release(first)
  end

  test "slots are independent and finished slots retain no holders or waiters", %{slot: slot} do
    exclusive = holder(slot, :exclusive)
    assert_receive {:holding, pid} when pid == exclusive.pid, 5_000
    other = holder(slot <> "_other", :exclusive)
    assert_receive {:holding, pid} when pid == other.pid, 5_000
    release(other)
    release(exclusive)
    refute Map.has_key?(:sys.get_state(Lease).slots, slot)
    refute Map.has_key?(:sys.get_state(Lease).slots, slot <> "_other")
  end

  test "with releases after an exception and allows same-process nesting", %{slot: slot} do
    assert_raise RuntimeError, "lease test", fn ->
      Lease.with(slot, :shared, fn -> raise "lease test" end)
    end

    assert :ok =
             Lease.with(slot, :exclusive, fn ->
               Lease.with(slot, :shared, fn -> :ok end)
             end)
  end
end
