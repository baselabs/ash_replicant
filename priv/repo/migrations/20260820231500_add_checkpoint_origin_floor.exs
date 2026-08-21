defmodule AshReplicant.TestRepo.Migrations.AddCheckpointOriginFloor do
  @moduledoc """
  Adds the append log's immutable origin floor to the bundled checkpoint
  (ADR-0018 §5).

  Nullable and always NULL for a state-mirror host, so this is additive for
  every existing deployment: nothing to capture, nothing to backfill.
  """

  use Ecto.Migration

  def up do
    alter table(:ash_replicant_checkpoints) do
      add(:origin_floor, :bigint)
    end
  end

  def down do
    alter table(:ash_replicant_checkpoints) do
      remove(:origin_floor)
    end
  end
end
