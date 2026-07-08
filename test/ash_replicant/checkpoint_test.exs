defmodule AshReplicant.CheckpointTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Test.Checkpoint

  test "upsert by slot_name inserts then refreshes commit_lsn (idempotent watermark)" do
    assert {:ok, first} =
             Ash.create(Checkpoint, %{slot_name: "s1", commit_lsn: 42},
               action: :upsert,
               authorize?: false
             )

    assert first.slot_name == "s1"
    assert first.commit_lsn == 42

    assert {:ok, _} =
             Ash.create(Checkpoint, %{slot_name: "s1", commit_lsn: 99},
               action: :upsert,
               authorize?: false
             )

    assert Ash.get!(Checkpoint, "s1", authorize?: false).commit_lsn == 99

    # Upsert, not insert: exactly one row for the slot.
    %Postgrex.Result{rows: [[count]]} =
      TestRepo.query!(
        "SELECT count(*) FROM ash_replicant_checkpoints WHERE slot_name = $1",
        ["s1"]
      )

    assert count == 1
  end
end
