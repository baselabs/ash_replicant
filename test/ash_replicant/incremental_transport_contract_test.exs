defmodule AshReplicant.IncrementalTransportContractTest do
  @moduledoc """
  Black-box gates over the fetched Replicant artifact required by ADR-0017.

  These use only exported dependency behavior. A module being present is not
  evidence that the collision window, retry cap, or backpressure contract works.
  """
  use ExUnit.Case, async: true

  alias Replicant.SnapshotWindow, as: Window
  alias Replicant.Snapshotter.Incremental

  defp change(op, old_id, new_id \\ nil) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: "orders",
      old_record: if(is_nil(old_id), do: nil, else: %{"id" => old_id}),
      record: if(is_nil(new_id), do: nil, else: %{"id" => new_id})
    }
  end

  defp chunk(ids, opts \\ []) do
    %{
      qualified: "public.orders",
      schema: "public",
      table: "orders",
      pk_raw: ["id"],
      pk_canon: Enum.map(ids, &[&1]),
      changes: Enum.map(ids, &change(:snapshot, nil, &1)),
      hw: Keyword.get(opts, :hw, 100),
      first?: false,
      complete?: false,
      progress: <<131, 100, 0, 8, "progress">>,
      bound: nil
    }
  end

  test "the fetched artifact is the exact 1.2.2 callback-lifecycle fix" do
    version = :replicant |> Application.spec(:vsn) |> to_string()
    assert version == "1.2.2"
    assert Replicant.SnapshotProgress.pending?(:backfill_pending)
  end

  test "a current stream image tracked before chunk admission wins" do
    window =
      Window.new(epoch: 1, drop_cap: 100, max_pending: 4)
      |> Window.open_window("public.orders")
      |> Window.track([change(:update, 2, 2)])

    {window, :ok} = Window.add_chunk(window, chunk([1, 2, 3]))
    window = Window.set_frontier(window, 1, 100)

    assert {:apply, kept, _meta, _window} = Window.pop_ready(window)
    assert Enum.map(kept, & &1.record["id"]) == [1, 3]
  end

  test "delete and both sides of a key-changing update cannot resurrect" do
    window = Window.new(epoch: 1, drop_cap: 100, max_pending: 4)

    {window, :ok} =
      Window.add_chunk(Window.open_window(window, "public.orders"), chunk([1, 2, 3]))

    {window, []} =
      Window.track_capped(window, [
        change(:delete, 2),
        change(:update, 1, 4)
      ])

    assert Window.tracked?(window, "public.orders", [1])
    assert Window.tracked?(window, "public.orders", [2])
    assert Window.tracked?(window, "public.orders", [4])

    assert {:apply, kept, _meta, _window} =
             window |> Window.set_frontier(1, 100) |> Window.pop_ready()

    assert Enum.map(kept, & &1.record["id"]) == [3]
  end

  test "pending chunks are bounded and capacity refusal does not append" do
    window = Window.new(epoch: 1, drop_cap: 100, max_pending: 1)
    window = Window.open_window(window, "public.orders")
    {window, :ok} = Window.add_chunk(window, chunk([1]))
    {refused, :at_capacity} = Window.add_chunk(window, chunk([2], hw: 101))

    assert length(refused.pending) == 1
  end

  test "keyed contention exhausts after three discards while reconnect consumes no budget" do
    table = "public.orders"

    assert {:retry, %{^table => 2}} =
             Incremental.keyed_retry_decision(%{}, table, :table_discarded)

    assert {:retry, %{^table => 3} = attempts} =
             Incremental.keyed_retry_decision(%{table => 2}, table, :table_discarded)

    assert {:retry, ^attempts} =
             Incremental.keyed_retry_decision(attempts, table, :window_reset)

    assert :halt = Incremental.keyed_retry_decision(attempts, table, :table_discarded)
  end

  test "keyless contention signals table redo and reconnect remains distinguishable" do
    assert catch_throw(Incremental.reset_guard({:error, :table_discarded})) ==
             :table_discarded

    assert catch_throw(Incremental.reset_guard({:error, :window_reset})) == :window_reset
  end
end
