defmodule AshReplicant.PipelineGuard do
  @moduledoc false
  use GenServer, restart: :temporary

  alias AshReplicant.Census

  # Independent of the owner's mailbox: a blocked lifecycle drain must not
  # disable the census deadline, and an untrappable owner kill must not leave
  # its worker or Replicant's independently supervised transport alive.
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def start(owner, pipeline) do
    DynamicSupervisor.start_child(
      AshReplicant.PipelineGuards,
      {__MODULE__, owner: owner, pipeline: pipeline}
    )
  end

  def start_census(guard, slot, sink, token, timeout),
    do: GenServer.call(guard, {:census, slot, sink, token, timeout}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)

    case Process.info(owner, :group_leader) do
      {:group_leader, leader} -> Process.group_leader(self(), leader)
      nil -> :ok
    end

    {:ok,
     %{
       owner: owner,
       monitor: Process.monitor(owner),
       pipeline: Keyword.fetch!(opts, :pipeline),
       census: nil
     }}
  end

  @impl true
  def handle_call({:census, slot, sink, token, timeout}, _from, state) do
    cancel_census(state.census)
    owner = state.owner

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {:census_result, token, Census.run(slot, sink)}) end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:census_deadline, token}, timeout)
    run = %{pid: pid, monitor: monitor, token: token, timeout: timer}
    {:reply, {:ok, pid, timer}, %{state | census: run}}
  end

  @impl true
  def handle_info({:census_deadline, token}, %{census: %{token: token, pid: pid}} = state) do
    send(state.owner, {:census_timeout, token})
    Process.exit(pid, :census_timeout)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{census: %{monitor: monitor, pid: pid} = run} = state
      ) do
    Process.cancel_timer(run.timeout)
    {:noreply, %{state | census: nil}}
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{monitor: monitor, owner: owner} = state
      ) do
    cancel_census(state.census)
    # Terminate the exact child we observed, never a successor's slot lookup.
    _ = DynamicSupervisor.terminate_child(Replicant.Supervisor, state.pipeline)
    {:stop, :normal, %{state | census: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp cancel_census(nil), do: :ok

  defp cancel_census(%{pid: pid, monitor: monitor, timeout: timer}) do
    Process.cancel_timer(timer)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end
end
