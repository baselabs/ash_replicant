defmodule AshReplicant.TestRepo.Migrations.SnapshotEffectObserver do
  @moduledoc """
  Hand-authored (NOT `mix ash.codegen`) test scaffolding for S02 / ADR-0017.

  Two things Ash resource snapshots cannot express:

  1. **The append-only business-effect observer.** ADR-0017 requires proving
     that a snapshot retry does not REPEAT a committed host business effect,
     and final-state convergence cannot show that. So a row-level trigger on
     each provenance mirror appends every physical write to `snap_effects`,
     classifying an UPDATE that touched only the two provenance columns as
     bookkeeping rather than a business effect. The observer sits at the
     substrate, below anything the sink can claim about itself.

  2. **The context-multitenancy schemas.** `AshReplicant.Test.SnapCtxOrder`
     uses `strategy :context`, which AshPostgres resolves as schema-per-tenant.
     The retained scopes are real Postgres schemas, created here.
  """

  use Ecto.Migration

  @provenance_columns ~w(replica_fingerprint replica_seen_attempt)
  @public_tables ~w(snap_orders snap_tenant_orders snap_versions)
  @context_schemas ~w(ctx_org_a ctx_org_b)

  def up do
    create table(:snap_effects, primary_key: false) do
      add(:seq, :bigserial, primary_key: true)
      add(:tbl, :text, null: false)
      add(:op, :text, null: false)
      add(:row_key, :text)
      add(:bookkeeping, :boolean, null: false, default: false)
    end

    stripped = Enum.map_join(@provenance_columns, " ", &"- '#{&1}'")

    execute("""
    CREATE FUNCTION snap_observe_effect() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      key text;
      only_provenance boolean := false;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        key := OLD.id::text;
      ELSE
        key := NEW.id::text;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        only_provenance := (to_jsonb(NEW) #{stripped}) = (to_jsonb(OLD) #{stripped});
      END IF;

      INSERT INTO snap_effects (tbl, op, row_key, bookkeeping)
      VALUES (TG_TABLE_NAME, TG_OP, key, only_provenance);

      RETURN NULL;
    END
    $$
    """)

    for schema <- @context_schemas do
      execute("CREATE SCHEMA #{schema}")

      execute("""
      CREATE TABLE #{schema}.snap_ctx_orders (
        id text PRIMARY KEY,
        note text,
        replica_fingerprint bytea,
        replica_seen_attempt bytea
      )
      """)

      install_trigger("#{schema}.snap_ctx_orders", "#{schema}_snap_ctx_orders")
    end

    for table <- @public_tables, do: install_trigger(table, table)
  end

  def down do
    for table <- @public_tables do
      execute("DROP TRIGGER IF EXISTS snap_observe_#{table} ON #{table}")
    end

    for schema <- @context_schemas do
      execute("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    end

    execute("DROP FUNCTION IF EXISTS snap_observe_effect()")

    drop table(:snap_effects)
  end

  defp install_trigger(table, name) do
    execute("""
    CREATE TRIGGER snap_observe_#{name}
    AFTER INSERT OR UPDATE OR DELETE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION snap_observe_effect()
    """)
  end
end
