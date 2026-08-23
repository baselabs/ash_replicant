defmodule AshReplicant.Horizon do
  @moduledoc """
  The recovery-horizon classification home (O03, ADR-0020): ONE body consumed
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

  @doc """
  The smallest declared claim retention across the manifest's C1 message
  routes (`role == :message` with a protection). `nil` when the sink has no
  claim-backed routes — nothing to compare.
  """
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

  @doc """
  The LARGEST declared claim retention across the manifest's C1 message
  routes — the longest any claim can live, and therefore the bound the
  digest-key witness compares a removal against (conservative direction: a
  version may leave the configured set only once no claim minted under it can
  possibly remain).
  """
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

  @doc """
  The activation preflight leg: compare the manifest's retention floor against
  the sink config's declared horizon. Claim-backed routes without an
  admissible horizon fail closed (the compile tier already rejected this for
  DSL sinks; a config-map caller bypassing the DSL meets the same refusal).
  Value-free — the error carries the structural reason only.
  """
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
