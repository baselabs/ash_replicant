defmodule AshReplicant.Test.DestinationObserver do
  @moduledoc false

  alias AshReplicant.Test.Marquee

  @table "repl_destination_observer"
  @allowed_operations ~w(INSERT UPDATE DELETE)

  def table, do: @table

  def setup!(run_id, triggers) when is_binary(run_id) and is_list(triggers) do
    teardown!(triggers)

    Marquee.q!("""
    CREATE TABLE #{quote_ident(@table)} (
      run_id text not null,
      participant text not null,
      operation text not null,
      transaction_id bigint not null,
      commit_lsn bigint
    )
    """)

    Enum.each(triggers, &install_trigger!(run_id, &1))
    :ok
  end

  def teardown!(triggers) when is_list(triggers) do
    Enum.each(triggers, fn trigger ->
      Marquee.q!(
        "DROP TRIGGER IF EXISTS #{quote_ident(trigger_name(trigger))} ON #{quote_table(trigger.table)}"
      )

      Marquee.q!("DROP FUNCTION IF EXISTS #{quote_ident(function_name(trigger))}()")
    end)

    Marquee.q!("DROP TABLE IF EXISTS #{quote_ident(@table)}")
    :ok
  end

  def rows(run_id) do
    Marquee.q!(
      "SELECT participant, operation, transaction_id, commit_lsn FROM #{quote_ident(@table)} WHERE run_id = $1 ORDER BY ctid",
      [run_id]
    ).rows
    |> Enum.map(fn [participant, operation, transaction_id, commit_lsn] ->
      %{
        participant: participant,
        operation: operation,
        transaction_id: transaction_id,
        commit_lsn: commit_lsn
      }
    end)
  end

  def effect_count(run_id, participant, operation) do
    [[count]] =
      Marquee.q!(
        "SELECT count(*) FROM #{quote_ident(@table)} WHERE run_id = $1 AND participant = $2 AND operation = $3",
        [run_id, participant, operation]
      ).rows

    count
  end

  def unconstrained? do
    [[constraint_count]] =
      Marquee.q!("""
      SELECT count(*)
      FROM pg_constraint
      WHERE conrelid = #{quote_literal(@table)}::regclass
        AND contype IN ('p', 'u')
      """).rows

    [[unique_index_count]] =
      Marquee.q!("""
      SELECT count(*)
      FROM pg_index
      WHERE indrelid = #{quote_literal(@table)}::regclass
        AND indisunique
      """).rows

    constraint_count == 0 and unique_index_count == 0
  end

  defp install_trigger!(run_id, trigger) do
    operations =
      trigger
      |> Map.fetch!(:operations)
      |> Enum.map_join(" OR ", &normalize_operation!/1)

    commit_lsn =
      case Map.get(trigger, :commit_lsn_column) do
        nil ->
          "NULL"

        column ->
          quoted = quote_ident(column)
          "CASE WHEN TG_OP = 'DELETE' THEN OLD.#{quoted} ELSE NEW.#{quoted} END"
      end

    # O02: the checkpoint table now also carries the terminal tombstone
    # columns, and a stop/halt/clear writes them WITHOUT any data effect.
    # The observer proves effect-once on DATA writes, so a checkpoint
    # UPDATE that leaves every data column unchanged (a terminal-only
    # control-plane write) is not an effect and must not be counted —
    # otherwise the fault-containment budgets see phantom advances.
    terminal_guard = terminal_only_guard(trigger)

    Marquee.q!("""
    CREATE FUNCTION #{quote_ident(function_name(trigger))}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
    #{terminal_guard}
      INSERT INTO #{quote_ident(@table)}
        (run_id, participant, operation, transaction_id, commit_lsn)
      VALUES
        (#{quote_literal(run_id)}, #{quote_literal(trigger.participant)}, TG_OP,
         txid_current(), #{commit_lsn});
      RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END
    $$
    """)

    Marquee.q!("""
    CREATE TRIGGER #{quote_ident(trigger_name(trigger))}
    AFTER #{operations} ON #{quote_table(trigger.table)}
    FOR EACH ROW EXECUTE FUNCTION #{quote_ident(function_name(trigger))}()
    """)
  end

  # Emitted only for the checkpoint table (the one table with terminal
  # columns): skip the observer row when an UPDATE changed nothing on the
  # data surface — the write was a tombstone set/clear.
  defp terminal_only_guard(%{table: "ash_replicant_checkpoints"}) do
    """
      IF TG_OP = 'UPDATE'
         AND NEW.commit_lsn IS NOT DISTINCT FROM OLD.commit_lsn
         AND NEW.snapshot_state IS NOT DISTINCT FROM OLD.snapshot_state
         AND NEW.snapshot_progress IS NOT DISTINCT FROM OLD.snapshot_progress
         AND NEW.publication_contract IS NOT DISTINCT FROM OLD.publication_contract
         AND NEW.publication_fingerprint IS NOT DISTINCT FROM OLD.publication_fingerprint
         AND NEW.source_timeline IS NOT DISTINCT FROM OLD.source_timeline
         AND NEW.origin_floor IS NOT DISTINCT FROM OLD.origin_floor THEN
        RETURN NEW;
      END IF;
    """
  end

  defp terminal_only_guard(_other_trigger), do: ""

  defp normalize_operation!(operation) do
    operation = operation |> to_string() |> String.upcase()

    if operation in @allowed_operations do
      operation
    else
      raise ArgumentError, "unsupported observer operation"
    end
  end

  defp trigger_name(trigger), do: "repl_observe_#{suffix(trigger)}"
  defp function_name(trigger), do: "repl_observe_#{suffix(trigger)}_write"

  defp suffix(trigger) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({trigger.table, trigger.participant}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp quote_table(table) when is_binary(table) do
    table
    |> String.split(".")
    |> Enum.map_join(".", &quote_ident/1)
  end

  defp quote_ident(value), do: ~s("#{String.replace(to_string(value), "\"", "\"\"")}")
  defp quote_literal(value), do: "'#{String.replace(to_string(value), "'", "''")}'"
end
