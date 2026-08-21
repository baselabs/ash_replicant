# 5. Replicant 1.x coordination

Date: 2026-08-13

## Status

Accepted for the 1.0.0 release line. The final Decision bullet's deferral
("Persisting the accepted source identity and resolver/publication manifest
with checkpoint state remains B2 work") is discharged by
[ADR-0007](0007-source-bound-checkpoint-effect-once.md), which owns the
durable binding; the activation comparison decided here remains binding's
step 1.

## Context

AshReplicant previously admitted Replicant 0.3.x, which did not expose the
actual replication-session identity required to reject source drift before
checkpoint lookup. Replicant 1.0.0 added that frozen callback and the secure
Postgrex 0.22.4 floor. Replicant 1.1.0 then fixed valid float-array casting,
post-halt incremental-window rejection, and snapshot-reader connection-option
precedence. Replicant 1.2.0 added the typed slot-origin callback, fail-closed
unknown-checkpoint/absent-slot handling, and typed telemetry values; 1.2.1 bounds
keyed incremental-snapshot contention; 1.2.2 adds an explicit pre-first-chunk
pending state and safe live-slot origin recovery after a crash. A sibling checkout is not release evidence;
the consumer must prove the fetched Hex package and its callback ordering.

At the time of the original decision, the adapter supported only Replicant's v1
snapshot. Logical messages, sink-owned transaction batches, and incremental
snapshot progress remained disabled until their destination atomicity,
idempotency, and provenance contracts landed.

## Decision

- The public dependency is `>= 1.2.2 and < 2.0.0-0`. CI resolves exact 1.2.2 as
  the compatibility floor and the selector-free current lock, presently 1.2.2,
  as separate mandatory cells.
- Production activation requires an operator-pinned PostgreSQL system identifier
  and database. The generated sink compares those values plus the configured slot
  and normalized publication against `Replicant.SessionIdentity` from the actual
  replication connection before checkpoint lookup. It returns only a fixed
  structural mismatch error.
- Activation is serialized per slot. The resolver, identity, publication, and a
  unique generation reference are installed together. Failed-start cleanup may
  erase only its own generation; a duplicate cannot replace the active one.
- The adapter forwards Replicant's `streaming`, `max_inflight_lag`,
  `max_command_retries`, and `failover` options unchanged. It preserves v1
  `snapshot: true`; enables incremental mode only when every mapped resource has
  snapshot provenance; and exposes sink-owned batch and logical-message
  callbacks only through their destination-side atomicity and AshOnetime
  contracts. Append-log delivery remains absent until its separate contract
  lands.
- Release order is dependency first: Replicant 1.x is published and fetched before
  AshReplicant can publish a release requiring it. Tags are immutable. If a defect
  is found, publish a compatible Replicant patch and update the AshReplicant lock;
  retire an unsafe Hex release when warranted rather than moving a tag. If no safe
  compatible patch exists, AshReplicant publication remains blocked.
- Durable source identity and resolver/publication binding is owned by
  [ADR-0007](0007-source-bound-checkpoint-effect-once.md). The activation
  comparison here remains the first admission step before that checkpoint-bound
  contract is read or advanced.

## Consequences

- A production start without explicit source identity fails before the pipeline
  or resolver generation is active.
- Both the oldest admitted Replicant release and the current release are tested;
  a green current lock cannot substitute for the floor proof.
- Replicant 1.2.2's slot-origin, typed-telemetry, checkpoint/slot, bounded
  contention, and pending-backfill recovery fixes are mandatory release foundations. AshReplicant enables a
  Replicant mode only after its own destination-side contract lands.
- Rolling back AshReplicant code does not require moving Replicant tags. The safe
  Replicant floor remains 1.2.2; selecting an earlier 1.x package reintroduces
  data-integrity or value-safety defects and is not an admitted rollback.
- ADR-0007 carries the durable checkpoint binding required for source-bound
  effect-once semantics; this ADR continues to own the replication-session
  comparison that precedes it.

## Amendment (2026-08-20)

The original callback deferral is discharged by
[ADR-0015](0015-logical-message-effects.md),
[ADR-0016](0016-atomic-batch-delivery.md), and
[ADR-0017](0017-snapshot-provenance-and-restart.md). Those records own the live
message, batch, and incremental-snapshot contracts respectively. This amendment
does not enable append-log delivery; [ADR-0018](0018-append-log-delivery.md)
continues to own that boundary.

## Evidence

- `mix.lock` records Replicant 1.2.2 and Postgrex 0.22.4 from Hex.
- CI's compatibility matrix resolves exact Replicant 1.2.2 and selector-free
  current Replicant independently and asserts both versions.
- The release-contract checker verifies the Hex lock, public dependency shape,
  `SessionIdentity`, callback, and connection-order source from the fetched package.
- Live PostgreSQL integration tests prove identity-before-checkpoint and v1
  snapshot convergence, interruption, operator reset, retry, and stream resume.
