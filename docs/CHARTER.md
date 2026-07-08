# AshReplicant — Project Charter

**Status: realized.** Tasks 1-15 complete. Task 16: documentation.

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

**Proof:** Task 15 spike (AshCloak + effect-once) and crash-injection suite in
`replicant` (loss = 0, effect-dup = 0, real PG16).

### [D2] Multitenancy is fail-closed; never a "base tenant" fallback

**Decision:** If a source row's `tenant_attribute` or `tenant_mfa` resolves to nil/blank,
the mirror write fails (the Ash changeset's multitenancy validation fires and rejects
the write). No silent base-tenant fallback. The transaction rolls back.

**Proof:** Verifiers in `validate_multitenancy.ex` (compile-time) and fail-closed
behavior in the sink's `handle_transaction/1`.

### [D3] Sensitive = AshCloak-encrypted or binary; verified by type-shape

**Decision:** Every source column listed in `sensitive` must map to one of:
1. An AshCloak cloak attribute (detected via `AshCloak.Info.cloak_attributes!/1`)
2. A binary-storage attribute (user-managed encryption)
3. Listed in `skip` (excluded from mirror)

A `sensitive` column passes the verifier iff it is an AshCloak cloak attribute OR a
binary-storage attribute OR listed in `skip`. AshCloak is the single encryption
source of truth. The verifier runs at compile time and rejects a resource if a
`sensitive` column maps to an unencrypted or missing attribute.

**Proof:** Verifier in `validate_sensitive.ex` + spike in Task 15.

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

| Task | Slice | Status | Date |
|------|-------|--------|------|
| 1 | Project scaffold | ✓ | 2026-07-01 |
| 2-5 | Core sink scaffoldding | ✓ | 2026-07-02 |
| 6 | Checkpoint macro | ✓ | 2026-07-03 |
| 7-11 | Resource extension + verifiers | ✓ | 2026-07-04 |
| 12-14 | Sink action + apply logic | ✓ | 2026-07-05 |
| 15 | Effect-once spike + AshCloak integration | ✓ | 2026-07-08 |
| 16 | Documentation (CLAUDE/AGENTS/CHARTER/README/etc.) | ✓ | 2026-07-08 |

## References

- **`replicant`** (`../replicant`) — CDC framework; see `AGENTS.md` and `usage-rules.md`
- **`ash_postgres`** — Ash data layer for PostgreSQL
- **`AshCloak`** — Ash encryption extension; verifiers + before_action hooks
- **`CHANGELOG.md`** — version history
- **`usage-rules.md`** — host-integration rules for consumers
