defmodule AshReplicant.TestRepo.Migrations.AddReassignOrder do
  @moduledoc """
  Test-only table for the tenant-reassignment apply case. Mirrors the shape a
  real attribute-multitenant mirror carries when it declares a source-PK upsert
  identity: a GLOBAL `id` primary key PLUS a tenant-scoped `(org_id, id)` unique
  index (the index an Ash `identity :source_pk, [:id]` generates under attribute
  multitenancy). The disagreement between the global PK and the tenant-scoped
  upsert conflict target is exactly what makes a tenant reassignment collide.
  """

  use Ecto.Migration

  def up do
    create table(:reassign_orders, primary_key: false) do
      add(:id, :text, null: false, primary_key: true)
      add(:org_id, :text, null: false)
      add(:note, :text)
    end

    create(unique_index(:reassign_orders, [:org_id, :id], name: "reassign_orders_source_pk_index"))
  end

  def down do
    drop(table(:reassign_orders))
  end
end
