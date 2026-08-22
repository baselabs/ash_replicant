# 8. Strict source coverage and schema compatibility

Date: 2026-08-14

## Status

Accepted for the 1.0.0 release line. Composes with
[ADR-0001](0001-fail-closed-multitenancy.md) (amended by roadmap B4 — see
that file's amendment paragraph) and
[ADR-0007](0007-source-bound-checkpoint-effect-once.md) (the stored contract
manifest this decision classifies against).

## Context

Before this decision, three classes of source drift streamed **silently**:
an unmapped publication table returned `:ok` as a "legitimate
partial-publication skip"; an unaccounted source column fell into
`upsert_input`'s catch-all and was dropped; and a source column whose
PostgreSQL type the target attribute cannot cast was coerced leniently by the
framework's cast layer. In every case the checkpoint advanced past data that
was never mirrored — permanent, invisible loss.

The B2 checkpoint row records only the DECLARED adapter contract. Nothing
read `pg_publication_tables` outside the snapshotter, and the framework's
connect chain checks publication NAMES only (a missing publication name
already halts there; table membership is invisible to it). The framework
auto-applies `:additive` Relation changes with no sink callback, so a source
`ADD COLUMN` flowed straight into the silent catch-all.

## Decision

- **One activation-time source-catalog preflight** on a short-lived,
  identity-verified second PostgreSQL connection (`pool_size: 1`, the
  snapshotter's precedent). It is NOT the ADR-0007 TOCTOU class: nothing
  durable binds from it (the manifest comes from the compiled DSL via the
  identity-verified bind path), and its own identity probe
  (`pg_control_system().system_identifier::text` + `current_database()` across
  the supported PostgreSQL 15 through 18 matrix)
  must equal the CONFIGURED identity the replication session separately
  proves. A wrong-node catalog read can only delay a halt to the first
  affected change (the per-change guard), never silently advance past one.
  An UNREACHABLE source defers the verdict (boot resilience: the pipeline
  cannot advance a checkpoint it cannot stream; the bind re-check completes
  the verdict on the first reachable connection).
- **A reconnect re-check at every bind** (rule 2/3 subset: mapped tables
  still published; publication tables mapped or ignored) — a mapped table
  dropped from the publication mid-run has NO streaming signal, and
  reconnect is an event the sink already participates in, not polling.
- **Delivery-side accounting**: the unmapped-table skip is REVERSED into a
  halt unless explicitly ignored, and every delivered column (streaming via
  `change.columns`, snapshot via record keys) must be mapped or skipped —
  before any write, so the admission transaction rolls back and the
  watermark never advances past an unmapped source.
- **Explicit ignores**: sink-level `ignored_sources` (strictly qualified
  `schema.table` strings; bare names and duplicates are compile errors;
  collision with a mapped relation is an activation error) for TABLES, and
  the existing resource-level `skip` for COLUMNS — both validated against
  the live catalog at activation. No third ignore surface: a skip is
  already manifest-recorded and classified (B2), and a promotion (skip →
  mapped column, ignore → mapped relation) is compatible coverage growth
  while an orphaned removal halts.
- **A static type matrix** per target attribute type (arrays unwrap;
  unknown/custom target types are not judged — the runtime Ash cast stays
  per-row fail-closed). Module-atom types normalize through
  `Ash.Type.storage_type/2`.
- **REPLICA IDENTITY FULL enforced at activation** for tenant-scoped mapped
  tables and SCD2 tables whose business key is not the source primary key
  (flat, no `USING INDEX` exemptions — an identity-precise admission was
  executed-disproven: under `relreplident 'd'` a non-key-changing UPDATE
  emits no old tuple, so admitting it wedges every ordinary update).
  Mid-stream identity and type changes are CARVED OUT of
  `on_schema_change :ignore` and always halt (they alter `old_record`
  meaning and the cast contract — the bases this decision stands on).
- **Source-connection storage**: the activation `:connection` opts are
  stored in the Generation (`:source_connection`) for the bind re-check —
  never logged, never in telemetry, node-memory trust domain; B5's secret
  scans remain the backstop.

## Consequences

- Every coverage rule violation halts BEFORE any checkpoint advance:
  missing expected tables, unignored publication tables, unmapped columns,
  missing declared columns, stale skips, invalid source types, wrong
  replica identity — at activation, at reconnect, or at the first
  delivered change.
- Breaking change: hosts relying on silent partial publication must declare
  `ignored_sources` (CHANGELOG migration note).
- Residual window (C5-owned): an operator DDL on a mapped table between
  reconnects with no change delivered on it is invisible until the next
  reconnect or restart. Steady-state polling is C5's continuous-invariant
  scope.
- `Resolver.writable_target/2` (dead, zero production callers) is removed.
- Boot-ordering consequence: a source unreachable at activation no longer
  paces reconnects inside Replicant — the verdict defers (documented in
  usage-rules) rather than crash-looping the host supervisor.

## Evidence

- `AshReplicant.Coverage` (evaluate/reconnect_check/preflight, the
  accounting guards, the type matrix, the relreplident census).
- `AshReplicant.Apply` / `AshReplicant.Sink.Impl` (the delivery-side halts,
  the carve-out).
- `test/ash_replicant/coverage_test.exs` (the rule matrix),
  `test/integration/source_coverage_test.exs` (the live red/green
  marquees), `test/integration/tenant_reassignment_test.exs` (RIF +
  reassignment marquees).
- Executed probes on the live substrate: the identity probe, the framework
  catalog SQL verbatim, the relreplident census, the PG18 disproof of the
  identity-precise RIF alternative.
