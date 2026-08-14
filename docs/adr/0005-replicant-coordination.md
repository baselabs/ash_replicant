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
precedence. A sibling checkout is not release evidence; the consumer must prove
the fetched Hex package and its callback ordering.

The adapter already supports Replicant's v1 snapshot. It does not yet implement
logical messages, sink-owned transaction batches, or incremental snapshot
progress. Advertising those callbacks early would enable modes whose destination
atomicity, nonce, and provenance contracts are owned by later roadmap rows.

## Decision

- The public dependency is `>= 1.0.0 and < 2.0.0-0`. CI resolves exact 1.0.0 as
  the compatibility floor and the selector-free current lock, presently 1.1.0,
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
  `snapshot: true` and rejects incremental snapshot mode until durable progress
  and target provenance land. Batch and message callbacks remain absent until
  their atomicity and AshOnetime contracts land.
- Release order is dependency first: Replicant 1.x is published and fetched before
  AshReplicant can publish a release requiring it. Tags are immutable. If a defect
  is found, publish a compatible Replicant patch and update the AshReplicant lock;
  retire an unsafe Hex release when warranted rather than moving a tag. If no safe
  compatible patch exists, AshReplicant publication remains blocked.
- Persisting the accepted source identity and resolver/publication manifest with
  checkpoint state remains B2 work. This activation comparison does not claim a
  source-bound durable checkpoint.

## Consequences

- A production start without explicit source identity fails before the pipeline
  or resolver generation is active.
- Both the oldest admitted Replicant release and the current release are tested;
  a green current lock cannot substitute for the floor proof.
- Replicant 1.1.0's v1 snapshot and casting fixes are consumed without prematurely
  enabling its incremental, batch, or message surfaces.
- Rolling back AshReplicant code does not require moving Replicant tags. Operators
  can select a safe compatible 1.x package while the public range remains valid.
- B2 must migrate the activation-only identity into durable checkpoint binding
  before AshReplicant can claim source-bound effect-once semantics.

## Evidence

- `mix.lock` records Replicant 1.1.0 and Postgrex 0.22.4 from Hex.
- CI's compatibility matrix resolves exact Replicant 1.0.0 and selector-free
  current Replicant independently and asserts both versions.
- The release-contract checker verifies the Hex lock, public dependency shape,
  `SessionIdentity`, callback, and connection-order source from the fetched package.
- Live PostgreSQL integration tests prove identity-before-checkpoint and v1
  snapshot convergence, interruption, operator reset, retry, and stream resume.
