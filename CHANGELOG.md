# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-07-14

### Added

- **SCD2 history mirroring** — a per-resource opt-in (`history_strategy :scd2`) that
  mirrors a source table into a host-defined validity-windowed version table
  (close-current + insert-version) instead of overwriting current state. Effect-once,
  fail-closed multitenancy, value-free boundaries, and Critical Rule 1 preserved; new
  `ValidateHistory` compile verifier; `on_truncate :close`. Audit-log needs remain
  served by AshPaperTrail on an SCD1 mirror.

### Security

- **Multitenancy fail-closed at compile time — both tenant sources.**
  `ValidateMultitenancy` now requires an Ash `multitenancy` block whenever a
  `tenant_attribute` **or** a `tenant_mfa` is declared. Without a block Ash silently
  ignores the `tenant:` option the sink passes, so every tenant's rows mirror **unscoped**
  into one table — a proven fail-open with no runtime error. The `tenant_attribute` arm
  shipped 2026-07-10; the symmetric `tenant_mfa` arm closes the parallel hole (2026-07-14).
  Any strategy (`:attribute` or `:context`), including a `global?` block, satisfies the gate.
  See [ADR-0001](docs/adr/0001-fail-closed-multitenancy.md).
- **A `false`-resolved tenant now fails closed.** `Resolver.resolve_tenant/2` rejected only
  `nil`/blank-string tenants; a `tenant_attribute` column holding boolean `false` or a
  `tenant_mfa` returning `false` resolved to `{:ok, false}`. Ash treats a falsy tenant as
  **no scoping** (neither force-set nor required), so the mirror write landed **unscoped**
  across tenants. `false` now returns `:tenant_required` like `nil` (2026-07-14).
- **Sink-selected actions can no longer bypass tenancy.** A new
  `ValidateActionMultitenancy` compile verifier rejects `multitenancy :bypass` / `:bypass_all`
  on the host's primary **read**, create, destroy, and the SCD2 close action of a multitenant
  resource — Ash would otherwise ignore the tenant the sink passes and mirror every tenant
  **unscoped** (and a `:bypass` read would let a `bulk_update`/`bulk_destroy` match and mutate
  another tenant's rows), despite a valid multitenancy block. `:enforce` and `:allow_global`
  remain permitted (2026-07-14).
- **The multitenancy discriminator column is now shape-checked.** Under `strategy :attribute`,
  `ValidateMultitenancy` rejects a `sensitive`-classified or binary-storage-typed multitenancy
  `attribute` — Ash force-sets it to the plaintext tenant and filters reads on it, so an
  encrypted/binary column would store/compare a mismatched value and **silently mis-scope**
  (reads return empty). AshCloak-encrypted attributes are already rejected by Ash's own verifier
  (2026-07-14).

## [0.2.0] - 2026-07-09

### Added

- **`ValidateTenantSource` compile-time verifier** — a resource declaring
  non-global Ash multitenancy must declare a `replicant` tenant source
  (`tenant_attribute` or `tenant_mfa`). Without one, every mirror write is
  attempted with `tenant: nil` and halts fail-closed (`:tenant_required`) at
  runtime; this gate moves that failure to build time. It is the converse of
  `ValidateMultitenancy` (which checks the shape of a declared discriminator).

### Fixed (closeout review, 2026-07-08 — `/review-autopilot --fix`)

- **Snapshot fails closed on an empty resolver index** — `handle_snapshot/3` and
  `handle_snapshot_complete/2` now share the `handle_transaction/2` fail-closed guard
  (a degenerate/misloaded index no longer silently drops a backfill while advancing
  the checkpoint).
- **`on_truncate :mirror` clears tenant-blind** — was a `TenantRequired` dead-end for
  non-global attribute-multitenant resources; now a quoted raw `DELETE` on the mirror
  table (matching the snapshot redo-safety clear).
- **Full telemetry contract** — the `[:ash_replicant, :snapshot, :batch]` /
  `[:snapshot, :complete]` events (previously never emitted), `:sink,:halted`
  `error_class`, and `:sink,:applied` `change_count` + `duration` measurements are now
  emitted (`change_count` counted single-pass).
- **`transaction?: false`** on the per-record upsert (the sink owns the outer
  transaction the action joins).

### Documented (closeout review)

- **Tenant-scoped source tables must be `REPLICA IDENTITY FULL`** — a tenant-scoped
  delete / PK-changing update resolves the tenant from `old_record`, which is key-only
  under the default replica identity (else the sink halts fail-closed
  `:tenant_required`). Documented in AGENTS Critical Rule 2, the `tenant_attribute`
  DSL doc, README, and usage-rules; locked by a key-only-`old_record` red-gate.

### Optimized (post-closeout, 2026-07-09)

- **Snapshot bulk path computes its reflection once per batch** — the non-tenant
  bulk upsert derives the `{skip, cloak, attribute-name}` reflection a single time
  (`Resolver.upsert_reflection/1` + `Resolver.upsert_input/2`) instead of re-deriving
  it per row; `attrs_for_upsert/2` is retained for single-record callers. Behavior
  unchanged (F13).
- **Delete path is a single atomic `bulk_destroy`** — `Apply.destroy_by_pk/3` issues
  one `DELETE ... WHERE pk` (`strategy: [:atomic, :stream]`, `transaction: false`)
  instead of read-then-destroy, falling back to per-record streaming when a host
  destroy action carries non-atomic changes. The nil-PK fail-closed guard, per-row
  tenant scoping, and idempotent-on-absent-row semantics are preserved (F14).

## [0.1.0] - 2026-07-08

First release: the complete Ash `Replicant.Sink` adapter with effect-once
semantics, fail-closed multitenancy, AshCloak integration, and compile-time
sensitive-column verification.

### Added

- **Ash resource extension** (`AshReplicant.Resource`) — a `replicant do ... end`
  DSL section for marking AshPostgres resources as CDC mirror targets. Options:
  `source_table`, `source_schema`, `tenant_attribute`, `tenant_mfa`, `sensitive`,
  `skip`, `on_truncate`, `on_schema_change`, `upsert_identity`.

- **Checkpoint macro** (`AshReplicant.Checkpoint`) — generates an AshPostgres
  resource backing the `ash_replicant_checkpoints` table (one row per slot,
  tracking the durable `commit_lsn` watermark). Bound to the host's repo and
  domain at compile time.

- **Sink-config macro** (`AshReplicant.Sink`) — generates a `Replicant.Sink`
  implementation with repo, domains, checkpoint resource, and `slot_name` baked in.
  The `slot_name` is the single source of truth for the replication slot (not a
  `start_link` option) and keys the resolver index.

- **Resource resolver** (`AshReplicant.Resolver`) — maps `{schema, table}` pairs
  to resources, built from the sink's domains. The index is cached in
  `:persistent_term` and accessed by the sink's transaction handler.

- **Sink action applier** (`AshReplicant.Apply`) — applies changes to mirror
  resources: upsert by PK, destroy, truncate per policy. Actions are the host's
  own resource actions; the sink invokes them with `authorize?: false` at the
  boundary (the host's Ash policies still guard those actions for application
  callers; the flag exempts only the sink's in-transaction mirror writes from
  re-gating). Tenant is passed per-row.

- **Compile-time verifiers** — enforce critical rules:
  - `ValidateSensitive`: each sensitive column maps to an AshCloak-encrypted
    attribute, a binary-storage attribute, or is skipped.
  - `ValidateMultitenancy`: a multitenant resource with a `tenant_attribute` has
    a plaintext, declared discriminator; the tenant is never classified or skipped.

- **Value-free error & telemetry boundaries** — sink failures and halt paths carry
  structure (error reason, table name, LSN) only. No row values, PKs, tenant names,
  or raw data appear in logs, errors, or telemetry. Column names are strings, never
  atoms.

- **Effect-once transaction model** — each `Replicant.Transaction` applies in one
  `Repo.transaction`: skip by commit-LSN watermark, apply rows, upsert checkpoint
  atomically. Failure rolls back; on resume, un-acked WAL re-streams and dedups
  against the durable checkpoint. Proven by crash-injection tests (loss = 0,
  effect-dup = 0).

- **Documentation** — `CLAUDE.md`, `AGENTS.md`, `README.md`, `CHANGELOG.md`,
  `usage-rules.md`, `CONTRIBUTING.md`, `LICENSE`, `NOTICE`; tracked charter at
  `docs/CHARTER.md` (only `/docs/superpowers/` lifecycle artifacts are local-only).

[Unreleased]: https://github.com/baselabs/ash_replicant/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/baselabs/ash_replicant/releases/tag/v0.3.0
[0.2.0]: https://github.com/baselabs/ash_replicant/releases/tag/v0.2.0
[0.1.0]: https://github.com/baselabs/ash_replicant/releases/tag/v0.1.0
