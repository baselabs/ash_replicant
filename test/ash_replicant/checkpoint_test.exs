defmodule AshReplicant.CheckpointTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias Ash.Resource.Info
  alias AshReplicant.Test.Checkpoint

  @sys "7673383468368400428"
  @db "ash_replicant_test"

  describe "generated shape (source-bound row)" do
    test "composite primary key on the identity triple" do
      assert Info.primary_key(Checkpoint) ==
               [:source_system_id, :source_database, :slot_name]
    end

    test "identity and actions for the sink + operator surface" do
      identity = Info.identity(Checkpoint, :source_slot)
      assert identity.keys == [:source_system_id, :source_database, :slot_name]

      action_names = Checkpoint |> Info.actions() |> Enum.map(& &1.name)
      assert :read in action_names
      assert :upsert in action_names
      assert :operator_reset in action_names
      refute :destroy in action_names
    end

    test "attribute nullability matches the data model" do
      attrs = Map.new(Info.attributes(Checkpoint), &{&1.name, &1})

      for name <- [:source_system_id, :source_database, :slot_name] do
        assert attrs[name].allow_nil? == false
        assert attrs[name].primary_key? == true
      end

      # Nullable until first bind/commit; non-null after the first frontier write is
      # a lock-enforced invariant, not a column constraint.
      for name <- [:commit_lsn, :publication_contract, :publication_fingerprint, :source_timeline] do
        assert attrs[name].allow_nil? == true
      end

      # `snapshot_progress` stays reserved for S03 incremental mode.
      assert attrs[:snapshot_progress].allow_nil? == true

      # S02 (ADR-0017): the inert `snapshot_generation` placeholder became the
      # LIVE `snapshot_state` envelope column. The old name must be GONE — a
      # host left holding it would be carrying a column the sink never writes.
      assert attrs[:snapshot_state].allow_nil? == true
      refute Map.has_key?(attrs, :snapshot_generation)

      # The sink writes the envelope under the checkpoint lock, so the upsert
      # action has to accept it.
      upsert = Enum.find(Info.actions(Checkpoint), &(&1.name == :upsert))
      assert :snapshot_state in upsert.accept

      assert attrs[:inserted_at] && attrs[:updated_at]
    end
  end

  describe "upsert by the identity triple" do
    test "same triple refreshes commit_lsn; different triple is a different row" do
      assert {:ok, first} =
               Ash.create(
                 Checkpoint,
                 %{source_system_id: @sys, source_database: @db, slot_name: "s1", commit_lsn: 42},
                 action: :upsert,
                 authorize?: false
               )

      assert first.commit_lsn == 42

      assert {:ok, _} =
               Ash.create(
                 Checkpoint,
                 %{source_system_id: @sys, source_database: @db, slot_name: "s1", commit_lsn: 99},
                 action: :upsert,
                 authorize?: false
               )

      assert get!(@sys, @db, "s1").commit_lsn == 99

      # One row per triple.
      assert count(@sys, @db, "s1") == 1

      # A different slot under the same source is a different row (source-bound
      # identity scopes by source AND slot).
      assert {:ok, _} =
               Ash.create(
                 Checkpoint,
                 %{
                   source_system_id: @sys,
                   source_database: @db,
                   slot_name: "s1-other",
                   commit_lsn: 7
                 },
                 action: :upsert,
                 authorize?: false
               )

      assert count(@sys, @db, "s1") == 1
      assert count(@sys, @db, "s1-other") == 1
    end

    test "slot_name stays single-source: the shipped unique index refuses a second identity" do
      assert {:ok, _} =
               Ash.create(
                 Checkpoint,
                 %{source_system_id: @sys, source_database: @db, slot_name: "s2", commit_lsn: 1},
                 action: :upsert,
                 authorize?: false
               )

      assert {:error, _} =
               Ash.create(
                 Checkpoint,
                 %{
                   source_system_id: "9999999999999999999",
                   source_database: @db,
                   slot_name: "s2",
                   commit_lsn: 2
                 },
                 action: :upsert,
                 authorize?: false
               )

      assert count(@sys, @db, "s2") == 1
    end
  end

  defp get!(sys, db, slot) do
    Ash.get!(Checkpoint, %{source_system_id: sys, source_database: db, slot_name: slot},
      authorize?: false
    )
  end

  defp count(sys, db, slot) do
    {:ok, result} =
      AshReplicant.TestRepo.query(
        "SELECT count(*) FROM ash_replicant_checkpoints WHERE source_system_id = $1 AND source_database = $2 AND slot_name = $3",
        [sys, db, slot]
      )

    result.rows |> List.first() |> List.first()
  end
end
