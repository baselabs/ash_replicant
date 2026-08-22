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

  alias AshReplicant.{Census, Status, Telemetry}
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

    state = %{
      slot_name: admitted.slot_name,
      sink: admitted.sink,
      source_identity: admitted.source_identity,
      generation_ref: admitted.generation_ref,
      pipeline_pid: admitted.pipeline_pid,
      monitor: monitor,
      census: admitted.census,
      census_timer: nil,
      census_run: nil,
      consecutive_faults: 0,
      last_census: :none
    }

    {:noreply, schedule_next_census(state)}
  end

  # O02: the status derivation's facts seam. The owner answers in BOTH
  # phases (an unmatched call would exit the GenServer and kill a healthy
  # activation), and a catch-all keeps every other caller harmless.
  @impl GenServer
  def handle_call(:ash_replicant_status, _from, %{pending: true} = state) do
    {:reply, %{phase: :pending}, state}
  end

  def handle_call(:ash_replicant_status, _from, state) do
    {:reply, status_facts(state), state}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  defp status_facts(state) do
    %{
      phase: :admitted,
      pipeline_alive: is_pid(state.pipeline_pid) and Process.alive?(state.pipeline_pid),
      last_census: Map.get(state, :last_census, :none),
      census_enabled?: match?(%{enabled?: true}, state.census),
      consecutive_faults: state.consecutive_faults
    }
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

  def handle_info({:census_tick, token}, %{census_timer: %{token: token}} = state) do
    state = %{state | census_timer: nil}
    {:noreply, start_census(state)}
  end

  def handle_info(
        {:census_result, token, %{state: {:drifted, _check, _reason}} = report},
        %{census_run: %{token: token, timed_out?: true} = run} = state
      ) do
    cancel_census_run(run)
    apply_census_report(report, %{state | census_run: nil})
  end

  def handle_info(
        {:census_result, token, %{state: _state, checks: _checks} = report},
        %{
          census_run: %{
            token: token,
            monitor: monitor,
            timeout: timeout,
            timed_out?: false
          }
        } = state
      ) do
    cancel_timer(timeout)
    Process.demonitor(monitor, [:flush])
    apply_census_report(report, %{state | census_run: nil})
  end

  def handle_info(
        {:census_timeout, token},
        %{census_run: %{token: token, pid: pid} = run} = state
      ) do
    Process.exit(pid, :kill)
    {:noreply, %{state | census_run: %{run | timed_out?: true}}}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{census_run: %{monitor: monitor, pid: pid, timed_out?: timed_out?} = run} = state
      ) do
    cancel_timer(run.timeout)

    reason = if timed_out?, do: :census_timeout, else: :census_checker_fault
    report = census_fault_report(reason)
    apply_census_report(report, %{state | census_run: nil})
  end

  # The pipeline exited (halt, crash, external stop): the generation is
  # dead weight — erase only OURS and leave. Replicant 1.x discards the
  # halt reason at teardown (the halting caller owns the distinguishing
  # signal), so an unexplained death records the GENERIC terminal cause —
  # but never over a tombstone a precise writer already left.
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{monitor: ref, pipeline_pid: pid} = state
      ) do
    Status.record_if_absent(
      state.slot_name,
      state.sink,
      state.source_identity,
      :pipeline_terminated
    )

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
    if slot_name = state.slot_name do
      AshReplicant.reclaim_owned_generation(slot_name, self())
      # The reaped pipeline ended by the handshake aborting — a teardown
      # write hazard, so the node-local leg is the whole record.
      Status.record_node_local(slot_name, :pipeline_terminated)
    end

    {:stop, :normal, state}
  end

  # The single cleanup home: erase ONLY this owner's generation (the
  # compare-reference erase can never touch a successor's) and drop the
  # snapshot ordinals. Both are idempotent, so racing a stop_supervised
  # that already cleaned up converges.
  defp cleanup(%{slot_name: slot_name, generation_ref: generation_ref, monitor: monitor} = state) do
    state = stop_census(state)
    Process.demonitor(monitor, [:flush])
    :ok = AshReplicant.erase_generation(slot_name, generation_ref)
    Impl.clear_snapshot_ordinals(slot_name)
    state
  end

  defp schedule_next_census(%{census: %{enabled?: false}} = state), do: state

  defp schedule_next_census(%{census_timer: nil, census_run: nil, census: census} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:census_tick, token}, Census.next_delay(census))
    %{state | census_timer: %{token: token, timer: timer}}
  end

  defp schedule_next_census(state), do: state

  defp start_census(%{census: %{enabled?: false}} = state), do: state
  defp start_census(%{census_run: run} = state) when not is_nil(run), do: state

  defp start_census(state) do
    parent = self()
    token = make_ref()
    slot_name = state.slot_name
    sink = state.sink

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:census_result, token, Census.run(slot_name, sink)})
      end)

    timeout = Process.send_after(self(), {:census_timeout, token}, state.census.timeout_ms)

    %{
      state
      | census_run: %{
          token: token,
          pid: pid,
          monitor: monitor,
          timeout: timeout,
          timed_out?: false
        }
    }
  end

  defp apply_census_report(%{state: :healthy}, state) do
    Telemetry.event(
      [:ash_replicant, :census, :passed],
      %{count: 1},
      %{slot_name: state.slot_name}
    )

    {:noreply, schedule_next_census(%{state | consecutive_faults: 0, last_census: :healthy})}
  end

  defp apply_census_report(
         %{state: {:faulted, check, reason}},
         state
       ) do
    faults = state.consecutive_faults + 1

    Telemetry.event(
      [:ash_replicant, :census, :faulted],
      %{count: 1},
      %{slot_name: state.slot_name, kind: check, reason: reason}
    )

    state = %{state | consecutive_faults: faults, last_census: :faulted}

    if faults >= state.census.max_consecutive_faults do
      halt_for_census(state, check, :census_unverifiable)
    else
      {:noreply, schedule_next_census(state)}
    end
  end

  defp apply_census_report(
         %{state: {:drifted, check, reason}},
         state
       ) do
    halt_for_census(state, check, reason)
  end

  defp halt_for_census(state, check, reason) do
    Telemetry.event(
      [:ash_replicant, :census, :halted],
      %{count: 1},
      %{slot_name: state.slot_name, kind: check, reason: reason}
    )

    # The node-local tombstone leg is written at the DECISION (always
    # legible, even with the destination down); the durable leg waits for
    # termination — after `safe_stop` no admitted delivery can still commit
    # its terminal-clear (O02 design D3).
    tombstone = Status.record_node_local(state.slot_name, reason)
    _ = safe_stop(state)
    Status.record_durable(state.slot_name, state.sink, state.source_identity, tombstone)
    {:stop, :normal, cleanup(state)}
  end

  defp census_fault_report(reason) do
    Census.fault_report(reason)
  end

  defp stop_census(state) do
    cancel_census_timer(Map.get(state, :census_timer))
    cancel_census_run(Map.get(state, :census_run))

    state
    |> Map.put(:census_timer, nil)
    |> Map.put(:census_run, nil)
  end

  defp cancel_census_timer(%{timer: timer}), do: cancel_timer(timer)
  defp cancel_census_timer(_other), do: :ok

  defp cancel_census_run(%{pid: pid, monitor: monitor, timeout: timeout}) do
    cancel_timer(timeout)
    Process.demonitor(monitor, [:flush])
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp cancel_census_run(_other), do: :ok

  defp cancel_timer(timer) when is_reference(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp cancel_timer(_other), do: :ok

  defp safe_stop(%{slot_name: slot_name}) do
    Replicant.stop(slot_name)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end
end
