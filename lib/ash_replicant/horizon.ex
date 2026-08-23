defmodule AshReplicant.Horizon do
  @moduledoc """
  The recovery-horizon classification home (O03, ADR-0022): ONE body consumed
  by activation, the census, and the doctor — Critical Rule 11 forbids any of
  them re-implementing the other's copy.

  The horizon contract: a standalone message's ONLY dedup is its AshOnetime
  claim (`handle_message/2` has no watermark skip), and the claim lives until
  `retain_until`. An outage shorter than the slot's WAL window but longer than
  a route's declared retention expires the dedup while the WAL is still
  recoverable — the operator's declared `recovery_horizon` (sink DSL, seconds)
  is the supported outage window every route retention must cover. This module
  owns the static comparison; the slot-fact and digest-key-envelope
  classifications ride the same home.

  Append-log sinks are out of scope here: their message routes dedup
  structurally through the append identity (ADR-0018), carry no claim, and
  contribute no retention floor.
  """

  require Ash.Query

  alias AshReplicant.Destination
  alias AshReplicant.Error
  alias AshReplicant.Horizon.KeyState
  alias AshReplicant.Telemetry

  @min_provenance_key_bytes 16

  @doc """
  The validated horizon provenance key set — the ORTHOGONAL family that
  authenticates the digest-key witness: a non-empty list of
  `{positive_integer_version, binary_key}` with unique versions and keys of at
  least #{@min_provenance_key_bytes} bytes, sorted ascending. The ACTIVE
  version is the highest. Never the message digest keys themselves (see
  `KeyState`'s moduledoc for the circularity this avoids).
  """
  @spec provenance_keys() :: {:ok, [{pos_integer(), binary()}]} | :error
  def provenance_keys do
    case Application.get_env(:ash_replicant, :horizon_provenance_keys) do
      keys when is_list(keys) and keys != [] ->
        with true <- Enum.all?(keys, &valid_provenance_key?/1),
             versions = Enum.map(keys, &elem(&1, 0)),
             true <- length(Enum.uniq(versions)) == length(versions) do
          {:ok, Enum.sort(keys)}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp valid_provenance_key?({version, key})
       when is_integer(version) and version >= 1 and is_binary(key) and
              byte_size(key) >= @min_provenance_key_bytes,
       do: true

  defp valid_provenance_key?(_other), do: false

  # Hidden-module spec (Destination.Manifest) — the 65ea3a0 pattern; the
  # contract lives in these lines and ADR-0022.
  # # The smallest declared claim retention across the manifest's C1 message
  # routes (`role == :message` with a protection). `nil` when the sink has no
  # claim-backed routes — nothing to compare.
  #
  @doc false
  @spec min_route_retention(Destination.Manifest.t()) ::
          {:ok, pos_integer() | nil} | {:error, Error.t()}
  def min_route_retention(%Destination.Manifest{entries: entries}) do
    retentions =
      entries
      |> Enum.filter(&(&1.role == :message and is_map(&1.protection)))
      |> Enum.map(& &1.protection.retention)
      |> Enum.reject(&is_nil/1)

    cond do
      retentions == [] ->
        {:ok, nil}

      # Unreachable through manifest/1 (validate_onetime_entries rejects a
      # non-positive retention first); guards direct Entry construction.
      Enum.all?(retentions, &(is_integer(&1) and &1 > 0)) ->
        {:ok, Enum.min(retentions)}

      true ->
        {:error, Error.exception(reason: :config_invalid, op: :activation)}
    end
  end

  # Hidden-module spec (Destination.Manifest) — the 65ea3a0 pattern; the
  # contract lives in these lines and ADR-0022.
  # # The LARGEST declared claim retention across the manifest's C1 message
  # routes — the longest any claim can live, and therefore the bound the
  # digest-key witness compares a removal against (conservative direction: a
  # version may leave the configured set only once no claim minted under it can
  # possibly remain).
  #
  @doc false
  @spec max_route_retention(Destination.Manifest.t()) ::
          {:ok, pos_integer() | nil} | {:error, Error.t()}
  def max_route_retention(%Destination.Manifest{entries: entries}) do
    retentions =
      entries
      |> Enum.filter(&(&1.role == :message and is_map(&1.protection)))
      |> Enum.map(& &1.protection.retention)
      |> Enum.reject(&is_nil/1)

    cond do
      retentions == [] ->
        {:ok, nil}

      Enum.all?(retentions, &(is_integer(&1) and &1 > 0)) ->
        {:ok, Enum.max(retentions)}

      true ->
        {:error, Error.exception(reason: :config_invalid, op: :activation)}
    end
  end

  @doc """
  Classify the stored witness against the currently-configured digest-key
  versions. `{:ok, :ok}` — unchanged; `{:ok, :rebind}` — the observation is
  stale (versions added, or a removal past the retention horizon) and must be
  re-recorded; `{:error, :digest_key_horizon_violated}` — a version was
  removed from the configured set within the retention horizon of the last
  observation containing it, so claims minted under it may still be
  re-deliverable and replay would halt `:content_digest_mismatch`;
  `{:error, :digest_key_state_invalid}` — undecodable, tampered, or
  impossible (clock regression) — fail closed, never a silent fresh witness.
  """
  @spec classify_key_state(KeyState.t(), [pos_integer()], DateTime.t(), pos_integer()) ::
          {:ok, :ok | :rebind}
          | {:error, :digest_key_horizon_violated | :digest_key_state_invalid}
  def classify_key_state(%KeyState{} = state, configured_versions, now, retention)
      when is_list(configured_versions) do
    cond do
      not (is_integer(retention) and retention > 0) ->
        {:error, :digest_key_state_invalid}

      DateTime.compare(now, state.recorded_at) == :lt ->
        {:error, :digest_key_state_invalid}

      true ->
        classify_key_set_change(state, configured_versions, now, retention)
    end
  end

  def classify_key_state(_state, _configured, _now, _retention),
    do: {:error, :digest_key_state_invalid}

  defp classify_key_set_change(state, configured_versions, now, retention) do
    missing = state.versions -- configured_versions
    elapsed = DateTime.diff(now, state.recorded_at, :second)

    cond do
      missing == [] and Enum.sort(configured_versions) == state.versions ->
        {:ok, :ok}

      missing == [] ->
        {:ok, :rebind}

      elapsed < retention ->
        {:error, :digest_key_horizon_violated}

      true ->
        {:ok, :rebind}
    end
  end

  @doc """
  The raw-bytes classifier: decode the durable column first, then classify.
  Undecodable or unauthenticatable bytes fail closed as
  `:digest_key_state_invalid` — the distinction between corruption and a
  rotated-away horizon key is diagnosable but not actionable mid-flight.
  """
  @spec classify_stored_key_state(
          binary(),
          [{pos_integer(), binary()}],
          [pos_integer()],
          DateTime.t(),
          pos_integer()
        ) ::
          {:ok, :ok | :rebind}
          | {:error, :digest_key_horizon_violated | :digest_key_state_invalid}
  def classify_stored_key_state(stored, keys, configured_versions, now, retention)
      when is_binary(stored) and is_list(keys) do
    case KeyState.decode(stored, keys) do
      {:ok, state} -> classify_key_state(state, configured_versions, now, retention)
      {:error, _reason} -> {:error, :digest_key_state_invalid}
    end
  end

  def classify_stored_key_state(_stored, _keys, _configured, _now, _retention),
    do: {:error, :digest_key_state_invalid}

  @doc """
  The slot-fact risk classifier (the WAL side of the horizon): `reserved` /
  `extended` with headroom are `{:ok, :ok}`; `unreserved` (WAL about to be
  removed at the next checkpoint but still recoverable) or an exhausted
  `safe_wal_size` are `{:ok, {:at_risk, kind}}` — the alert that must fire
  BEFORE recovery becomes impossible; `lost` is
  `{:error, :source_wal_lost}` — recovery is already impossible, a census
  drift halt. No slot row or an unreadable status defers to
  `{:ok, :unknown}`.
  """
  @spec classify_slot_risk(map() | nil) ::
          {:ok, :ok | :unknown | {:at_risk, :wal_unreserved | :wal_exhausted}}
          | {:error, :source_wal_lost}
  def classify_slot_risk(%{wal_status: "reserved", exhausted: false}), do: {:ok, :ok}
  def classify_slot_risk(%{wal_status: "extended", exhausted: false}), do: {:ok, :ok}

  def classify_slot_risk(%{wal_status: "unreserved", exhausted: false}),
    do: {:ok, {:at_risk, :wal_unreserved}}

  def classify_slot_risk(%{wal_status: status, exhausted: true}) when status != "lost",
    do: {:ok, {:at_risk, :wal_exhausted}}

  def classify_slot_risk(%{wal_status: "lost"}), do: {:error, :source_wal_lost}
  def classify_slot_risk(_unknown), do: {:ok, :unknown}

  @doc """
  The activation resume gate: a prior halt (`halted_since` — the durable
  tombstone's `terminal_at`) whose duration crossed the minimum claim
  retention while the slot still retains WAL refuses with
  `:retention_horizon_crossed` — the un-acked standalone messages whose
  claims expired would re-execute on re-delivery; the operator must
  reconcile consciously (the standing no-unproven-zero posture). A `lost`
  slot defers to the stream's own failure (that is data loss, not
  duplication); an unreachable probe never blocks recovery; no prior halt
  or no claim-backed routes proceed.
  """
  @spec classify_resume(
          DateTime.t() | nil,
          DateTime.t(),
          pos_integer() | nil,
          map() | nil | :unreachable
        ) ::
          :ok | {:error, :retention_horizon_crossed}
  def classify_resume(nil, _now, _retention, _slot), do: :ok
  def classify_resume(_halted_since, _now, nil, _slot), do: :ok
  def classify_resume(_halted_since, _now, _retention, :unreachable), do: :ok
  def classify_resume(_halted_since, _now, _retention, nil), do: :ok

  def classify_resume(halted_since, now, retention, slot) do
    with true <- is_map(slot),
         false <- slot.wal_status == "lost",
         true <- DateTime.diff(now, halted_since, :second) >= retention do
      {:error, :retention_horizon_crossed}
    else
      _other -> :ok
    end
  end

  @doc """
  The census's slot-fact leg: probe the slot on a short-lived read-only
  connection (the doctor's own `probe_slot`), classify, and on at-risk emit
  `[:ash_replicant, :retention, :at_risk]` — META ONLY (`slot_name` + the
  structural `kind`; no measurement: `byte_size` is C1-reserved and a
  non-positive `safe_wal_size` would fail measurement validation and mask
  the alert as a checker fault). Returns the census-verdict pair.
  """
  @spec census_slot_verdict(map()) :: {:pass | {:drift, atom()}, :ok | :unknown | nil}
  def census_slot_verdict(config) do
    slot = AshReplicant.Doctor.Probe.probe_slot(config.source_connection, config.slot_name)

    case classify_slot_risk(slot) do
      {:ok, :ok} -> {:pass, :ok}
      {:ok, :unknown} -> {:pass, :unknown}
      {:ok, {:at_risk, kind}} -> emit_at_risk(config, kind)
      {:error, :source_wal_lost} -> {{:drift, :source_wal_lost}, nil}
    end
  end

  defp emit_at_risk(config, kind) do
    Telemetry.event(
      [:ash_replicant, :retention, :at_risk],
      %{},
      %{slot_name: config.slot_name, kind: kind}
    )

    {:pass, {:at_risk, kind}}
  end

  # Hidden-module spec (Destination.Manifest) — the 65ea3a0 pattern; the
  # contract lives in these lines and ADR-0022.
  # # The activation preflight leg: the resume gate — read the slot facts, read
  # the durable tombstone time, compare against the retention floor. Never
  # blocks on an unreachable probe.
  #
  @doc false
  @spec preflight_resume(keyword(), String.t(), map(), Destination.Manifest.t()) ::
          :ok | {:error, Error.t()}
  def preflight_resume(connection_opts, slot_name, config, manifest) do
    with {:ok, min} <- min_route_retention(manifest),
         true <- is_integer(min) do
      halted_since = durable_terminal_at(config)
      slot = AshReplicant.Doctor.Probe.probe_slot(connection_opts, slot_name)

      classify_resume(halted_since, DateTime.utc_now(), min, slot)
      |> case do
        :ok -> :ok
        {:error, reason} -> {:error, Error.exception(reason: reason, op: :activation)}
      end
    else
      _no_claim_routes -> :ok
    end
  end

  defp durable_terminal_at(config) do
    context = Map.get(config, :data_layer_context, %{repo: config.repo})

    config.checkpoint_resource
    |> Ash.Query.filter(
      slot_name == ^config.slot_name and
        source_system_id == ^config.source_identity.system_identifier and
        source_database == ^config.source_identity.database
    )
    |> Ash.read(authorize?: false, context: context)
    |> case do
      {:ok, [%{terminal_at: %DateTime{} = at}]} -> at
      _absent_or_no_tombstone -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  @doc """
  The census's witness verdict: `:skip` when the sink carries no claim-backed
  routes (nothing to witness), `{:ok, :rebind}` for a NULL envelope on a
  claim-routed sink — the pre-O03 upgrade posture (the first census after the
  upgrade mints the witness rather than halting on every existing row) — and
  otherwise the stored classification above.
  """
  @spec classify_witness(
          binary() | nil,
          [{pos_integer(), binary()}],
          [pos_integer()],
          DateTime.t(),
          pos_integer() | nil
        ) ::
          {:ok, :ok | :rebind | :skip}
          | {:error, :digest_key_horizon_violated | :digest_key_state_invalid}
  def classify_witness(_stored, _keys, _configured, _now, nil), do: {:ok, :skip}

  def classify_witness(nil, _keys, _configured, _now, _retention), do: {:ok, :rebind}

  def classify_witness(stored, keys, configured, now, retention),
    do: classify_stored_key_state(stored, keys, configured, now, retention)

  @doc """
  Record the CURRENT digest-key observation on the checkpoint row: the scoped
  control-plane write (read `FOR UPDATE`, then an upsert whose
  `upsert_fields` carry ONLY `digest_key_state`, so a racing advance's
  watermark can never be clobbered — the O02 tombstone writer's pattern).
  Never creates the row (the bind owns creation); `:ok` when there is no
  claim-routed observation to record.
  """
  @spec rebind_key_state(map()) :: :ok | {:error, Error.t()}
  def rebind_key_state(config) do
    with {:ok, encoded} <- observe_key_state(),
         binary when is_binary(binary) <- encoded do
      write_witness(config, binary)
    else
      nil -> :ok
    end
  end

  defp write_witness(config, encoded) do
    context = Map.get(config, :data_layer_context, %{repo: config.repo})
    system_id = config.source_identity.system_identifier
    database = config.source_identity.database
    slot = config.slot_name

    result =
      config.repo.transaction(fn ->
        rows =
          config.checkpoint_resource
          |> Ash.Query.filter(
            slot_name == ^slot and source_system_id == ^system_id and
              source_database == ^database
          )
          |> Ash.read!(lock: :for_update, authorize?: false, context: context)
          |> List.wrap()

        case rows do
          [_row] ->
            Ash.create!(
              config.checkpoint_resource,
              Map.merge(checkpoint_filter(config), %{digest_key_state: encoded}),
              action: :upsert,
              upsert?: true,
              upsert_identity: :source_slot,
              upsert_fields: [:digest_key_state],
              authorize?: false,
              context: context,
              return_notifications?: true
            )

            :ok

          _absent_or_ambiguous ->
            :skip
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:ok, :skip} -> :ok
      _failed -> {:error, Error.exception(reason: :config_invalid, op: :census)}
    end
  rescue
    _error -> {:error, Error.exception(reason: :config_invalid, op: :census)}
  catch
    _kind, _reason -> {:error, Error.exception(reason: :config_invalid, op: :census)}
  end

  defp checkpoint_filter(config) do
    %{
      source_system_id: config.source_identity.system_identifier,
      source_database: config.source_identity.database,
      slot_name: config.slot_name
    }
  end

  @doc """
  Static comparison: every claim-backed route retention must cover the
  operator's declared recovery horizon, or activation refuses fail-closed.
  """
  @spec classify_retention(pos_integer() | nil, pos_integer()) :: :ok | {:error, atom()}
  def classify_retention(nil, _horizon), do: :ok

  def classify_retention(retention, horizon)
      when is_integer(retention) and retention > 0 and is_integer(horizon) and horizon > 0 and
             retention >= horizon,
      do: :ok

  def classify_retention(_retention, _horizon), do: {:error, :retention_below_recovery_horizon}

  # Hidden-module spec (Destination.Manifest) — the 65ea3a0 pattern; the
  # contract lives in these lines and ADR-0022.
  # # The activation preflight leg: compare the manifest's retention floor against
  # the sink config's declared horizon. Claim-backed routes without an
  # admissible horizon fail closed (the compile tier already rejected this for
  # DSL sinks; a config-map caller bypassing the DSL meets the same refusal).
  # Value-free — the error carries the structural reason only.
  #
  @doc false
  @spec preflight_static(Destination.Manifest.t(), map()) :: :ok | {:error, Error.t()}
  def preflight_static(%Destination.Manifest{} = manifest, config) do
    case min_route_retention(manifest) do
      {:ok, nil} ->
        :ok

      {:ok, min} when is_integer(min) ->
        # The witness needs its authenticating family before the first bind
        # (the same posture preflight_digest holds for the digest keys).
        with :ok <- require_provenance_keys() do
          compare_admissible_horizon(min, Map.get(config, :recovery_horizon))
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  defp require_provenance_keys do
    case provenance_keys() do
      {:ok, _keys} -> :ok
      :error -> {:error, Error.exception(reason: :config_invalid, op: :activation)}
    end
  end

  @doc """
  Encode the CURRENT digest-key observation for the durable witness: the
  configured versions + active version + now, authenticated under the ACTIVE
  horizon provenance key. `{:ok, nil}` when the digest keys are not
  configured (a claim-routed sink never reaches here — preflight gated it).
  """
  @spec observe_key_state() :: {:ok, binary() | nil} | {:error, Error.t()}
  def observe_key_state do
    with {:ok, digest_keys} <- AshReplicant.Messages.digest_keys(),
         {:ok, provenance} <- provenance_keys() do
      versions = Enum.map(digest_keys, &elem(&1, 0))
      active = List.last(versions)
      key_version = provenance |> Enum.map(&elem(&1, 0)) |> List.last()

      KeyState.observed(active, versions, DateTime.utc_now(), key_version)
      |> KeyState.encode(provenance)
      |> case do
        {:ok, encoded} -> {:ok, encoded}
        {:error, _reason} -> {:error, Error.exception(reason: :config_invalid, op: :activation)}
      end
    else
      :error -> {:ok, nil}
    end
  end

  defp compare_admissible_horizon(min, horizon) when is_integer(horizon) and horizon > 0 do
    case classify_retention(min, horizon) do
      :ok ->
        :ok

      {:error, _below} ->
        # Minted as a literal so the closed-reasons live pin (grep over
        # lib/) enforces this atom's membership in the inventory.
        {:error, Error.exception(reason: :retention_below_recovery_horizon, op: :activation)}
    end
  end

  # Claim-backed routes without an admissible horizon fail closed (the
  # compile tier already rejected this for DSL sinks; a config-map caller
  # bypassing the DSL meets the same refusal).
  defp compare_admissible_horizon(_min, _not_admissible) do
    {:error, Error.exception(reason: :config_invalid, op: :activation)}
  end
end
