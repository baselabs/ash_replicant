defmodule AshReplicant.TestRepo.Migrations.AddAppendLogFixtures do
  @moduledoc """
  Hand-authored (NOT `mix ash.codegen`) test scaffolding for the immutable
  append-log targets of ADR-0018.

  The three tables are HOST-owned by construction — that is the whole point of
  ADR-0018 §2 — so they live here rather than behind any package generator.
  Each carries the five-column append identity as a real UNIQUE index: it is
  the defensive database constraint behind append-once, and a test that
  asserted append-once without it would be proving the sink's own bookkeeping
  rather than the substrate.

  `secret_order_events.encrypted_pan` mirrors the `secret_orders` shape:
  AshCloak stores ciphertext in `encrypted_<name>` and the plaintext attribute
  is never a column.
  """

  use Ecto.Migration

  @append_identity [:source_system_id, :source_database, :slot_name, :commit_lsn, :ordinal]

  def up do
    create table(:order_events, primary_key: false) do
      add(:event_id, :uuid, null: false, primary_key: true)
      add(:source_system_id, :text, null: false)
      add(:source_database, :text, null: false)
      add(:slot_name, :text, null: false)
      add(:commit_lsn, :bigint, null: false)
      add(:ordinal, :bigint, null: false)
      add(:operation, :text, null: false)
      add(:origin, :text, null: false)
      add(:snapshot_attempt, :binary)
      add(:id, :text)
      add(:note, :text)
      add(:body, :text)
    end

    create table(:tenant_order_events, primary_key: false) do
      add(:event_id, :uuid, null: false, primary_key: true)
      add(:source_system_id, :text, null: false)
      add(:source_database, :text, null: false)
      add(:slot_name, :text, null: false)
      add(:commit_lsn, :bigint, null: false)
      add(:ordinal, :bigint, null: false)
      add(:operation, :text, null: false)
      add(:origin, :text, null: false)
      add(:snapshot_attempt, :binary)
      add(:id, :text)
      add(:org_id, :text, null: false)
      add(:note, :text)
    end

    create table(:secret_order_events, primary_key: false) do
      add(:event_id, :uuid, null: false, primary_key: true)
      add(:source_system_id, :text, null: false)
      add(:source_database, :text, null: false)
      add(:slot_name, :text, null: false)
      add(:commit_lsn, :bigint, null: false)
      add(:ordinal, :bigint, null: false)
      add(:operation, :text, null: false)
      add(:origin, :text, null: false)
      add(:snapshot_attempt, :binary)
      add(:id, :text)
      add(:encrypted_pan, :binary)
    end

    for table <- [:order_events, :tenant_order_events, :secret_order_events] do
      create(unique_index(table, @append_identity, name: "#{table}_append_identity_index"))
    end
  end

  def down do
    drop(table(:order_events))
    drop(table(:tenant_order_events))
    drop(table(:secret_order_events))
  end
end
