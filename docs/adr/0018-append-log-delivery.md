# 18. Append-log delivery is an exclusive host-owned sink

Date: 2026-08-19

## Status

Status: Proposed for the 1.0.0 release line (roadmap C4).

## Context

Replicant exposes `sink_kind/0` per generated sink, not per mapped resource.
AshReplicant currently hardcodes `:state_mirror`. A generic package event table
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
   not delivery paths.
3. `(source system, database, slot, commit LSN, ordinal)` is the append identity.
   A unique identity is a defensive database constraint; effect-once still rests
   on action plus checkpoint committing in the same locked destination
   transaction. Distinct same-transaction effects never overwrite one another.
4. Insert, update, delete, truncate, logical-message, snapshot, and batch shapes
   are explicit. Deletes use admitted old-record data; truncate is a structural
   event; snapshot rows carry their structural mode and checkpoint-owned attempt
   identity without reusing state-mirror row provenance fields; standalone message
   recovery retains ADR-0015's claim rules; a batch remains one transaction.
5. A fresh append sink declares exactly one initial-state intent: snapshot or
   go-forward. Go-forward consumes Replicant's typed slot-origin callback. On
   the first admitted activation it persists the callback origin as the
   immutable floor: a new slot supplies its `CREATE_REPLICATION_SLOT`
   `consistent_point`; a reused slot supplies its effective
   `START_REPLICATION` origin. Later reconnect origins are moving resume facts,
   never replacement floors; each must tie to the durable append checkpoint and
   last appended identity, and an origin ahead of that frontier halts as a gap
   before readiness. No completeness claim covers data before the floor.
6. Append payloads use the same tenant and sensitive-type rules as state mirrors.
   Unknown/unmapped values halt before insert; no row value enters structural
   diagnostics or default telemetry labels.

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
