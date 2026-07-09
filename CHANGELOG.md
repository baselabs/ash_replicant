# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/baselabs/ash_replicant/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/baselabs/ash_replicant/releases/tag/v0.2.0
[0.1.0]: https://github.com/baselabs/ash_replicant/releases/tag/v0.1.0
