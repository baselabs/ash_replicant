defmodule AshReplicant.PipelineOwner do
  @moduledoc """
  One owner per live resolver generation (roadmap B7 / ADR-0014).

  The owner is a per-slot process that owns the activation's admission
  state and **monitors** the Replicant pipeline. Replicant retains
  transport ownership — the owner never holds, restarts, or reconfigures
  the connection; it observes process death and cleans up:

    * the pipeline exits (a fail-closed halt, a crash, an external stop) —
      the `:DOWN` handler erases only its own generation (compare-reference),
      clears the snapshot ordinals, and exits `:normal`;
    * the owner is shut down (a host supervisor's tree shutdown, or an
      explicit `Process.exit/2`) — the trapped `:EXIT` handler stops the
      pipeline first, then the same cleanup runs.

  The owner links to NOBODY (deliberately): a bare caller finishing — or
  being shut down by its own test runner — must not take a live pipeline
  down mid-transaction. A host supervisor needs no link either: it
  monitors the child and delivers tree shutdown as a direct `:shutdown`
  exit signal, which the trapping owner receives and honors.

  A generation whose owner has died ADMITS nothing (callback entry checks
  owner liveness and fails closed) and blocks nothing (activation and the
  offline operator functions treat it as absent) — see ADR-0014 for the
  fail-closed/replaceable contract.

  ## Starting under a host supervisor

  Declare it as a child (the id carries the slot name, so a duplicate slot
  in one tree is a supervisor-level start error):

      children = [
        {AshReplicant.PipelineOwner,
         sink: MyApp.ReplicantSink,
         connection: [...],
         publication: "orders_pub",
         source_identity: [system_identifier: "...", database: "..."]}
      ]

  The child is `:temporary` like the pipeline it owns: a fail-closed halt
  is permanent, and restarting is an explicit decision that re-runs the
  full admission — never an automatic resurrection.

  ## The adoption handshake

  Activation must run in the CALLER (a failed start returns the chain's
  own error shapes and must not take the caller down with it), but the
  generation has to record its owner's pid BEFORE it is written. So
  `start_link/1` spawns the owner UNLINKED and pending first, runs the
  activation naming that pid, then on success hands it the admitted state
  (cast). A caller that dies mid-handshake leaves either no generation
  (activation had not finished) or a generation whose owner is still
  pending — the pending owner watches the caller and reaps its own
  generation in that window, so no admission state can outlive its owner.
  """

  use GenServer

  alias AshReplicant.Sink.Impl

  @doc """
  The supervised child spec: `:temporary` (halt is permanent), id keyed by
  the sink's slot name so duplicate slots in one tree fail at start.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id =
      case slot_name_of(opts) do
        {:ok, slot_name} -> {__MODULE__, slot_name}
        :error -> __MODULE__
      end

    %{id: id, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc """
  Start the owner for one slot's pipeline. This is the body of
  `AshReplicant.start_link/1`; hosts should prefer the `child_spec/1` under
  their supervisor. Activation runs in the caller and returns the activation
  chain's own error shapes synchronously (`:sink_required`,
  `:slot_already_active`, …).

  The owner is NOT linked to the caller (deliberately): a bare caller
  finishing — or being shut down by its own test runner — must not take a
  live pipeline down mid-transaction. A host supervisor needs no link
  either: it monitors the child and delivers tree shutdown as a direct
  `:shutdown` exit signal, which the trapping owner receives and honors.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, owner} <- GenServer.start(__MODULE__, {:pending, self(), opts}) do
      case AshReplicant.activate_owner(opts, owner) do
        {:ok, admitted} ->
          GenServer.cast(owner, {:admitted, admitted})
          {:ok, owner}

        {:error, reason} ->
          true = Process.exit(owner, :kill)
          {:error, reason}
      end
    end
  end

  defp slot_name_of(opts) when is_list(opts) do
    sink = Keyword.get(opts, :sink)

    config =
      if is_atom(sink) and function_exported?(sink, :__ash_replicant_config__, 0) do
        sink.__ash_replicant_config__()
      else
        :error
      end

    case config do
      %{slot_name: slot_name} when is_binary(slot_name) and slot_name != "" ->
        {:ok, slot_name}

      _other ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  @impl GenServer
  def init({:pending, caller, opts}) do
    Process.flag(:trap_exit, true)
    Process.monitor(caller)

    # Known best-effort from the opts; a generation can only exist for the
    # sink's own slot, which is all the pending-reap window needs.
    slot_name =
      case slot_name_of(opts) do
        {:ok, slot_name} -> slot_name
        :error -> nil
      end

    {:ok, %{pending: true, slot_name: slot_name}}
  end

  @impl GenServer
  def handle_cast({:admitted, admitted}, %{pending: true}) do
    monitor = Process.monitor(admitted.pipeline_pid)

    {:noreply,
     %{
       slot_name: admitted.slot_name,
       generation_ref: admitted.generation_ref,
       pipeline_pid: admitted.pipeline_pid,
       monitor: monitor
     }}
  end

  @impl GenServer
  # The caller died before adoption. If its activation had already
  # succeeded, a generation names this process as owner — reap it (and any
  # pipeline it started); otherwise there is nothing to own.
  def handle_info({:DOWN, _ref, :process, _caller, _reason}, %{pending: true} = state) do
    reap_pending(state)
  end

  # Linked before the adoption cast was processed (host-tree shutdown in
  # that window): same pending reap.
  def handle_info({:EXIT, _pid, _reason}, %{pending: true} = state) do
    reap_pending(state)
  end

  # The pipeline exited (halt, crash, external stop): the generation is
  # dead weight — erase only OURS and leave.
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{monitor: ref, pipeline_pid: pid} = state
      ) do
    {:stop, :normal, cleanup(state)}
  end

  # A `:normal` DIRECT exit signal (Process.exit(pid, :normal)) carries no
  # shutdown intent — ignore. Post-adoption this also swallows the pending
  # caller-monitor's late :DOWN.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Host-tree shutdown or an explicit kill signal: stop the pipeline first,
  # then the same cleanup the :DOWN path performs.
  def handle_info({:EXIT, _pid, _reason}, state) do
    _ = safe_stop(state)
    {:stop, :normal, cleanup(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp reap_pending(%{pending: true} = state) do
    if slot_name = state.slot_name, do: AshReplicant.reclaim_owned_generation(slot_name, self())

    {:stop, :normal, state}
  end

  # The single cleanup home: erase ONLY this owner's generation (the
  # compare-reference erase can never touch a successor's) and drop the
  # snapshot ordinals. Both are idempotent, so racing a stop_supervised
  # that already cleaned up converges.
  defp cleanup(%{slot_name: slot_name, generation_ref: generation_ref, monitor: monitor} = state) do
    Process.demonitor(monitor, [:flush])
    :ok = AshReplicant.erase_generation(slot_name, generation_ref)
    Impl.clear_snapshot_ordinals(slot_name)
    state
  end

  defp safe_stop(%{slot_name: slot_name}) do
    Replicant.stop(slot_name)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end
end
