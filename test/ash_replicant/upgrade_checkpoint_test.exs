defmodule AshReplicant.Upgrade.CheckpointTest do
  use ExUnit.Case, async: true

  alias AshReplicant.Upgrade.Checkpoint
  alias AshReplicant.Upgrade.Checkpoint.{Error, Report}

  @binding %{
    slot_name: "configured_slot",
    source_system_id: "source-system",
    source_database: "source-database"
  }

  test "classifies a populated legacy table only when every row has exactly one binding" do
    facts = %{
      schema: :legacy,
      rows: [%{slot_name: @binding.slot_name, commit_lsn: 42}],
      bindings: [@binding]
    }

    assert {:ok,
            %Report{
              state: :legacy_ready,
              legacy_rows: 1,
              bound_rows: 1,
              dormant_bindings: 0
            }} = Checkpoint.classify(facts)
  end

  test "an empty legacy table permits dormant configured bindings" do
    facts = %{schema: :legacy, rows: [], bindings: [@binding]}

    assert {:ok,
            %Report{
              state: :legacy_ready,
              legacy_rows: 0,
              bound_rows: 0,
              dormant_bindings: 1
            }} = Checkpoint.classify(facts)
  end

  test "refuses an unclaimed shared legacy row without exposing its values" do
    secret_slot = "slot-secret-sentinel"
    secret_lsn = 9_223_372_036_854_775_000

    facts = %{
      schema: :legacy,
      rows: [%{slot_name: secret_slot, commit_lsn: secret_lsn}],
      bindings: [@binding]
    }

    assert {:error, %Error{reason: :legacy_row_unbound} = error} =
             Checkpoint.classify(facts)

    message = Exception.message(error)
    refute message =~ secret_slot
    refute message =~ Integer.to_string(secret_lsn)
  end

  test "refuses duplicate claims for one legacy slot" do
    facts = %{
      schema: :legacy,
      rows: [%{slot_name: @binding.slot_name, commit_lsn: 42}],
      bindings: [@binding, Map.put(@binding, :source_system_id, "another-source")]
    }

    assert {:error, %Error{reason: :legacy_row_ambiguous}} = Checkpoint.classify(facts)
  end

  test "distinguishes already-current, interrupted, foreign, and missing shapes" do
    assert {:ok, %Report{state: :already_upgraded}} =
             Checkpoint.classify(%{schema: :current, rows: [], bindings: []})

    assert {:error, %Error{reason: :interrupted_upgrade}} =
             Checkpoint.classify(%{schema: :interrupted, rows: [], bindings: []})

    assert {:error, %Error{reason: :foreign_checkpoint}} =
             Checkpoint.classify(%{schema: :foreign, rows: [], bindings: []})

    assert {:error, %Error{reason: :checkpoint_missing}} =
             Checkpoint.classify(%{schema: :missing, rows: [], bindings: []})
  end

  test "duplicate ownership claims are ambiguous even after the table is current" do
    row = Map.take(@binding, [:slot_name, :source_system_id, :source_database])

    assert {:error, %Error{reason: :legacy_row_ambiguous}} =
             Checkpoint.classify(%{
               schema: :current,
               rows: [row],
               bindings: [@binding, @binding]
             })
  end

  test "rejects malformed facts rather than guessing" do
    assert {:error, %Error{reason: :facts_invalid}} = Checkpoint.classify(%{})

    assert {:error, %Error{reason: :facts_invalid}} =
             Checkpoint.classify(%{schema: :legacy, rows: :unknown, bindings: []})
  end
end
