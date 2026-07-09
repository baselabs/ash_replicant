# AshReplicant — Project Charter

**Status: realized + closeout-reviewed.** All 17 plan tasks shipped & verified; `/review-autopilot --fix` closeout complete (2026-07-08). See `docs/superpowers/plans/2026-07-08-ash-replicant.md` (per-task ledger) and `docs/superpowers/reviews/2026-07-08-ash-replicant-lens-reports.md` (closeout).

## Purpose

Solve the Ash framework's CDC mirror / incremental-sync / multi-DC failover pattern
by adapting the proven `replicant` framework (tenant-blind, framework-agnostic CDC
consumer) to Ash resources, with effect-once semantics and fail-closed multitenancy.

## Mission

**AshReplicant** is the Ash `Replicant.Sink` adapter. It owns multitenancy
resolution, sensitive-data verification, policy enforcement, and resource mapping,
while delegating transport and exactly-once watermark to `replicant`.

```
replicant (tenant-blind CDC)
   ↓
AshReplicant (Ash sink adapter) ← HERE
   ↓
Ash resources + policies + multitenancy
```

This is "the `ash_postgres` of `replicant`" — just as `ash_postgres` is not
`postgrex`, `ash_replicant` is not `replicant`.

## Layering

| Layer | Responsibility |
|-------|-----------------|
| **Ash core** | multitenancy DSL, policies, the tenant concept |
| **AshReplicant** ← HERE | resource resolution, tenant routing, sensitive-column verification, mirror actions |
| **replicant** | PostgreSQL logical replication (pgoutput), transaction assembly, exactly-once watermark |
| **Postgres** | logical decoding output |

## Scope

### In

- Ash resource extension (`replicant do … end` DSL section)
- Checkpoint-tracking resource macro (`use AshReplicant.Checkpoint`)
- Sink-config wrapper macro (`use AshReplicant.Sink`)
- `Replicant.Sink` behaviour implementation
- Multitenancy fail-closed validation (nil/blank tenant → error)
- Sensitive-column verification (AshCloak-encrypted or binary or skip)
- Resource resolver index (`{schema,table}` → resource mapping)
- Value-free error/telemetry boundaries
- Tenant-aware action execution (the `tenant:` option on the Ash action, resolved per-row from the source record's `tenant_attribute`)
- Validity-windowed SCD2 history mode (opt-in; close-current + insert-version)

### Out (tenant-blind; lives in `replicant`)

- Transport, protocol, socket lifecycle
- Postgres logical replication slot / publication management
- WAL message decoding
- Transaction assembly and commit-LSN ordering
- Schema-change detection
- Exactly-once watermark (commit-LSN checkpoint)
- Snapshot / initial sync
- Multi-DC / physical-multitenancy logic

## Key Decisions (Resolved)

### [D1] Effect-once semantics via transaction-granularity commit-LSN watermark

**Decision:** Each `Replicant.Transaction` carries a single `commit_lsn`. The sink
skips any txn whose `commit_lsn <= checkpoint`. Rows are upserted by table PK, and
the checkpoint is upserted in the same `Repo.transaction`. A failure rolls the
entire txn back (fail-closed); on resume, the un-acked WAL re-streams and dedups
against the durable watermark.

**Proof:** Task 15 crash-injection marquee `test/integration/effect_once_test.exs`
(loss = 0, effect-dup = 0 via the append-only no-PK ledger, real PG16) plus the
sibling `replicant` crash-injection suite.

### [D2] Multitenancy is fail-closed; never a "base tenant" fallback

**Decision:** If a source row's `tenant_attribute` or `tenant_mfa` resolves to nil/blank,
the mirror write fails and the transaction rolls back — no silent base-tenant fallback.
The sink fails closed EARLY: `Resolver.resolve_tenant/2` returns `{:error, :tenant_required}`
(nil/blank/whitespace) and `Apply.resolve_tenant!/3` raises before the write is attempted
(defense in depth on top of Ash's own multitenancy validation). Note: a tenant-scoped
delete needs the tenant in `old_record`, so the source table must be `REPLICA IDENTITY
FULL` (closeout amendment; see AGENTS Critical Rule 2).

**Proof:** Compile-time `validate_multitenancy.ex` + runtime `:tenant_required` in
`resolver.ex`/`apply.ex`; red-gates in `resolver_test.exs`, `apply_test.exs` (incl. the
key-only-`old_record` fail-closed lock), and the non-global-tenant snapshot in
`snapshot_test.exs`.

### [D3] Sensitive = AshCloak-encrypted or binary; verified by type-shape

**Decision:** Every source column listed in `sensitive` must map to one of:
1. An AshCloak cloak attribute (detected via `AshCloak.Info.cloak_attributes!/1`)
2. A binary-storage attribute (user-managed encryption)
3. Listed in `skip` (excluded from mirror)

A `sensitive` column passes the verifier iff it is an AshCloak cloak attribute OR a
binary-storage attribute OR listed in `skip`. AshCloak is the single encryption
source of truth. The verifier runs at compile time and rejects a resource if a
`sensitive` column maps to an unencrypted or missing attribute.

**Proof:** Verifier in `validate_sensitive.ex` + the AshCloak-upsert spike (Task 2, `test/integration/cloak_upsert_spike_test.exs`).

### [D4] Tenant-blind layering: multitenancy one layer up, never in transport

**Decision:** `replicant` has no concept of tenant, tenant resolution, or row
classification. Those live here in `ash_replicant`. The split is enforced by
separate repos and separate test fixtures. Never import `ash_replicant` in
`replicant`.

**Proof:** Arch in `../replicant/AGENTS.md` + separate usage tests.

### [D5] Value-free at the boundary: no row value in error/log/telemetry

**Decision:** A sink failure (decode fault, resource resolution error, write fault)
produces an error reason (the `Replicant.Error` struct) and a fail-closed halt.
Errors are scrubbed before logging — never the column value, PK, tenant name, or
offending data. Telemetry is allowlisted (LSNs, table names, counts, durations,
error reasons) — never row values. Including the halt path.

**Proof:** Boundary in `sink/impl.ex` + redact logic in `error.ex`.

## Status Build Log

All 17 plan tasks shipped and verified on 2026-07-08, then closeout-reviewed
(`/review-autopilot --fix`). The **authoritative per-task ledger** (task → commit
sha, RED evidence, review rounds) lives in
`docs/superpowers/plans/2026-07-08-ash-replicant.md`; the closeout findings + fixes
in `docs/superpowers/reviews/2026-07-08-ash-replicant-lens-reports.md`. This charter
does not duplicate that ledger (a second copy only drifts).

## References

- **`replicant`** (`../replicant`) — CDC framework; see `AGENTS.md` and `usage-rules.md`
- **`ash_postgres`** — Ash data layer for PostgreSQL
- **`AshCloak`** — Ash encryption extension; verifiers + before_action hooks
- **`CHANGELOG.md`** — version history
- **`usage-rules.md`** — host-integration rules for consumers
