# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- `AshReplicant.DestinationParticipant.operation_key/2` now requires an
  `:invocation` label in the operation context (the sink mints it; manual
  minters — tests, replay probes — must carry the mint-site label). Closes the
  intra-change AshOnetime key collision where one change's two SCD2 closes
  shared a key and the second close replayed the first's stored response
  (ADR-0010). Upgrade note: sink-side claims live and die in the SAME
  transaction as their effects and the checkpoint (atomic), so no sink-side
  durable claim can survive across the upgrade — but any HOST-side store
  holding manually-minted keys under the old 6-component encoding must be
  drained before upgrading; admission already rejects independent-commit
  claims, so this only affects out-of-band host tooling.
- A notifier whose `load/2` returns a non-empty statement must implement
  `AshReplicant.DestinationParticipant` (`:notifier` kind): its dependency
  pre-load read executes inside the admitted transaction regardless of notify
  gates (ADR-0010).
### Added

- Completed value-free boundary: `catch :throw`/`:exit` at all six sink bodies;
  the schema-change fault path fires the sink's own `:halted` with the
  structural reason (previously mislabeled `:decode_failure` by the framework
  wrapper) (ADR-0009).
- Typed telemetry: per-key metadata types, a closed measurement-key set
  (`byte_size` reserved for C1), count-only off-allowlist raises, and a
  conformance integration gate over every emitted event name.
- `AshReplicant.Sql`: the one identifier quoting home (PG-canonical doubling,
  control-character rejection) — admission-time identifier validation in the
  manifest walk; all raw-SQL sites routed through it (ADR-0009).
- The action-contract freeze table (live-reflection source-pin test), the
  reason-space enumeration, and the Ash-bump grep procedure (CONTRIBUTING).
- Release-contract absence gates: `apply_ledger` (exactly the two allowlisted
  fail-closed lines) and a secret-literal scan over `lib/`.
- `AshReplicant.Apply.Context.invocation_labels/0` and
  `AshReplicant.DestinationParticipant.operation_components/0` (the single
  component-list home).
- Activation source-catalog preflight (roadmap B3): missing expected tables,
  unignored publication tables, unmapped columns, missing declared columns,
  stale skips, invalid source types, and wrong replica identity halt before
  any checkpoint advance; the check re-runs at every reconnect; an
  unreachable source defers the verdict. `ignored_sources` declares
  intentional partial publications. ADR-0008.
- Tenant reassignment is fail-closed (roadmap B4): both tenants resolve
  before any write; an absent/blank/false/raising old side — or a missing
  `old_record` — halts value-free; SCD1 relocates, SCD2 terminally closes
  under the old tenant. ADR-0001 amended.
- `AshReplicant.adopt_checkpoint/3`, `AshReplicant.reset_checkpoint/2`, and
  `AshReplicant.acknowledge_checkpoint_timeline/3` operator recovery surfaces,
  plus `AshReplicant.Checkpoint.Identity.refuse_ambiguous_legacy_rows!/1` /
  `legacy_checkpoint_row_count/1` for the slot-only upgrade path.
- ADR-0007 records the source-bound, serialized checkpoint decision.
- Adopt Replicant `>= 1.0.0 and < 2.0.0-0` from Hex, with current 1.1.0 and
  exact-floor 1.0.0 compatibility gates. Generated sinks now require and compare
  the actual replication-session system/database identity before checkpoint lookup.
- Add live Replicant 1.1.0 proofs for actual-session ordering, v1 snapshot-to-stream
  convergence, post-handoff restart, and operator-reset retry after an incomplete snapshot.
- Add AshOnetime 0.6.0 as the governed idempotency dependency for the logical-message
  actions planned for 1.0.0 and for admitted local auxiliary actions that need a
  WAL replay guard. The permanent commit-LSN checkpoint remains the transaction
  replay and resume authority.
- Add a deterministic recursive destination manifest covering checkpoint, mapped,
  framework-reached, SCD2, and declared auxiliary actions. It rejects foreign or
  dynamic Repos, non-Postgres resources, missing/opaque/cyclic participants, and
  `touches_resources` mismatches before delivery, then pins one effective Repo and
  generation through commit or rollback.
- Add `AshReplicant.DestinationParticipant` and a WAL-safe AshOnetime admission
  profile for local auxiliary actions: exact source/database/slot/LSN/ordinal/
  participant identity, private operation key, same-transaction fail-closed store,
  and explicit rejection of nonce, independent, external, and opaque profiles.
- Add independent CI paths for no-database tests, exact-floor/current-lock/latest-Ash
  live PostgreSQL integration, migration drift, Dialyzer, warnings-as-errors docs,
  and selector-free Hex package inspection. Checked-in assertions reject missing,
  skipped, invalid, excluded-without-authorization, or failing test evidence.
- Pin third-party CI actions to immutable commits, assert the executing
  Elixir/OTP identity, capture raw test failures without publishing values, and
  mutation-test the release-evidence, workflow, documentation, and migration
  checkers against masking and constant-accept regressions.
### Changed

- **Breaking:** an unmapped publication table now HALTS
  (`:source_table_unmapped`) instead of the silent partial-publication
  skip — declare `ignored_sources` for intentional partial coverage. An
  unaccounted delivered column halts (`:source_column_unmapped`).
  `:replica_identity_changed` and `:type_changed` schema changes always
  halt regardless of `on_schema_change :ignore`.
- **Removed:** `Resolver.writable_target/2` (dead code) and
  `Resolver.tenant_changed?/2` (its fail-open caveat is the class B4
  closed).
- **Breaking:** the generated checkpoint resource is source-bound — the
  composite primary key is `(source_system_id, source_database, slot_name)`
  from the actual replication session, with `source_timeline`,
  `publication_contract`/`publication_fingerprint`, nullable-until-first-commit
  `commit_lsn`, reserved snapshot-frontier columns, timestamps, the
  `:source_slot` identity, and a named `:operator_reset` destroy action. The
  slot-only `:unique_slot` identity is gone and the shape change requires a
  migration; see the upgrade runbook (usage-rules.md).
- The sink binds the checkpoint row inside `handle_session_identity/2` (now a
  mutating, lease-held callback) on every connect: a foreign same-slot
  identity, a changed timeline, a watermark ahead of the session's WAL flush
  position, or an incompatible contract transition halts fail-closed with
  value-free reasons and a `[:ash_replicant, :checkpoint, :conflict]` event.
- Admission takes the checkpoint row `FOR UPDATE` inside the destination
  transaction; lower/equal LSNs never regress or reapply and concurrent
  callers produce one effect. An absent row at admission is a permanent
  `:checkpoint_unbound` halt (restart re-binds). The v1 snapshot handoff no
  longer regresses the watermark on a re-delivered consistent point.
- Serialize resolver activation per slot, generation-check rejected-start cleanup,
  and forward Replicant's safe `streaming`, `max_inflight_lag`,
  `max_command_retries`, and `failover` transport options. Incremental snapshots,
  batch delivery, and logical messages remain capability-gated for their owning rows.
- Scope the current physical effect-once guarantee to committed streaming
  transactions and atomic snapshot batches. An incomplete Replicant v1 multi-batch
  snapshot restart can repeat already committed batch effects before rebuilding the
  target; C3 must remove those repeats before the stable snapshot-restart claim.
- Require Elixir 1.20.3/OTP 29 and the AshPostgres 2.11 dependency family for the
  1.0.0 release line.
### Security

- Raise the 1.0.0 dependency floor to audit-clean Ash 3.31.3 and exclude Ash 4
  prereleases; resolve Postgrex 0.22.4 and ymlr 5.1.6 so `mix hex.audit` and
  `mix deps.audit` report no known advisories.
- Make generated delivery callbacks invoke the admitted sink implementation
  directly; remove the overridable effect hook that could acknowledge WAL without
  applying rows/checkpointing. Reject data-layer `SetContext` redirection and
  behavior-conforming external AshOnetime caches at destination admission.
- Give v1 snapshots ONE continuing operation-ordinal space per run (keyed by the
  exported consistent point). A per-table space minted identical operation keys
  for table A row i and table B row i whenever two mapped resources shared one
  participant atom, and AshOnetime replayed A's stored response for B — silently
  suppressing B's declared auxiliary effect. Proven live by a two-table
  same-participant snapshot marquee.
- Reject unknown or removed `use AshReplicant.Sink` options at compile time
  (including the removed `apply_ledger`) instead of silently dropping them — a
  host upgrading across the removal now gets a compile failure, not a
  silently-gone ledger.
- Admit the dynamic (MFA) `set_context` form only when the module behind the MFA
  declares its effects through `AshReplicant.DestinationParticipant`; static-map
  contexts still may not replace `:data_layer`. The core-code fingerprint now
  covers every delivery-reachable module including the value-free telemetry
  allowlist enforcer.
- Close four cross-vendor-admission bypasses found by the peer review: a
  `set_context` may no longer touch `:shared` (Ash promotes it over the whole
  context, so a nested `shared.data_layer` redirected the destination) or the
  sink-owned `:ash_replicant_operation` identity (a forged operation context
  would mint one replay key for every row); `prepare build(context: ...)` is
  rejected (Ash.Query.build's context option redirects `data_layer`); and every
  admitted action — including declared auxiliary participants — must keep its
  tenant scoping (`multitenancy :bypass`/`:bypass_all` is rejected, closing
  cross-tenant auxiliary effects). Streaming transactions carry an explicit
  120s timeout (the per-change generation guards can exceed DBConnection's 15s
  default at scale, deterministically wedging replication), and a sink callback
  defined BEFORE `use AshReplicant.Sink` now also fails compilation (it would
  win dispatch and skip the generation guard, activation lock, and repo pin).
- Completed the cross-vendor value-free closure over every error-shaped input:
  `Error.scrub`/`Error.scrub_caught` trust no field of an incoming error
  struct — a forged `:reason` or `:shape`, via raise, throw, or the rollback
  verb, survives only as the closed typed reason — and the reason space is
  pinned to the library's finite set. The telemetry `span/3` is hand-rolled
  so an exception event carries the class only and no malformed-result path
  renders a value. `:bulk_create` joins the sink-owned context keys (a host
  `SetContext` over the framework's per-row snapshot index would alias a
  whole batch onto ONE operation key — the replay-suppression class), the
  generation code-fingerprint covers `AshReplicant.Sql`, and the legacy-row
  count probe routes through the quoting home. Gate-integrity pins: live
  mint-site label equality, a bidirectional mint-site ↔ frozen-label
  inventory, strict-walk cycle detection on the destination manifest, and a
  load-realistic await for the concurrent-start race.

### Fixed

- Admit the census preflight connection BEFORE starting a pool: a
  postgrex-UNRESOLVABLE `:connection` database (absent key with no
  `PGDATABASE`, or an explicit nil — postgrex discovers the missing
  `:database` key only inside the pool's async connect) now defers as the
  unreachable class immediately, instead of starting a pool that can never
  connect, logging `[error] missing the :database key` on every backoff
  retry while burning the checkout queue-timeout on every bind. The gate
  mirrors postgrex's own resolution (`Utils.default_opts/1` — the same
  resolution the replication stream applies), so a `PGDATABASE`-configured
  source is censused, never deferred, and the census and the stream cannot
  disagree. This is what made the live structural battery fail its own
  no-error gate with every test passing; a host misconfiguring the
  connection keyword hit the same doomed-pool burn at runtime. Sync-start
  failures return the structural `{:error, :unreachable}` (callers defer
  through their census-fault branch and never query or stop a placeholder
  connection), and the dead-for-pools `sync_connect: true` merge is dropped
  (only the replication connection reads that option).
- The forced-reconnect marquee captures the replication connection's
  expected `[error]` reconnect line (the `start_link_test` precedent), which
  otherwise order-dependently trips the same battery gate.
- Dialyzer green again: `legacy_checkpoint_row_count/2`'s spec now admits
  the `{:error, :checkpoint_probe_failed}` probe-failure leg its body
  already returns (the caller handled it), and the census preflight's
  catch-all scrub — unreachable once admission returns error-tagged
  connections — is removed (the closed-case shape `reconnect_check/5`
  already uses).
- Reconcile public policy, snapshot, tenancy, notifier, and release-history
  documentation with live code. Host policies are not re-gated, the current
  adapter supports v1 snapshots only, and tenant reassignment requires the old
  tenant record shape.
- Split checkpoint policy introspection from its six live enforcement cases so
  `mix test --exclude integration` runs successfully without starting TestRepo.
- Cover SCD2 resources in migration drift and observe TestRepo start attempts in
  the same VM as the database-free suite.
- Decode release workflows as YAML, require independently executable gate steps,
  bind compatibility selection to its exact unlock/assert block, and validate
  visible non-contradictory runtime documentation. Independent mutations now
  cover every protected release-evidence decision.
- Reconciled the published docs with shipped code: the tenant-reassignment
  old-side fail-closed guard is SHIPPED (`:tenant_required` `side=old` /
  `:tenant_resolution_failed`, fail-closed before any write), not open
  roadmap work (README, usage-rules, CHARTER now say so); the live
  integration gate's PostgreSQL statement records the actual split (CI pins
  16, the local substrate is 18, the support matrix is PG15–18); relative
  ADR links normalize to the canonical GitHub form; and the cloak-upsert
  spike's PG16 note reads as the historical proof it is.
  `AshReplicant.Sql`, `AshReplicant.Apply.Context`, and
  `AshReplicant.Checkpoint.Identity` carry real moduledocs (their
  comment-docs, promoted) so the reference-checked docs gate is green over
  the surfaces the docs already advertised.

## [0.4.0] - 2026-08-03

### Added

- **`use AshReplicant.Checkpoint` accepts an `authorizers:` option**, so the generated
  checkpoint resource can carry `Ash.Policy.Authorizer` and enforce host-declared
  `policies do` blocks. The checkpoint is an internal watermark; a host that exposes its
  domain on a wire surface (JSON:API, MCP) previously had no way to lock the checkpoint
  down, because the macro emitted a resource with no authorizer and `policies` is not a
  declarable section without one. The sink still reads/upserts with `authorize?: false`
  on both paths (`Sink.Impl.read_checkpoint/1`, `upsert_checkpoint/2`), so effect-once is
  unaffected by whatever policies the host declares — including none, which fail-closes
  the resource to every actor except the sink. `authorizers:` defaults to `[]`, identical
  to the option Ash already defaults to, so existing hosts get the byte-for-byte prior
  resource (no behaviour change). Verified against live logical-replication Postgres:
  `checkpoint_policy_test.exs` proves the authorizer + policies are present, a non-system
  actor is denied (hard `Forbidden`), a system actor is allowed, and the sink's
  `authorize?: false` path bypasses both.

## [0.3.3] - 2026-08-02

> **Release provenance:** 0.3.3 was published to
> [Hex](https://hex.pm/packages/ash_replicant/0.3.3). Every packaged
> source/document byte matches commit
> [`3b61d3a`](https://github.com/baselabs/ash_replicant/commit/3b61d3a9ae553fb96ff26e9fcf581416af723843).
> The publishing checkout itself is not independently recorded. No `v0.3.3` Git
> tag or GitHub Release was created; current documentation does not invent one.

### Fixed

- **Tenant reassignment on the SCD2 path no longer leaves a double-current version.** The
  0.3.2 relocate fix covered only the SCD1 (upsert) path. On the SCD2 (validity-windowed)
  path a tenant reassignment (same business key, new tenant) left the OLD-tenant version
  OPEN forever while opening a fresh current version under the NEW tenant — the entity read
  as "current" under BOTH tenants (a silent double-current split; a per-tenant open-uniq
  index permits it, so no error surfaced). `Apply.Scd2` now terminally closes the old-tenant
  version on a resolved-tenant change (in addition to a business-key change), relocating the
  row. Regression test: `scd2_apply_test.exs` "tenant-reassigning update terminally closes
  the OLD-tenant version and opens under the NEW tenant".
- **Value-free preserved on the tenant-change check.** The reassignment predicate was
  promoted to `Resolver.tenant_changed?/2` and made scrub-safe: a raising `tenant_mfa`
  resolver is caught inside the check and reported as "not changed" (never propagating an
  unscrubbed row value out of the pre-apply tenant comparison, which sits outside the
  per-op scrub boundary). Both apply paths share the one helper.

### Notes

- Tenant-scoped mirrors REQUIRE `REPLICA IDENTITY FULL` on the source for reassignment
  detection: the check needs the old row's tenant, which is key-only under the default
  replica identity. Without RIF a genuine reassignment falls through to the pre-0.3.2
  behavior (SCD1: the colliding upsert; SCD2: the double-current) — the same `old_record`
  dependency already documented for tenant-scoped deletes/PK-changes.
- Reassignment detection also depends on a NON-RAISING tenant resolver. `Resolver.tenant_changed?/2`
  treats a raising `tenant_mfa` as "not changed" (value-free), so an MFA that raises on
  `old_record` makes a reassignment invisible and the caller keeps its non-relocating path.
  `tenant_attribute` resolvers never raise; this affects only `tenant_mfa` and is not a
  regression (no path handled reassignment before 0.3.2/0.3.3).

## [0.3.2] - 2026-08-02

### Fixed

- **Tenant reassignment no longer halts the mirror stream.** When a source row's tenant
  attribute changed (same PK, new `tenant_attribute` value), a resource declaring a
  tenant-scoped upsert identity (`identity :source_pk, [pk]` under attribute multitenancy →
  a `(tenant, pk)` unique index) would fall through to an INSERT under the new tenant that
  collided with the row's GLOBAL primary key (the still-present old-tenant row). The upsert
  raised, the sink transaction rolled back, and the checkpoint froze — a fail-closed poison
  pill that stalled delivery for ALL tenants and retained source WAL indefinitely. `Apply`
  now treats a resolved-tenant change like a PK change: destroy the old-tenant row (resolved
  from `old_record`) then upsert under the new tenant, relocating the mirror row. Triggers
  only when both tenants resolve and differ, so non-multitenant resources and key-only
  `old_record` updates (no REPLICA IDENTITY FULL) are unchanged. Regression test:
  `apply_test.exs` "tenant-reassigning UPDATE … MOVES the row to the new tenant".

## [0.3.1] - 2026-08-02

### Changed

- Widen the `replicant` requirement from `~> 0.1.0` to `~> 0.3` so consumers can adopt the
  current replicant line (0.3.x) without a resolver conflict. ash_replicant calls only
  replicant's stable core (`Replicant.{Change, SchemaChange, Sink, Transaction, lsn}`,
  `Replicant.start_link/1`, `Replicant.stop/1`); verified compatible against replicant 0.3.1:
  `mix compile --warnings-as-errors` clean and `mix test` 90 passed / 0 failed (unit suite;
  the `:integration` gate — 52 tests needing a live `wal_level=logical` DB via
  `ASH_REPLICANT_TEST_URL` — is owed in CI before publish). No API or behavior change.

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
  See [ADR-0001](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0001-fail-closed-multitenancy.md).
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

[Unreleased]: https://github.com/baselabs/ash_replicant/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/baselabs/ash_replicant/tree/v0.4.0
[0.3.3]: https://github.com/baselabs/ash_replicant/commit/3b61d3a9ae553fb96ff26e9fcf581416af723843
[0.3.2]: https://github.com/baselabs/ash_replicant/tree/v0.3.2
[0.3.1]: https://github.com/baselabs/ash_replicant/tree/v0.3.1
[0.3.0]: https://github.com/baselabs/ash_replicant/tree/v0.3.0
[0.2.0]: https://github.com/baselabs/ash_replicant/tree/v0.2.0
[0.1.0]: https://github.com/baselabs/ash_replicant/tree/v0.1.0
