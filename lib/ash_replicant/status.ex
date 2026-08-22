defmodule AshReplicant.Status do
  @moduledoc """
  O02 / issue #12 / ADR-0019 ¶5: the ONE runtime state model.

  `AshReplicant.status/1` answers the closed public five — `:healthy`,
  `:catching_up`, `{:halted, reason}`, `{:misconfigured, reason}`,
  `:not_started` — and `derive/2` exposes the six-state generation lifecycle
  underneath (`:activating`, `:ready`, `:degraded`, `:halted`, `:stopped`,
  `:superseded`; `:absent` when no generation exists to describe).

  The answer is DERIVED, never stored: precedence walks the live owner's own
  facts, then the node-local generation entry (a dead owner is a fault,
  never ready), then the tombstone legs, then nothing. A generation whose
  owner is gone can therefore never report `:ready`/`:healthy`, and a
  terminal cause outlives the processes that knew it through the durable
  tombstone on the checkpoint row.

  Healthy requires a live owner, a live pipeline, an enabled census whose
  last run passed, and no in-flight snapshot — owner liveness alone is
  insufficient (ADR-0019). A disabled or not-yet-run census conservatively
  reports `:catching_up`.

  ## Tombstones

  A tombstone is the bounded, value-free record of WHY a generation ended:
  `cause` (a closed reason atom or the one structural tuple), `class`
  (`:halt` | `:misconfigured` | `:stopped`), and `at` (a timestamp). The
  node-local leg (`:persistent_term`, keyed by slot) is written always and
  first; the durable leg is best-effort on the checkpoint row, only when
  that row already exists — a tombstone never creates watermark-less rows.
  Every admitted checkpoint write (bind and advance) clears the durable
  leg, so a stale cause cannot outlive a successor generation. Nothing in a
  tombstone renders a row value, message prefix, or progress token.

  Writers are the parties that know the cause: the sink's halt paths (the
  scrubbed reason), the owner's census halt, and `stop_supervised/1` (an
  operator stop). Replicant 1.x discards halt reasons at teardown, so an
  unexplained pipeline death records the generic `:pipeline_terminated` —
  but only when no tombstone is already present.
  """

  alias AshReplicant.Destination.Generation
  alias AshReplicant.Snapshot.{Provenance, State}
  alias AshReplicant.Telemetry

  require Ash.Query

  @type lifecycle ::
          :activating | :ready | :degraded | :halted | :stopped | :superseded | :absent
  @type reason :: atom() | {:invalid_destination_config, atom()}
  @type class :: :halt | :misconfigured | :stopped
  @type public ::
          :healthy
          | :catching_up
          | {:halted, reason()}
          | {:misconfigured, reason()}
          | :not_started

  defmodule Tombstone do
    @moduledoc false
    @enforce_keys [:cause, :class, :at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            cause: AshReplicant.Status.reason(),
            class: AshReplicant.Status.class(),
            at: DateTime.t()
          }
  end

  # The drift/mapping reasons an OPERATOR fixes in configuration before a
  # restart can succeed: identity rebinding, contract drift, and source
  # coverage/mapping gaps. Everything else — census fault budgets, delivery
  # and snapshot integrity, unexplained deaths — is a halt; the default is
  # fail-closed (over-alert, never silently "just config").
  @misconfigured_reasons [
    :source_identity_rebound,
    :source_identity_mismatch,
    :publication_contract_incompatible,
    :duplicate_source,
    :source_table_missing,
    :source_table_unmapped,
    :source_column_missing,
    :source_column_unmapped,
    :source_type_invalid,
    :source_replica_identity
  ]

  # The closed halt atoms a persisted cause may decode back into
  # (`AshReplicant.Error`'s mint inventory minus the misconfigured list,
  # plus this module's own terminal atoms).
  @closed_halt_reasons [
    :sink_failed,
    :tenant_required,
    :tenant_resolution_failed,
    :schema_change_destructive,
    :truncate_halt,
    :config_invalid,
    :source_timeline_changed,
    :source_behind_watermark,
    :source_skip_stale,
    :message_prefix_unmapped,
    :checkpoint_unbound,
    :checkpoint_adopt_conflict,
    :checkpoint_adopt_invalid,
    :checkpoint_legacy_rows_present,
    :snapshot_state_invalid,
    :snapshot_provenance_unavailable,
    :snapshot_scope_incomplete,
    :append_origin_gap,
    :append_origin_invalid,
    :append_frontier_divergent,
    :census_timeout,
    :census_checker_fault,
    :census_source_unreachable,
    :census_unverifiable,
    :pipeline_terminated,
    :owner_lost,
    :operator_stopped,
    :tombstone_unknown
  ]

  # The closed structural tags of the one tuple-shaped reason
  # (`AshReplicant.Destination`'s own @type is the authority; this set is
  # pinned by test against the mint inventory).
  @destination_config_tags [
    :adapter,
    :code_fingerprint,
    :effective_repo,
    :identifier,
    :notifier_load_drift,
    :notifier_load_probe_failed,
    :notifier_load_unadmitted,
    :onetime_store,
    :reflection_failed,
    :repo,
    :shape
  ]

  @tuple_prefix "invalid_destination_config/"

  @owner_call_timeout 500

  # --- the public five (ADR-0019 ¶5 closed set) ---

  @doc """
  The coherent public status of a sink's slot. `sink` is the module built
  with `use AshReplicant.Sink` — it names the slot, the repo, and the
  checkpoint resource, which is exactly what the durable tombstone leg
  needs when no live generation remains to ask.
  """
  @spec status(module()) :: public()
  def status(sink), do: derive(sink).status

  @doc """
  The full derivation: the public five, the six-state lifecycle, and the
  typed value-free evidence they came from. `timeout` bounds the ask of a
  live owner (a busy owner is not a dead one).
  """
  @spec derive(module(), pos_integer()) :: %{
          status: public(),
          lifecycle: lifecycle(),
          evidence: map()
        }
  def derive(sink, timeout \\ @owner_call_timeout)
      when is_atom(sink) and is_integer(timeout) and timeout > 0 do
    case sink_config(sink) do
      {:error, reason} ->
        %{status: {:misconfigured, reason}, lifecycle: :absent, evidence: %{}}

      {:ok, config} ->
        derive_slot(config, timeout)
    end
  end

  defp derive_slot(config, timeout) do
    key = {AshReplicant, config.slot_name}
    checkpoint = durable_facts(config)

    case :persistent_term.get(key, :none) do
      %Generation{owner: owner} when is_pid(owner) ->
        derive_entry(owner, checkpoint, timeout)

      _absent ->
        derive_tombstone(checkpoint)
    end
  end

  # A live entry outranks every tombstone: the owner is asked, and only a
  # CONFIRMED dead owner falls to the fault reading.
  defp derive_entry(owner, checkpoint, timeout) do
    if owner_alive?(owner) do
      case owner_facts(owner, timeout) do
        {:ok, facts} ->
          lifecycle = live_lifecycle(facts, checkpoint)
          evidence = %{owner: :live, census: facts, checkpoint: checkpoint}
          %{status: public_of(lifecycle), lifecycle: lifecycle, evidence: evidence}

        :unresponsive ->
          # The call timed out or answered garbage while the owner is alive
          # (typically blocked stopping the pipeline): the conservative
          # live bucket, never the owner-lost fault.
          %{status: :catching_up, lifecycle: :degraded, evidence: %{owner: :unresponsive}}
      end
    else
      superseded()
    end
  end

  defp live_lifecycle(%{phase: :pending}, _checkpoint), do: :activating

  defp live_lifecycle(
         %{phase: :admitted, pipeline_alive: true, census_enabled?: true, last_census: :healthy},
         checkpoint
       ) do
    if snapshot_in_flight?(checkpoint), do: :degraded, else: :ready
  end

  defp live_lifecycle(%{phase: :admitted}, _checkpoint), do: :degraded

  defp superseded do
    # A dead owner means mirroring has stopped or stops at the next
    # callback (admission fails closed) — a fault, never "not started".
    %{status: {:halted, :owner_lost}, lifecycle: :superseded, evidence: %{owner: :dead}}
  end

  defp derive_tombstone(checkpoint) do
    case node_local(checkpoint[:slot_name]) || durable_tombstone(checkpoint) do
      nil ->
        %{status: :not_started, lifecycle: :absent, evidence: %{}}

      %Tombstone{cause: cause, class: :stopped} ->
        %{
          status: :not_started,
          lifecycle: :stopped,
          evidence: %{tombstone: cause_class(cause, :stopped)}
        }

      %Tombstone{cause: cause, class: :misconfigured} ->
        %{
          status: {:misconfigured, cause},
          lifecycle: :halted,
          evidence: %{tombstone: cause_class(cause, :misconfigured)}
        }

      %Tombstone{cause: cause, class: :halt} ->
        %{
          status: {:halted, cause},
          lifecycle: :halted,
          evidence: %{tombstone: cause_class(cause, :halt)}
        }
    end
  end

  defp cause_class(cause, class), do: %{cause: cause, class: class}

  # The public five are a CLOSED set: the collapse of the LIVE states (the
  # superseded fault and the tombstone-only states build their public
  # answer directly at their own sites).
  defp public_of(:activating), do: :catching_up
  defp public_of(:ready), do: :healthy
  defp public_of(:degraded), do: :catching_up

  # --- the owner facts seam ---

  defp owner_facts(owner, timeout) do
    case GenServer.call(owner, :ash_replicant_status, timeout) do
      %{phase: :admitted} = facts -> {:ok, facts}
      %{phase: :pending} = facts -> {:ok, facts}
      _garbage -> :unresponsive
    end
  catch
    :exit, _timeout_or_noproc -> :unresponsive
  end

  # --- classification: the closed cause→class table ---

  @doc """
  The class of a terminal cause. `:operator_stopped` is a stop; the
  identity/contract/mapping drift an operator fixes in configuration is
  `:misconfigured`; everything else — including any reason not enumerated
  here — fails closed to `:halt`.
  """
  @spec classify(reason()) :: class()
  def classify(:operator_stopped), do: :stopped

  def classify({:invalid_destination_config, tag}) when tag in @destination_config_tags,
    do: :misconfigured

  def classify(reason) when reason in @misconfigured_reasons, do: :misconfigured
  def classify(_unlisted), do: :halt

  # --- tombstone encoding: closed strings on the durable row ---

  @doc false
  @spec encode_cause(reason()) :: String.t()
  def encode_cause({:invalid_destination_config, tag}) when tag in @destination_config_tags,
    do: @tuple_prefix <> Atom.to_string(tag)

  def encode_cause(reason) when is_atom(reason), do: Atom.to_string(reason)
  def encode_cause(_other), do: Atom.to_string(:tombstone_unknown)

  @doc """
  Decode a persisted cause back into `{class, reason}`. Only the closed
  mint sets decode — a foreign or corrupted string (a different library
  version, a tampered row) falls back to `{:halt, :tombstone_unknown}` and
  never mints atoms from data.
  """
  @spec decode_cause(term()) :: {class(), reason()}
  def decode_cause(@tuple_prefix <> tag_text) do
    tag = String.to_existing_atom(tag_text)

    if tag in @destination_config_tags do
      {:misconfigured, {:invalid_destination_config, tag}}
    else
      fallback()
    end
  rescue
    _argument_error -> fallback()
  catch
    _kind, _reason -> fallback()
  end

  def decode_cause(text) when is_binary(text) do
    reason = String.to_existing_atom(text)

    cond do
      reason in @misconfigured_reasons -> {:misconfigured, reason}
      reason in @closed_halt_reasons -> {classify(reason), reason}
      true -> fallback()
    end
  rescue
    _error -> fallback()
  catch
    _kind, _reason -> fallback()
  end

  def decode_cause(_other), do: fallback()

  defp fallback, do: {:halt, :tombstone_unknown}

  # --- tombstone writers ---

  @doc """
  Record a terminal cause: the node-local leg always, then the durable leg
  best-effort. Never raises — a tombstone must not turn a halt into a
  crash — and never writes a row the checkpoint does not already have.
  """
  @spec record_terminal(String.t(), module() | nil, map() | nil, reason()) :: :ok
  def record_terminal(slot_name, sink, identity, reason) do
    tombstone = record_node_local(slot_name, reason)
    record_durable(slot_name, sink, identity, tombstone)
  end

  @doc """
  The always-writable leg. Returns the tombstone it wrote.
  """
  @spec record_node_local(String.t(), reason()) :: Tombstone.t()
  def record_node_local(slot_name, reason) when is_binary(slot_name) do
    tombstone = %Tombstone{cause: reason, class: classify(reason), at: DateTime.utc_now()}
    :persistent_term.put({__MODULE__, slot_name}, tombstone)
    tombstone
  end

  @doc false
  @spec record_if_absent(String.t(), module() | nil, map() | nil, reason()) :: :ok
  def record_if_absent(slot_name, sink, identity, reason) do
    if is_nil(node_local(slot_name)) do
      record_terminal(slot_name, sink, identity, reason)
    else
      :ok
    end
  end

  @doc """
  The durable leg on the checkpoint row — only when that row already
  exists (locked read; a tombstone never creates a watermark-less row).
  A sink or identity the caller cannot resolve (nothing live to ask) is a
  quiet skip, not a write failure.
  """
  @spec record_durable(String.t(), module() | nil, map() | nil, Tombstone.t()) :: :ok
  def record_durable(slot_name, sink, identity, %Tombstone{} = tombstone)
      when is_binary(slot_name) do
    with {:ok, config} <- sink_config(sink),
         identity when is_map(identity) <- identity,
         {:ok, system_id} <- closed_binary(identity.system_identifier),
         {:ok, database} <- closed_binary(identity.database),
         true <- is_pid(Process.whereis(config.repo)) do
      persist_tombstone(config, system_id, database, tombstone)
    else
      _structurally_unavailable -> telemetry_write_failed(slot_name, :destination_unavailable)
    end

    :ok
  end

  @doc """
  A successful activation clears the node-local leg — the live generation
  is the newer fact.
  """
  @spec clear_node_local(String.t()) :: :ok
  def clear_node_local(slot_name) when is_binary(slot_name) do
    :persistent_term.erase({__MODULE__, slot_name})
    :ok
  end

  defp closed_binary(value) when is_binary(value) and value != "", do: {:ok, value}
  defp closed_binary(_other), do: :error

  defp persist_tombstone(config, system_id, database, %Tombstone{} = tombstone) do
    result =
      config.repo.transaction(fn ->
        rows =
          config.checkpoint_resource
          |> Ash.Query.filter(
            slot_name == ^config.slot_name and source_system_id == ^system_id and
              source_database == ^database
          )
          |> Ash.read!(lock: :for_update, authorize?: false)
          |> List.wrap()

        case rows do
          [_row] ->
            Ash.create!(
              config.checkpoint_resource,
              %{
                source_system_id: system_id,
                source_database: database,
                slot_name: config.slot_name,
                terminal_cause: encode_cause(tombstone.cause),
                terminal_class: Atom.to_string(tombstone.class),
                terminal_at: tombstone.at
              },
              action: :upsert,
              upsert?: true,
              upsert_identity: :source_slot,
              upsert_fields: [:terminal_cause, :terminal_class, :terminal_at],
              authorize?: false,
              return_notifications?: true
            )

            :ok

          _absent_or_ambiguous ->
            :skip
        end
      end)

    case result do
      {:ok, _} -> :ok
      _failed -> telemetry_write_failed(config.slot_name, :destination_write_failed)
    end
  rescue
    _error -> telemetry_write_failed(config.slot_name, :destination_write_failed)
  catch
    _kind, _reason -> telemetry_write_failed(config.slot_name, :destination_write_failed)
  end

  defp telemetry_write_failed(slot_name, reason) do
    Telemetry.event([:ash_replicant, :status, :tombstone_write_failed], %{count: 1}, %{
      slot_name: slot_name,
      reason: reason
    })
  end

  # --- tombstone readers ---

  defp node_local(slot_name) when is_binary(slot_name) do
    case :persistent_term.get({__MODULE__, slot_name}, nil) do
      %Tombstone{} = tombstone -> tombstone
      _other -> nil
    end
  end

  defp node_local(_other), do: nil

  # One guarded destination read serving both the durable tombstone leg and
  # the in-flight snapshot leg. A down or absent repo skips the legs — the
  # census remains the authority on destination validity, and status never
  # starts a repo.
  defp durable_facts(config) do
    repo = Map.get(config, :repo)

    if is_atom(repo) and not is_nil(repo) and is_pid(Process.whereis(repo)) do
      read_durable_facts(config)
    else
      %{slot_name: config.slot_name}
    end
  end

  defp read_durable_facts(config) do
    rows =
      config.checkpoint_resource
      |> Ash.Query.filter(slot_name == ^config.slot_name)
      |> Ash.read!(authorize?: false)
      |> List.wrap()

    case rows do
      [row] ->
        %{
          slot_name: config.slot_name,
          snapshot_state: Map.get(row, :snapshot_state),
          tombstone: durable_tombstone_from(row)
        }

      _none_or_ambiguous ->
        %{slot_name: config.slot_name}
    end
  rescue
    _error -> %{slot_name: config.slot_name}
  catch
    _kind, _reason -> %{slot_name: config.slot_name}
  end

  defp durable_tombstone(%{tombstone: %Tombstone{} = tombstone}), do: tombstone
  defp durable_tombstone(_checkpoint), do: nil

  defp durable_tombstone_from(row) do
    case Map.get(row, :terminal_cause) do
      cause when is_binary(cause) ->
        {class, reason} = decode_cause(cause)
        %Tombstone{cause: reason, class: class, at: Map.get(row, :terminal_at)}

      _nil ->
        nil
    end
  end

  # In-flight snapshot evidence: `:armed`/`:active` attempts mean the
  # pipeline is still catching up. Presence WITHOUT a decodable envelope is
  # skipped (fail-closed on readiness is the census's call, not a guess
  # here); no progress-token bytes ever leave this function.
  defp snapshot_in_flight?(checkpoint) do
    case Map.get(checkpoint, :snapshot_state) do
      binary when is_binary(binary) ->
        with {:ok, keys} <- Provenance.keys(),
             {:ok, %State{} = state} <- State.decode(binary, keys) do
          state.status in [:armed, :active]
        else
          _undecodable -> false
        end

      _nil ->
        false
    end
  end

  # --- shared config admission (the operator-function shape) ---

  defp sink_config(sink) when is_atom(sink) do
    if Code.ensure_loaded?(sink) and function_exported?(sink, :__ash_replicant_config__, 0) do
      case safe_config(sink) do
        %{repo: repo, checkpoint_resource: checkpoint, slot_name: slot}
        when is_atom(repo) and is_atom(checkpoint) and is_binary(slot) and slot != "" ->
          {:ok, %{repo: repo, checkpoint_resource: checkpoint, slot_name: slot}}

        _invalid ->
          {:error, :sink_required}
      end
    else
      {:error, :sink_required}
    end
  end

  defp sink_config(_other), do: {:error, :sink_required}

  defp safe_config(sink) do
    sink.__ash_replicant_config__()
  rescue
    _error -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  # The ADR-0014 owner-liveness check, mirrored from `AshReplicant`'s own:
  # remote pids cannot be checked locally and cannot occur on the
  # single-node runtime Replicant 1.x guarantees; treat them as unowned.
  defp owner_alive?(owner) when is_pid(owner) do
    node(owner) == node() and Process.alive?(owner)
  end
end
