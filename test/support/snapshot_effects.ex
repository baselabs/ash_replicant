defmodule AshReplicant.Test.SnapshotEffects do
  @moduledoc """
  Reader for the append-only business-effect observer installed by the
  `SnapshotEffectObserver` migration (S02, ADR-0017).

  ADR-0017's whole point is that converging to the same final state is NOT
  proof of effect-once: a create, destroy, or SCD2 close can carry an
  append-only local effect even when a later upsert converges. So the proof has
  to count PHYSICAL writes, from below the sink, and it has to tell a host
  business effect apart from the package's own bookkeeping mark.

  The trigger does exactly that: an UPDATE whose non-provenance columns are
  byte-identical to the old row is `bookkeeping`; every INSERT, DELETE, and
  value-changing UPDATE is a business effect.
  """

  alias AshReplicant.TestRepo

  @doc "Every observed effect, in physical write order."
  def all do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        "SELECT tbl, op, row_key, bookkeeping FROM snap_effects ORDER BY seq",
        []
      )

    Enum.map(rows, fn [tbl, op, row_key, bookkeeping] ->
      %{table: tbl, op: op, row_key: row_key, bookkeeping?: bookkeeping}
    end)
  end

  @doc "Only the HOST BUSINESS effects — inserts, deletes, and value-changing updates."
  def business, do: Enum.reject(all(), & &1.bookkeeping?)

  @doc "Only the package's own provenance-column-only updates."
  def bookkeeping, do: Enum.filter(all(), & &1.bookkeeping?)

  @doc "Business effects for one row key, as `[op]` in write order."
  def business_ops(row_key) do
    business() |> Enum.filter(&(&1.row_key == row_key)) |> Enum.map(& &1.op)
  end

  @doc "Forget everything observed so far, so a later phase counts from zero."
  def reset! do
    TestRepo.query!("DELETE FROM snap_effects", [])
    :ok
  end
end
