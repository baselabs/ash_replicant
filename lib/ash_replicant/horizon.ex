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

  alias AshReplicant.Destination
  alias AshReplicant.Error

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
        compare_admissible_horizon(min, Map.get(config, :recovery_horizon))

      {:error, %Error{}} = error ->
        error
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
