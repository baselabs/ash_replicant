# AshReplicant — Project Charter

**Status: realized, latest published package 0.4.0; 1.0.0 hardening in progress.**
The original state-mirror and SCD2 capabilities are shipped. The canonical
production-readiness scope and dependency order live in `docs/ROADMAP.md`.
Product-shaping decisions are tracked in `docs/adr/`; historical lifecycle
artifacts preserve their point-in-time testimony and are not current work queues.

## Purpose

Solve the Ash framework's CDC mirror / incremental-sync / multi-DC failover pattern
by adapting the proven `replicant` framework (tenant-blind, framework-agnostic CDC
consumer) to Ash resources, with effect-once semantics and fail-closed multitenancy.

## Mission

**AshReplicant** is the Ash `Replicant.Sink` adapter. It owns multitenancy
resolution, sensitive-data verification, resource mapping, host action execution,
and the atomic destination checkpoint. It delegates WAL transport, decoding,
transaction assembly, and acknowledgement ordering to `replicant`. Host validations,
changes, AshCloak hooks, and multitenancy run; policies are not re-gated because the
trusted sink executes with `authorize?: false`.

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
| **replicant** | PostgreSQL logical replication (pgoutput), transaction assembly, WAL ordering and acknowledgement |
| **Postgres** | logical decoding output |

## Scope

### In

- Ash resource extension (`replicant do … end` DSL section)
- Checkpoint-tracking resource macro (`use AshReplicant.Checkpoint`)
- Sink-config wrapper macro (`use AshReplicant.Sink`)
- `Replicant.Sink` behaviour implementation
- Multitenancy fail-closed validation (nil/`false`/blank tenant → error)
- Sensitive-column verification (AshCloak-encrypted or binary or skip)
- Resource resolver index (`{schema,table}` → resource mapping)
- Value-free error/telemetry boundaries
- Tenant-aware action execution (the `tenant:` option on the Ash action, resolved per-row from the source record's `tenant_attribute`)
- Validity-windowed SCD2 history mode (opt-in; close-current + insert-version)
- Destination commit-LSN checkpoint and snapshot callbacks

### Out (tenant-blind; lives in `replicant`)

- Transport, protocol, socket lifecycle
- Postgres logical replication slot / publication management
- WAL message decoding
- Transaction assembly and commit-LSN ordering
- Schema-change detection
- Snapshot extraction, chunking, and transport
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

**Decision:** If a source row's `tenant_attribute` or `tenant_mfa` resolves to nil/`false`/blank,
the mirror write fails and the transaction rolls back — no silent base-tenant fallback.
The sink fails closed EARLY: `Resolver.resolve_tenant/2` returns `{:error, :tenant_required}`
(nil/`false`/blank/whitespace) and `Resolver.resolve_tenant!/3` raises before the write is attempted
(defense in depth on top of Ash's own multitenancy validation). Additionally, at COMPILE time
a declared tenant source requires an Ash `multitenancy` block — `ValidateMultitenancy` rejects
a `tenant_attribute` **or** `tenant_mfa` with no block (Ash would otherwise silently ignore
`tenant:` and mirror every tenant unscoped), and the converse `ValidateTenantSource` rejects a
non-global multitenant resource with no tenant source. A tenant-scoped delete,
PK-changing update, or tenant reassignment needs the old tenant in `old_record`, so
the source table normally must be `REPLICA IDENTITY FULL`. A `tenant_mfa` must
resolve both new and old record shapes; an indeterminate old-side result halts
fail-closed (`:tenant_required` `side=old` / `:tenant_resolution_failed`) before any
write — the B4 amendment recorded in
[ADR-0001](adr/0001-fail-closed-multitenancy.md).

**Proof:** Compile-time `validate_multitenancy.ex` (both `tenant_attribute` and `tenant_mfa`
arms) + `validate_tenant_source.ex` (converse) + runtime `:tenant_required` in
`resolver.ex`/`apply.ex`; red-gates in `validate_multitenancy_test.exs` (both fail-opens
tripwired), `validate_tenant_source_test.exs`, `resolver_test.exs`, `apply_test.exs` (incl. the
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

The original 17-task build shipped on 2026-07-08. SCD2, fail-closed tenancy
verifiers, tenant reassignment, a dedicated integration database, CI, and optional
checkpoint policy authorization followed through 0.4.0. The 2026-08-13 hardening
foundation moved the repository to Elixir 1.20.3/OTP 29, Ash 3.31.3,
AshPostgres 2.11, Postgrex 0.22.4, ymlr 5.1.6, and AshOnetime 0.6.0 with clean
dependency audits and non-vacuous release gates.

Release history has one forensic caveat: Hex package 0.3.3 is real and its
packaged bytes match commit `3b61d3a9ae553fb96ff26e9fcf581416af723843`,
but no local or remote `v0.3.3` tag exists. It is an untagged release; the project
does not invent or move historical tags. GitHub Releases is incomplete for the
0.3.3 and 0.4.0 packages, so Hex plus immutable git commits/tags is the 0.x
release authority.

The current implementation order and acceptance criteria are derived from
`docs/ROADMAP.md`. Historical specs, plans, handoffs, and review reports remain
evidence for their original runs; they do not override the roadmap or live code.

## Destination and AshOnetime boundary for 1.0.0

The B1 implementation admits one recursive destination action graph before
delivery. Every mapped, checkpoint, relationship, cascade, and declared auxiliary
resource must use the same literal and effective AshPostgres Repo. Arbitrary
custom code declares its database effects through
`AshReplicant.DestinationParticipant`; `touches_resources` must match that closure.
This verifies the declaration, not the truth of an arbitrary Elixir body, so raw
SQL, another Repo, asynchronous work, and external effects remain forbidden behind
custom providers.

AshOnetime 0.6.0 is now used for WAL-safe local auxiliary idempotency as well as
being the governed mechanism for future C1 message actions. It does not replace
the transaction checkpoint. The accepted local profile is idempotency with the
action, fail-closed PostgreSQL storage in the admitted Repo, no external effect,
and the exact source-system/database/slot/commit-LSN/ordinal/participant identity.
The claim, response, auxiliary effect, mapped rows, and checkpoint share one
transaction. Nonce and independent-commit modes are rejected for WAL retry.

The permanent checkpoint remains the replay and resume authority. Transactional
logical messages will run inside their Replicant transaction; C1 separately owns
confidential message digests and ambiguous external-peer recovery. No message
action is implemented in 0.4.0. The full current boundary and trust limit are in
[ADR-0006](adr/0006-destination-transaction-boundary.md).

## References

- **`replicant`** (`../replicant`) — CDC framework; see `AGENTS.md` and `usage-rules.md`
- **`ash_postgres`** — Ash data layer for PostgreSQL
- **`AshCloak`** — Ash encryption extension; verifiers + before_action hooks
- **`CHANGELOG.md`** — version history
- **`usage-rules.md`** — host-integration rules for consumers
