defmodule AshReplicant.Sink.Impl do
  @moduledoc """
  The config-parameterized sink implementation the `use AshReplicant.Sink`
  macro delegates to. `handle_transaction/2` is the effect-once core: one
  `Repo.transaction` wrapping {dedup-check → single-pass apply → checkpoint
  upsert}, value-free and fail-closed.

  Mirrored writes run inside the host transaction and pass
  `return_notifications?: true`, so Ash bundles any notification into the return
  value (never firing a notifier) and the sink discards it — Ash notifiers/pubsub
  do NOT fire for mirrored changes. (Ash cannot emit notifications from within a
  host-managed transaction anyway; `notify?: false` is not honored by
  single-record create/destroy in Ash 3.x, only `return_notifications?`.)
  """

  alias AshReplicant.{Apply, Error, Telemetry}
  alias Ecto.Adapters.SQL

  @doc "Last durably-persisted commit LSN for the slot (`nil` = never), the dedup watermark."
  @spec checkpoint(map()) :: {:ok, Replicant.lsn() | nil} | {:error, term()}
  def checkpoint(config) do
    {:ok, read_checkpoint(config)}
  rescue
    e -> {:error, Error.scrub(e, config.checkpoint_resource, :checkpoint)}
  end

  @doc """
  Persist the transaction's changes AND the checkpoint atomically; skip if
  `commit_lsn <= checkpoint`. Returns `{:ok, commit_lsn}` or a value-free
  `{:error, %AshReplicant.Error{}}` (the pipeline halts fail-closed and
  re-delivers on resume).

  `Apply.apply_change/2` RAISES on failure, so a failing change propagates out of
  `Repo.transaction` (Ecto rolls back, then re-raises) and lands on the outer
  `rescue` — NOT the `{:error, _}` branch of the result match. Both halt paths
  route through `halt/2`, so `:halted` telemetry fires on the real raise path too.
  """
  @spec handle_transaction(map(), Replicant.Transaction.t()) ::
          {:ok, Replicant.lsn()} | {:error, term()}
  def handle_transaction(config, %Replicant.Transaction{commit_lsn: lsn, changes: changes}) do
    if map_size(config.resolver_index) == 0 do
      # Fail closed: an absent/empty resolver index (start_link not run, slot
      # mismatch, degenerate config) would resolve every change to `nil` in
      # Apply — silently dropping ALL rows while still advancing the checkpoint,
      # i.e. PERMANENT, INVISIBLE loss. Halt BEFORE the txn so the checkpoint
      # never advances and the LSN is re-delivered on resume.
      halt(Error.exception(reason: :config_invalid, resource: nil, op: :sink), config)
    else
      run_transaction(config, lsn, changes)
    end
  rescue
    e -> halt(e, config)
  end

  defp run_transaction(config, lsn, changes) do
    result =
      config.repo.transaction(fn ->
        case read_checkpoint(config) do
          cp when is_integer(cp) and lsn <= cp ->
            :skipped

          _ ->
            # Single pass: `changes` may be a spilled txn's lazy, single-pass
            # Enumerable — iterate it exactly once, never sort/count/to_list.
            Enum.each(changes, &Apply.apply_change(config, &1))
            upsert_checkpoint(config, lsn)
            maybe_append_ledger(config, lsn)
            :applied
        end
      end)

    case result do
      {:ok, :applied} ->
        Telemetry.event([:ash_replicant, :sink, :applied], %{}, %{commit_lsn: lsn})
        {:ok, lsn}

      {:ok, :skipped} ->
        Telemetry.event([:ash_replicant, :sink, :skipped], %{}, %{commit_lsn: lsn})
        {:ok, lsn}

      {:error, reason} ->
        halt(reason, config)
    end
  end

  # Value-free fail-closed halt: scrub to a structural reason, emit `:halted`
  # (reason atom only — never a row value), return the scrubbed error.
  defp halt(reason, config) do
    error = Error.scrub(reason, config.checkpoint_resource, :sink)
    Telemetry.event([:ash_replicant, :sink, :halted], %{}, %{reason: error.reason})
    {:error, error}
  end

  defp read_checkpoint(config) do
    case Ash.get!(config.checkpoint_resource, config.slot_name,
           authorize?: false,
           error?: false
         ) do
      nil -> nil
      %{commit_lsn: lsn} -> lsn
    end
  end

  defp upsert_checkpoint(config, lsn) do
    Ash.create!(config.checkpoint_resource, %{slot_name: config.slot_name, commit_lsn: lsn},
      action: :upsert,
      upsert?: true,
      upsert_identity: :unique_slot,
      upsert_fields: [:commit_lsn],
      authorize?: false,
      return_notifications?: true
    )
  end

  # Test-only append-only ledger (config[:apply_ledger] = table name) for the dup=0
  # proof (Task 15). Appends inside the sink transaction, so it rolls back with a
  # failed txn and appends exactly once per applied txn. Dormant unless configured.
  defp maybe_append_ledger(%{apply_ledger: table} = config, lsn) when is_binary(table) do
    SQL.query!(config.repo, "INSERT INTO #{table} (commit_lsn) VALUES ($1)", [lsn])
  end

  defp maybe_append_ledger(_config, _lsn), do: :ok
end
