defmodule AshReplicant.Doctor do
  @moduledoc """
  The read-only operator diagnosis surface behind `AshReplicant.preflight/1`,
  `AshReplicant.doctor/1`, `mix ash_replicant.preflight`, and
  `mix ash_replicant.doctor`.

  ## What it answers

  `:preflight` answers *may this pipeline start?* — source reachability,
  privileges, identity, version, coverage, replica identity, slot shape and
  retention, destination admission, and dependency versions. It never reads a
  checkpoint, so it is correct before the first activation.

  `:doctor` is a strict superset that adds the durable-state classes a deployed
  pipeline has: checkpoint state, contract drift, and node-local runtime
  readiness.

  ## It performs no writes

  Three independent legs, none of which trusts the other:

    1. Every source statement passes `AshReplicant.Doctor.Probe.admit!/1`, a
       fail-closed read-only admission that holds with no database present.
    2. The probe connection is opened `default_transaction_read_only=on`, so
       PostgreSQL refuses a write the admission missed.
    3. The destination checkpoint is read through the resource's `:read` action
       with `authorize?: false` and NO lock — `lock: :for_update` is write
       intent and is never passed.

  ## Output

  Both renderings derive from one `AshReplicant.Doctor.Report` of
  `AshReplicant.Doctor.Check` structs, so machine and operator output cannot
  disagree. Reasons come from a closed vocabulary; `detail` carries structural
  identifiers only, admitted by the allowlist below.

  ## Runtime readiness is node-local

  `:persistent_term` is per-node, so `mix ash_replicant.doctor` — a separate OS
  process — always reports `:runtime_generation` absent. Call
  `AshReplicant.doctor/1` from inside the running application (a remote console
  or a health endpoint) for the real answer.
  """

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Destination.Generation
  alias AshReplicant.Doctor.{Check, Probe, Report}
  alias AshReplicant.Error
  alias AshReplicant.Snapshot.State

  # Duplicated from `mix.exs` because `mix.exs` is not loadable from a release.
  # `AshReplicant.DoctorTest` asserts the literals are equal, so changing one
  # without the other goes red.
  @replicant_requirement ">= 1.2.3 and < 2.0.0-0"
  @ash_requirement ">= 3.31.3 and < 4.0.0-0"

  # The PostgreSQL 15 through 18 support matrix as `server_version_num`.
  @source_release_floor 150_000
  @source_release_ceiling 190_000

  @expected_plugin "pgoutput"

  # The ONLY reasons whose `%Error{}.shape` may reach operator output: every
  # one is a catalog identifier (qualified table, column, PostgreSQL type name,
  # `relreplident` flag). Fail-closed — an unrecognised reason yields no detail.
  # `:source_identity_mismatch` is deliberately ABSENT: its shape embeds the
  # source database name.
  @detail_reasons [
    :config_invalid,
    :source_column_missing,
    :source_column_unmapped,
    :source_replica_identity,
    :source_skip_stale,
    :source_table_missing,
    :source_table_unmapped,
    :source_type_invalid
  ]

  @preflight_checks [
    :dependency_requirements,
    :sink_configuration,
    :destination_repo,
    :source_reachable,
    :source_release,
    :source_privileges,
    :source_identity,
    :source_coverage,
    :source_replica_identity,
    :slot_presence,
    :slot_retention
  ]

  @doctor_only_checks [
    :checkpoint_state,
    :contract_drift,
    :runtime_generation
  ]

  @doc "This package's declared Replicant requirement (kept equal to `mix.exs`)."
  @spec replicant_requirement() :: String.t()
  def replicant_requirement, do: @replicant_requirement

  @doc "This package's declared Ash requirement (kept equal to `mix.exs`)."
  @spec ash_requirement() :: String.t()
  def ash_requirement, do: @ash_requirement

  @doc """
  The ordered check names a mode reports. `:doctor` is a strict superset of
  `:preflight`.
  """
  @spec check_names(Report.mode()) :: [atom()]
  def check_names(:preflight), do: @preflight_checks
  def check_names(:doctor), do: @preflight_checks ++ @doctor_only_checks

  # --- runtime and dependency classes ---

  @doc """
  The loaded dependency versions against this package's declared requirements.
  A version mismatch here is silent at runtime — the callbacks simply behave
  differently than the adapter expects — which is why it is a named check.
  """
  @spec check_dependency_requirements(%{optional(atom()) => String.t() | nil}) :: Check.t()
  def check_dependency_requirements(loaded \\ loaded_requirements()) do
    requirements = [{:replicant, @replicant_requirement}, {:ash, @ash_requirement}]

    Enum.find_value(requirements, pass(:dependency_requirements, :runtime, :ok), fn {app,
                                                                                     requirement} ->
      case dependency_verdict(Map.get(loaded, app), requirement) do
        :ok -> nil
        reason -> fail(:dependency_requirements, :runtime, reason, Atom.to_string(app))
      end
    end)
  end

  defp dependency_verdict(nil, _requirement), do: :dependency_missing

  defp dependency_verdict(version, requirement) do
    if Version.match?(version, requirement), do: :ok, else: :dependency_version_mismatch
  rescue
    _invalid_version -> :dependency_version_mismatch
  end

  defp loaded_requirements do
    Map.new([:replicant, :ash], fn app -> {app, loaded_version(app)} end)
  end

  defp loaded_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Node-local runtime readiness: whether an admitted generation exists for the
  slot in THIS node and its owner is alive. A separate OS process (a Mix task)
  legitimately sees none — that is reported, never inferred away.
  """
  @spec check_runtime_generation(String.t()) :: Check.t()
  def check_runtime_generation(slot_name) when is_binary(slot_name) do
    case :persistent_term.get({AshReplicant, slot_name}, :none) do
      %Generation{owner: owner} when is_pid(owner) ->
        if node(owner) == node() and Process.alive?(owner),
          do: pass(:runtime_generation, :runtime, :generation_live),
          else: fail(:runtime_generation, :runtime, :generation_owner_dead)

      _absent ->
        warn(:runtime_generation, :runtime, :generation_absent)
    end
  end

  # --- source classes ---

  @doc "Source reachability. Unreachable fails closed; it is never a warning."
  @spec check_source_reachable(:ok | {:error, term()}) :: Check.t()
  def check_source_reachable(:ok), do: pass(:source_reachable, :source, :ok)

  def check_source_reachable({:error, _reason}),
    do: fail(:source_reachable, :source, :source_unreachable)

  @doc """
  The source PostgreSQL version against the supported matrix. Below the floor is
  a failure; above the tested ceiling is a warning, because a newer major is
  likely fine and refusing it would be a false negative.
  """
  @spec check_source_release(integer() | nil) :: Check.t()
  def check_source_release(version) when is_integer(version) do
    cond do
      version < @source_release_floor ->
        fail(:source_release, :source, :source_release_unsupported)

      version >= @source_release_ceiling ->
        warn(:source_release, :source, :source_release_untested)

      true ->
        pass(:source_release, :source, :ok)
    end
  end

  def check_source_release(_unknown), do: warn(:source_release, :source, :source_release_unknown)

  @doc """
  The connecting role's capability: REPLICATION (or superuser) for the stream,
  and `SELECT` on every published table for the snapshot. Both are their own
  reason — a privilege problem is not an unreachable source, and an operator
  who conflates them looks in the wrong place.
  """
  @spec check_privileges(%{
          superuser?: boolean(),
          replication?: boolean(),
          tables: [{String.t(), String.t(), boolean()}]
        }) :: Check.t()
  def check_privileges(%{superuser?: superuser?, replication?: replication?, tables: tables}) do
    denied =
      tables
      |> Enum.reject(fn {_schema, _table, allowed?} -> allowed? end)
      |> Enum.map(fn {schema, table, _allowed?} -> "#{schema}.#{table}" end)
      |> Enum.sort()

    cond do
      not (superuser? or replication?) ->
        fail(:source_privileges, :source, :privilege_replication_missing)

      denied != [] ->
        fail(:source_privileges, :source, :privilege_select_missing, Enum.join(denied, ","))

      true ->
        pass(:source_privileges, :source, :ok)
    end
  end

  @doc "Configured source identity against the identity the probe connection reports."
  @spec check_source_identity(:ok | {:error, Error.t()}) :: Check.t()
  def check_source_identity(:ok), do: pass(:source_identity, :source, :ok)

  def check_source_identity({:error, %Error{} = error}),
    do: from_error(:source_identity, :source, error)

  @doc """
  The strict source-coverage verdict (`AshReplicant.Coverage.evaluate/3`).

  A replica-identity violation reported here is NOT counted twice: it has its
  own check, judged independently, because `evaluate/3` short-circuits and would
  otherwise hide replica identity behind an earlier coverage rule.
  """
  @spec check_coverage(:ok | {:error, Error.t()}) :: Check.t()
  def check_coverage(:ok), do: pass(:source_coverage, :source, :ok)

  def check_coverage({:error, %Error{reason: :source_replica_identity}}),
    do: pass(:source_coverage, :source, :ok)

  def check_coverage({:error, %Error{} = error}), do: from_error(:source_coverage, :source, error)

  @doc """
  The replica-identity rule, judged independently of the rest of coverage
  (`AshReplicant.Coverage.replica_identity_check/2`).
  """
  @spec check_replica_identity(:ok | {:error, Error.t()}) :: Check.t()
  def check_replica_identity(:ok), do: pass(:source_replica_identity, :source, :ok)

  def check_replica_identity({:error, %Error{} = error}),
    do: from_error(:source_replica_identity, :source, error)

  # --- slot classes ---

  @doc """
  The slot's shape. An ABSENT slot warns rather than fails: the first activation
  creates it, so refusing here would block a legitimate first start.
  """
  @spec check_slot(map() | nil) :: Check.t()
  def check_slot(nil), do: warn(:slot_presence, :slot, :slot_absent)

  def check_slot(%{slot_type: slot_type, plugin: plugin, active: active}) do
    cond do
      slot_type != "logical" -> fail(:slot_presence, :slot, :slot_type_invalid)
      plugin != @expected_plugin -> fail(:slot_presence, :slot, :slot_plugin_invalid)
      active -> pass(:slot_presence, :slot, :slot_active)
      true -> pass(:slot_presence, :slot, :slot_inactive)
    end
  end

  @doc """
  The retention horizon — the alert that must fire BEFORE recovery becomes
  impossible, which is why `:retention_at_risk` and `:retention_lost` are
  separate reasons at separate severities.

  A durable watermark whose slot is GONE is already lost: the WAL behind that
  position cannot be re-read.
  """
  @spec check_retention(map() | nil, integer() | nil) :: Check.t()
  def check_retention(nil, watermark) when is_integer(watermark),
    do: fail(:slot_retention, :slot, :retention_lost)

  def check_retention(nil, _no_watermark), do: warn(:slot_retention, :slot, :retention_unknown)

  def check_retention(%{wal_status: wal_status, exhausted: exhausted}, _watermark) do
    cond do
      wal_status == "lost" -> fail(:slot_retention, :slot, :retention_lost)
      exhausted -> warn(:slot_retention, :slot, :retention_at_risk)
      wal_status == "unreserved" -> warn(:slot_retention, :slot, :retention_at_risk)
      wal_status == "extended" -> pass(:slot_retention, :slot, :retention_extended)
      wal_status == "reserved" -> pass(:slot_retention, :slot, :retention_reserved)
      true -> warn(:slot_retention, :slot, :retention_unknown)
    end
  end

  # --- checkpoint and contract classes ---

  @doc """
  The durable checkpoint's state. An envelope that will not decode FAILS as
  unknown state: the operator cannot tell where delivery is, and activation
  fails closed on exactly the same condition.
  """
  @spec check_checkpoint(map() | nil, keyword()) :: Check.t()
  def check_checkpoint(nil, _keys), do: pass(:checkpoint_state, :checkpoint, :checkpoint_absent)

  def check_checkpoint(row, keys) when is_map(row) do
    case snapshot_state_verdict(Map.get(row, :snapshot_state), keys) do
      :ok -> watermark_verdict(Map.get(row, :commit_lsn))
      reason -> fail(:checkpoint_state, :checkpoint, reason)
    end
  end

  defp snapshot_state_verdict(nil, _keys), do: :ok

  defp snapshot_state_verdict(encoded, keys) do
    case State.decode(encoded, keys) do
      {:ok, _state} -> :ok
      {:error, :unknown_key_version} -> :checkpoint_state_key_unknown
      {:error, _undecodable} -> :checkpoint_state_unknown
    end
  end

  defp watermark_verdict(nil),
    do: pass(:checkpoint_state, :checkpoint, :checkpoint_initialized)

  defp watermark_verdict(_lsn), do: pass(:checkpoint_state, :checkpoint, :checkpoint_bound)

  @doc """
  Contract drift, through the SAME set-monotone classifier activation binds with
  (`AshReplicant.Checkpoint.Identity.classify_stored_contract/3`) — a doctor that
  judged drift by its own rule could disagree with the runtime it diagnoses.

  Set-monotone growth WARNS rather than fails, because activation admits it.
  """
  @spec check_contract(map() | nil, Identity.contract()) :: Check.t()
  def check_contract(nil, _current), do: pass(:contract_drift, :contract, :contract_unbound)

  def check_contract(row, current) when is_map(row) do
    stored = Map.get(row, :publication_contract)
    stored_fingerprint = Map.get(row, :publication_fingerprint)

    case Identity.classify_stored_contract(stored, stored_fingerprint, current.manifest) do
      :unbound -> pass(:contract_drift, :contract, :contract_unbound)
      :equal -> pass(:contract_drift, :contract, :contract_equal)
      {:compatible, kind} -> warn(:contract_drift, :contract, kind)
      {:incompatible, reason} -> fail(:contract_drift, :contract, reason)
    end
  end

  # --- check constructors ---

  defp pass(name, domain, reason),
    do: %Check{name: name, domain: domain, status: :pass, reason: reason}

  defp warn(name, domain, reason),
    do: %Check{name: name, domain: domain, status: :warn, reason: reason}

  defp fail(name, domain, reason, detail \\ nil),
    do: %Check{name: name, domain: domain, status: :fail, reason: reason, detail: detail}

  # A structural error becomes a check: the reason survives, the shape survives
  # ONLY through the allowlist.
  defp from_error(name, domain, %Error{reason: reason} = error),
    do: fail(name, domain, reason, detail_for(error))

  defp detail_for(%Error{reason: reason, shape: shape})
       when reason in @detail_reasons and is_binary(shape),
       do: shape

  defp detail_for(_error), do: nil

  @doc false
  # Kept referenced so the probe module is a compile-time dependency of the one
  # module that documents the no-writes guarantee.
  @spec read_only_statements([String.t()]) :: [String.t()]
  def read_only_statements(publication), do: Probe.statements(publication)
end
