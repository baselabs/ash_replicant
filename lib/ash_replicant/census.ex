defmodule AshReplicant.Census do
  @moduledoc false

  require Ash.Query

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.{Coverage, Error, Horizon}

  @min_interval_ms 50
  @max_interval_ms 86_400_000
  @max_timeout_ms 60_000
  @max_consecutive_faults 1_000
  @checks [:destination, :contract, :checkpoint, :coverage]

  defmodule Options do
    @moduledoc false

    @enforce_keys [
      :enabled?,
      :interval_ms,
      :jitter_ratio,
      :timeout_ms,
      :max_consecutive_faults
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            enabled?: boolean(),
            interval_ms: pos_integer(),
            jitter_ratio: float(),
            timeout_ms: pos_integer(),
            max_consecutive_faults: pos_integer()
          }
  end

  defmodule Report do
    @moduledoc false

    @enforce_keys [:state, :checks]
    defstruct @enforce_keys

    @type check :: :destination | :contract | :checkpoint | :coverage
    @type verdict :: :pass | {:drift, atom()} | {:fault, atom()}
    @type state :: :healthy | {:drifted, check(), atom()} | {:faulted, check(), atom()}
    @type t :: %__MODULE__{state: state(), checks: [{check(), verdict()}]}
  end

  @defaults %{
    enabled?: true,
    interval_ms: 60_000,
    jitter_ratio: 0.1,
    timeout_ms: 10_000,
    max_consecutive_faults: 3
  }

  @option_keys Map.keys(@defaults)

  @spec options(keyword()) :: {:ok, Options.t()} | {:error, :census_options_invalid}
  def options(opts) when is_list(opts) do
    with census when is_list(census) <- Keyword.get(opts, :census, []),
         true <- Keyword.keyword?(census),
         [] <- Keyword.keys(census) -- @option_keys,
         values <- Map.merge(@defaults, Map.new(census)),
         true <- valid_options?(values) do
      {:ok, struct!(Options, values)}
    else
      _other -> {:error, :census_options_invalid}
    end
  end

  def options(_opts), do: {:error, :census_options_invalid}

  @spec next_delay(Options.t()) :: pos_integer()
  def next_delay(%Options{interval_ms: interval, jitter_ratio: ratio}) do
    radius = round(interval * ratio)

    case radius do
      0 -> interval
      positive -> interval - positive + :rand.uniform(positive * 2 + 1) - 1
    end
  end

  @spec state([{Report.check(), Report.verdict()}]) :: Report.state()
  def state(checks) when is_list(checks) do
    cond do
      checks == [] ->
        {:faulted, :destination, :census_checker_fault}

      drift = Enum.find(checks, fn {_check, verdict} -> match?({:drift, _}, verdict) end) ->
        {check, {:drift, reason}} = drift
        {:drifted, check, reason}

      fault = Enum.find(checks, fn {_check, verdict} -> match?({:fault, _}, verdict) end) ->
        {check, {:fault, reason}} = fault
        {:faulted, check, reason}

      Enum.all?(checks, fn {_check, verdict} -> verdict == :pass end) ->
        :healthy

      true ->
        {:faulted, :destination, :census_checker_fault}
    end
  end

  @spec run(String.t(), module()) :: Report.t()
  def run(slot_name, sink) when is_binary(slot_name) and is_atom(sink) do
    # terminal?: false (O02): a census fault feeds the consecutive-fault
    # budget — it is not a terminal pipeline cause and records no tombstone.
    case AshReplicant.run_callback(slot_name, sink, :read, &run_guarded/1, terminal?: false) do
      %Report{} = report -> report
      {:error, _reason} -> report(destination: {:drift, :config_invalid})
      _other -> report(destination: {:fault, :census_checker_fault})
    end
  rescue
    _error -> report(destination: {:fault, :census_checker_fault})
  catch
    _kind, _reason -> report(destination: {:fault, :census_checker_fault})
  end

  @doc false
  @spec fault_report(atom()) :: Report.t()
  def fault_report(reason) when is_atom(reason),
    do: report(destination: {:fault, reason})

  @doc false
  @spec classify_checkpoint([map()], map(), Identity.manifest()) :: Report.verdict()
  def classify_checkpoint(rows, expected, current_manifest) when is_list(rows) do
    case rows do
      [] ->
        {:fault, :checkpoint_unbound}

      [row] ->
        classify_checkpoint_row(row, expected, current_manifest)

      _many ->
        {:drift, :source_identity_rebound}
    end
  end

  @doc false
  @spec classify_contract(map(), Identity.contract()) :: Report.verdict()
  def classify_contract(config, admitted_contract) do
    case Identity.build_contract(config, config.publication) do
      {:ok, ^admitted_contract} -> :pass
      {:ok, _other} -> {:drift, :publication_contract_incompatible}
      {:error, _reason} -> {:drift, :publication_contract_incompatible}
    end
  rescue
    _error -> {:drift, :publication_contract_incompatible}
  catch
    _kind, _reason -> {:drift, :publication_contract_incompatible}
  end

  @doc false
  @spec classify_coverage_result(term()) :: Report.verdict()
  def classify_coverage_result({:ok, :deferred}),
    do: {:fault, :census_source_unreachable}

  def classify_coverage_result({:ok, _coverage}), do: :pass

  def classify_coverage_result({:error, %Error{reason: reason}}) when is_atom(reason),
    do: {:drift, reason}

  def classify_coverage_result({:error, _reason}), do: {:fault, :census_checker_fault}
  def classify_coverage_result(_other), do: {:fault, :census_checker_fault}

  defp valid_options?(values) do
    valid_interval?(values.interval_ms) and
      valid_jitter?(values.jitter_ratio) and
      valid_timeout?(values.timeout_ms) and
      valid_fault_budget?(values.max_consecutive_faults) and
      is_boolean(values.enabled?)
  end

  defp valid_interval?(value),
    do: is_integer(value) and value >= @min_interval_ms and value <= @max_interval_ms

  defp valid_jitter?(value), do: is_float(value) and value >= 0.0 and value <= 0.5

  defp valid_timeout?(value),
    do: is_integer(value) and value > 0 and value <= @max_timeout_ms

  defp valid_fault_budget?(value),
    do: is_integer(value) and value > 0 and value <= @max_consecutive_faults

  defp run_guarded(config) do
    checks =
      [
        {:contract, fn -> classify_contract(config, config.source_contract) end},
        {:checkpoint, fn -> check_checkpoint(config) end},
        {:coverage, fn -> check_coverage(config) end}
      ]
      |> Enum.reduce_while([destination: :pass], fn {check, checker}, checks ->
        verdict = safe_check(checker)
        next = checks ++ [{check, verdict}]

        if match?({:drift, _reason}, verdict), do: {:halt, next}, else: {:cont, next}
      end)

    report(checks)
  end

  defp safe_check(checker) do
    case checker.() do
      :pass -> :pass
      {:drift, reason} when is_atom(reason) -> {:drift, reason}
      {:fault, reason} when is_atom(reason) -> {:fault, reason}
      _other -> {:fault, :census_checker_fault}
    end
  rescue
    _error -> {:fault, :census_checker_fault}
  catch
    _kind, _reason -> {:fault, :census_checker_fault}
  end

  defp check_checkpoint(config) do
    slot_name = config.slot_name

    query =
      config.checkpoint_resource
      |> Ash.Query.filter(slot_name == ^slot_name)

    case Ash.read(query,
           authorize?: false,
           context: %{
             data_layer: Map.get(config, :data_layer_context, %{repo: config.repo})
           }
         ) do
      {:ok, rows} ->
        case classify_checkpoint(rows, checkpoint_filter(config), config.source_contract.manifest) do
          :pass -> classify_witness(config, rows)
          verdict -> verdict
        end

      {:error, _reason} ->
        {:fault, :census_checker_fault}
    end
  end

  # O03 (ADR-0020): the digest-key witness rides the checkpoint check — the
  # one admitted, budgeted place the sink re-observes its own durable row.
  # A rebind WRITES (set change or a pre-O03 NULL envelope — the upgrade
  # posture mints rather than halts); a violation or an undecodable witness
  # drifts fail-closed.
  defp classify_witness(config, rows) do
    with {:ok, retention} <- Horizon.max_route_retention(config.manifest),
         true <- is_nil(retention) or is_integer(retention),
         {:ok, keys} <- Horizon.provenance_keys(),
         {:ok, digest_keys} <- AshReplicant.Messages.digest_keys() do
      versions = Enum.map(digest_keys, &elem(&1, 0))
      stored = rows |> List.first() |> then(&Map.get(&1, :digest_key_state))

      case Horizon.classify_witness(stored, keys, versions, DateTime.utc_now(), retention) do
        {:ok, verdict} when verdict in [:ok, :skip] -> :pass
        {:ok, :rebind} -> rebind_witness(config)
        {:error, reason} -> {:drift, reason}
      end
    else
      _unavailable -> {:fault, :census_checker_fault}
    end
  end

  defp rebind_witness(config) do
    case Horizon.rebind_key_state(config) do
      :ok -> :pass
      {:error, _reason} -> {:fault, :census_checker_fault}
    end
  end

  defp classify_checkpoint_row(row, expected, current_manifest) do
    with :equal <- Identity.classify_source_binding(row, expected),
         timeline when is_integer(timeline) and timeline >= 0 <- Map.get(row, :source_timeline),
         stored when is_binary(stored) <- Map.get(row, :publication_contract) do
      case Identity.classify_stored_contract(
             stored,
             Map.get(row, :publication_fingerprint),
             current_manifest
           ) do
        :equal -> :pass
        {:compatible, _kind} -> :pass
        {:incompatible, _reason} -> {:drift, :publication_contract_incompatible}
        :unbound -> {:fault, :checkpoint_unbound}
      end
    else
      {:incompatible, :source_identity_rebound} -> {:drift, :source_identity_rebound}
      nil -> {:fault, :checkpoint_unbound}
      _other -> {:drift, :publication_contract_incompatible}
    end
  end

  defp check_coverage(config) do
    config.source_connection
    |> Coverage.preflight(
      config.source_identity,
      config.publication,
      config,
      config.resolver_index,
      config.source_contract.manifest
    )
    |> classify_coverage_result()
    |> then(fn verdict ->
      # O03 (ADR-0020): the WAL-side horizon rides the coverage check — the
      # source is reachable exactly when the slot probe can run. `lost` is a
      # drift halt; at-risk emits the retention event and CONTINUES (an
      # at-risk state must be observable without halting, or the alert
      # cannot precede the halt); the verdict stays as coverage classified it.
      if verdict == :pass do
        {slot_verdict, _detail} = Horizon.census_slot_verdict(config)
        slot_verdict
      else
        verdict
      end
    end)
  end

  defp checkpoint_filter(config) do
    %{
      source_system_id: config.source_identity.system_identifier,
      source_database: config.source_identity.database,
      slot_name: config.slot_name
    }
  end

  defp report(checks) do
    ordered = Enum.filter(checks, fn {check, _verdict} -> check in @checks end)
    %Report{state: state(ordered), checks: ordered}
  end
end
