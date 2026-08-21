# 18. Append-log delivery is an exclusive host-owned sink

Date: 2026-08-19

## Status

Status: Accepted and implemented for the 1.0.0 release line (roadmap C4).

## Context

Replicant exposes `sink_kind/0` per generated sink, not per mapped resource.
AshReplicant previously hardcoded `:state_mirror`. A generic package event table
would bypass the host's tenancy, classification, schema, retention, and action
contracts, while mixing mirror and append resources in one sink cannot be
represented by the transport callback.

## Decision

1. A generated sink is exclusively `:state_mirror` or `:append_log`. Activation
   rejects mixed resource kinds before starting Replicant.
2. An append target is a host-owned AshPostgres resource in the admitted Repo
   with an immutable create action. The resource declares structural attributes
   for source system, database, slot, commit LSN, ordinal, operation, and origin,
   plus mapped classified payload attributes. Update/upsert/destroy actions are
   not delivery paths. Manual append actions and arbitrary action/global create
   changes are rejected because they can rewrite a sink-minted identity axis
   after input admission; only AshCloak encryption of non-structural payload is
   admitted.
3. `(source system, database, slot, commit LSN, ordinal)` is the append identity.
   A unique identity is a defensive database constraint; effect-once still rests
   on action plus checkpoint committing in the same locked destination
   transaction. Distinct same-transaction effects never overwrite one another.
4. Insert, update, delete, truncate, logical-message, snapshot, and batch shapes
   are explicit. Deletes use admitted old-record data; truncate is a structural
   event; snapshot rows carry their structural mode and checkpoint-owned attempt
   identity without reusing state-mirror row provenance fields. In an append
   sink, a routed logical message uses the same append action and identity: a
   transactional message uses its transaction commit LSN and shared ordinal; a
   standalone message uses its WAL LSN and ordinal zero. The host declares
   destination-only prefix and binary-content attributes. State-mirror message
   routes retain ADR-0015's AshOnetime claim rules; a batch remains one transaction.
5. A fresh append sink declares exactly one initial-state intent: snapshot or
   go-forward. Go-forward consumes Replicant's typed slot-origin callback. On
   the first admitted activation it persists the callback origin as the
   immutable floor: a new slot supplies its `CREATE_REPLICATION_SLOT`
   `consistent_point`; a reused slot supplies its effective
   `START_REPLICATION` origin. Later reconnect origins are moving resume facts,
   never replacement floors. A slot created this session under an existing floor
   proves replacement and halts as a gap; Replicant never idle-advances an
   append slot, so a reused origin above the durable watermark is also a gap. The
   highest appended identity must never exceed the durable checkpoint. No
   completeness claim covers data before the floor.
6. Append payloads use the same tenant and sensitive-type rules as state mirrors.
   Unknown/unmapped values halt before insert; no row value enters structural
   diagnostics or default telemetry labels.
7. Replicant 1.2.3 is the transport floor. Append sinks retain filtered WAL until
   an actual append delivery or an explicit published heartbeat provides the
   durable release point; a transport idle-advance cannot discard a quiet
   append publication before AshReplicant observes it.

## Consequences

- Append support adds no package-owned data table, public testing API, or raw
  destination write path.
- Separate mirror and append pipelines may use separate slots and checkpoints;
  the release does not claim one slot can serve both sink kinds.
- Navyler may use its own append-only observer resource for release evidence,
  but that resource is consumer-owned and not part of AshReplicant's API.

## Required proof before acceptance

- Live insert/update/delete/truncate/message/snapshot/batch/replay tests,
  tenant/classification failures, same-LSN ordinal uniqueness, origin-floor
  persistence for new and reused slots, reconnect-gap rejection, and a
  dedup-bypass mutation whose observer count goes red.

## Implementation notes

Two clauses were sharpened against the transport's actual behaviour while
implementing this; both are recorded here because the ADR's wording alone would
have produced a wrong gate.

1. **Append logs do not use the filtered-WAL idle advance.** Replicant's generic
   idle keepalive path advances a slot to `wal_end` without writing the sink's
   checkpoint. An Ash-only origin comparison therefore cannot distinguish that
   healthy advance from an out-of-band `pg_replication_slot_advance`. The
   architecture was re-scoped at the transport lifecycle: Replicant excludes
   `sink_kind: :append_log` from idle advancement. A reused origin above the
   durable checkpoint is now unambiguously an out-of-band gap and halts
   `:append_origin_gap`; a slot created under an existing floor also halts. A
   quiet append publication uses a normal published heartbeat to release WAL.
   A rejected durable-idle-callback alternative was proved invalid because
   writing its receipt to a same-cluster PostgreSQL destination generates more
   filtered WAL and recursively advances the frontier it is trying to record.

2. **A `strategy :context` append target is refused on a go-forward sink.** The
   frontier tie-out ("tie to the durable append checkpoint and last appended
   identity") is a tenant-blind read over each append target's own table, and
   context multitenancy resolves that table's schema per tenant — there is no
   statically addressable table to read a tenant-spanning frontier from.
   Activation fails `:append_frontier_unavailable` rather than skipping the
   tie-out silently. A snapshot-intent append sink is unaffected.

An append sink cannot run Replicant's INCREMENTAL snapshot mode: incremental
activation requires every mapped resource to declare `snapshot_provenance
true`, which this ADR forbids on an append target. The combination fails
`:snapshot_unsupported` at activation.
