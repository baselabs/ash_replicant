defmodule AshReplicant.Lease do
  @moduledoc false
  use GenServer, restart: :temporary

  # One supervised, node-local registry. Only admission/release messages run
  # here; database work always executes in the holder's own process. A crashed
  # registry stays unavailable until application restart: silently replacing
  # it with empty state would forget live holds and split exclusivity.
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def with(slot, mode, fun) when mode in [:shared, :exclusive] and is_function(fun, 0) do
    key = {__MODULE__, slot}

    case Process.get(key) do
      nil -> with_hold(slot, mode, key, fun)
      :exclusive -> fun.()
      :shared when mode == :shared -> fun.()
      :shared -> raise ArgumentError, "cannot upgrade a shared destination lease"
    end
  end

  defp with_hold(slot, mode, key, fun) do
    ticket = request(slot, mode)
    :ok = await(ticket)
    Process.put(key, mode)

    try do
      fun.()
    after
      Process.delete(key)
      release(ticket)
    end
  end

  def request(slot, mode) when is_binary(slot) and mode in [:shared, :exclusive],
    do: GenServer.call(__MODULE__, {:request, slot, mode}, :infinity)

  def await({_status, {registry, reference}}) do
    monitor = Process.monitor(registry)

    receive do
      {__MODULE__, ^reference, :granted} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^registry, _reason} ->
        exit(:destination_lease_unavailable)
    end
  end

  def release({_status, {registry, reference}}),
    do: GenServer.call(registry, {:release, reference}, :infinity)

  @impl true
  def init(_opts), do: {:ok, %{slots: %{}, requests: %{}}}

  @impl true
  def handle_call({:request, slot, mode}, {pid, _tag}, state) do
    reference = Process.monitor(pid)
    request = %{slot: slot, mode: mode, pid: pid, status: :queued}
    lease = Map.get(state.slots, slot, %{holders: %{}, waiting: :queue.new()})
    lease = %{lease | waiting: :queue.in(reference, lease.waiting)}

    state = %{
      state
      | slots: Map.put(state.slots, slot, lease),
        requests: Map.put(state.requests, reference, request)
    }

    state = dispatch(state, slot)
    status = Map.fetch!(state.requests, reference).status
    {:reply, {status, {self(), reference}}, state}
  end

  def handle_call({:release, reference}, {pid, _tag}, state) do
    case Map.get(state.requests, reference) do
      %{pid: ^pid} ->
        Process.demonitor(reference, [:flush])
        {:reply, :ok, remove(state, reference)}

      _other ->
        {:reply, {:error, :not_lease_holder}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, reference, :process, _pid, _reason}, state),
    do: {:noreply, remove(state, reference)}

  defp remove(state, reference) do
    case Map.pop(state.requests, reference) do
      {nil, _requests} ->
        state

      {%{slot: slot}, requests} ->
        lease = Map.fetch!(state.slots, slot)

        lease = %{
          lease
          | holders: Map.delete(lease.holders, reference),
            waiting: :queue.filter(&(&1 != reference), lease.waiting)
        }

        dispatch(%{state | requests: requests, slots: Map.put(state.slots, slot, lease)}, slot)
    end
  end

  defp dispatch(state, slot) do
    lease = Map.fetch!(state.slots, slot)

    case :queue.out(lease.waiting) do
      {:empty, _waiting} when map_size(lease.holders) == 0 ->
        %{state | slots: Map.delete(state.slots, slot)}

      {{:value, reference}, waiting} ->
        request = Map.fetch!(state.requests, reference)

        if admissible?(lease.holders, request.mode) do
          send(request.pid, {__MODULE__, reference, :granted})

          lease = %{
            lease
            | holders: Map.put(lease.holders, reference, request.mode),
              waiting: waiting
          }

          requests = Map.put(state.requests, reference, %{request | status: :granted})
          dispatch(%{state | slots: Map.put(state.slots, slot, lease), requests: requests}, slot)
        else
          state
        end

      _empty_with_holders ->
        state
    end
  end

  defp admissible?(holders, :exclusive), do: map_size(holders) == 0
  defp admissible?(holders, :shared), do: :exclusive not in Map.values(holders)
end
