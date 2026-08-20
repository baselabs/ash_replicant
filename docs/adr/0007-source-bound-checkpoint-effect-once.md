# 7. Source-bound, serialized checkpoints

Date: 2026-08-14

## Status

Accepted for the 1.0.0 release line. The admitted-effects side of this
decision carries the per-invocation operation discriminator from
[ADR-0010](0010-host-action-contract.md) (each invocation of a declared
participant within one change mints its own AshOnetime key; this decision's
watermark discipline is unchanged).

Supersedes the checkpoint wording of [ADR-0005](0005-replicant-coordination.md)
(the activation identity comparison remains in force as step 1 of binding; the
"persisting the accepted source identity … remains B2 work" deferral is
discharged) and of [ADR-0006](0006-destination-transaction-boundary.md) ("the
checkpoint row is still keyed by the existing schema until B2 binds the
admitted source identity and canonical manifest durably" — now it does).
Amends AGENTS.md Critical Rule 6 phrasing; the Rule-6 mechanism is preserved
and strengthened, not weakened.

## Context

A slot-only checkpoint keying cannot prove the durable watermark and the live
stream share one LSN space. A repointed connection, a restored backup, or a
same-slot-name start against a different source can leave a stale watermark
that is numerically at or above the new source's stream position — every
delivered transaction then satisfies `commit_lsn <= checkpoint` and is
silently skipped while the pipeline reports healthy: whole-stream loss with a
green dashboard. Within one `system_identifier` the same class appears as
WAL-history divergence: PITR and `pg_rewind` preserve the system identifier,
and an unplanned failover to a lagging standby (slot synced via PG17+
`FAILOVER`) promotes at a fork point below the acked watermark — the new
timeline re-uses the forked LSN range, and Replicant's transport-level
re-stream (correct, zero-loss at the slot level) delivers new-timeline
transactions the stale watermark then skips.

The shipped admission path also had no row lock (an unlocked read plus a blind
overwrite upsert), no manifest of the mapping contract in force at a
watermark, no timeline record, and a snapshot handoff that could regress the
watermark.

## Decision

- The durable checkpoint is ONE row per
  `(source_system_id, source_database, slot_name)` — the composite primary
  key — bound inside `handle_session_identity/2` on EVERY connect/reconnect,
  before any checkpoint read. Identity comes only from the actual replication
  session's `IDENTIFY_SYSTEM` result (`Replicant.SessionIdentity`); identity
  from a separate connection is rejected as TOCTOU. The session timeline is
  recorded beside the triple (`source_timeline`, not part of the key).
- The row carries the canonical value-free publication/resolver contract
  manifest (relations, columns incl. cloak targets, the DECLARED skip set,
  target types, tenant sources, publication set) as a deterministic term with
  a sha256 fingerprint. Transitions classify under the checkpoint lock by a
  set-monotone rule: NEW entries (a relation, a brand-new column, an ignore)
  advance — the manifest/digest are replaced atomically without touching the
  watermark; any mutation or removal of a RECORDED entry (a re-target, a type
  change, a tenant-source change, reversing a recorded skip, a publication or
  version change) halts `:publication_contract_incompatible` for an explicit
  operator migration/reset decision.
- Every frontier writer (streaming transaction, v1 snapshot handoff, and the
  future message/batch/incremental frontiers) admits through one locked
  monotonic discipline: the bound row is read `FOR UPDATE` as the first
  write-capable statement of the destination transaction; `lsn <= commit_lsn`
  skips (lower/equal never regress or reapply); the advance happens under the
  lock. Concurrent callers therefore produce one effect, including
  cross-node — the activation lease is node-scoped, the row lock is the
  durable serializer. An ABSENT row at admission is a permanent
  `:checkpoint_unbound` halt (Replicant coerces sink errors to a supervisor
  halt with no restart); an operator/host restart re-runs the identity gate
  and re-binds.
- Binding halts fail-closed with value-free structural reasons and one
  telemetry event (`[:ash_replicant, :checkpoint, :conflict]`): a foreign
  triple under the same slot (`:source_identity_rebound` — the shipped unique
  slot-name index is the cross-node race backstop), a changed timeline
  (`:source_timeline_changed`), a watermark beyond the session's WAL flush
  position (`:source_behind_watermark`), an incompatible contract.
- Legacy slot-only rows admit NO automatic migration evidence (they record
  only `{slot_name, commit_lsn}` — no machine-derivable source): the
  structural migration refuses surviving rows by construction (NOT NULL
  identity columns abort `ecto.migrate`), a count-only refusal guard makes
  the blockage actionable, and adoption is an explicit offline operator act
  (`AshReplicant.adopt_checkpoint/3`) anchored to the operator-declared actual
  identity, idempotent, conflict-refusing. A timeline-change halt resolves
  through the operator's continuity assertion
  (`AshReplicant.acknowledge_checkpoint_timeline/3` — correct for a
  same-primary crash restart whose new timeline replays the old WAL) or a
  reset (`AshReplicant.reset_checkpoint/2` — divergence; on an SCD2 mirror a
  reset pairs with a full re-snapshot, never bare re-delivery).
- Effect-once restated: one admitted destination graph, one transaction per
  delivered unit, one source-bound locked watermark. AGENTS Critical Rule 6's
  skip sentence now names the source-bound row, the lock, and monotonicity;
  the v1-snapshot repeat disclaimer and the absent-callbacks enumeration
  survive verbatim.

## Consequences

- Source moves, same-slot foreign sources, rewound/restored sources, and
  timeline forks halt for an operator decision instead of silently skipping
  WAL; a same-primary crash restart costs one explicit timeline acknowledge
  (the accepted fail-closed cost).
- Reconnects cost one locked read; an unchanged contract and timeline write
  nothing.
- B3 verifies the stored manifest against the live source catalog and extends
  the recorded ignore set; C5 reuses the same classifier and stored manifest
  for runtime schema-change classification; C1–C3 compose their frontiers on
  the same row. C3 retains the exact `snapshot_progress` token and replaces the
  reserved `snapshot_generation` placeholder with ADR-0017's versioned
  `snapshot_state` envelope. D1 templates the capture/delete/migrate/adopt runbook into
  generated upgrade paths; D4/D6 own live fault-injection and the PG15–18
  standby/failover matrix cells.

## Evidence

- `AshReplicant.Checkpoint` (generated resource: composite triple PK,
  `source_timeline`, contract/fingerprint columns, `:source_slot` identity,
  `:operator_reset` destroy, kept unique slot index).
- `AshReplicant.Checkpoint.Identity` (canonical contract, deterministic
  encoding, sha256 fingerprint, set-monotone classifier, legacy guard).
- `AshReplicant.Sink.Impl` (bind sequence at the identity gate; locked
  monotonic admission; monotonic snapshot handoff).
- `AshReplicant` (`adopt_checkpoint/3`, `reset_checkpoint/2`,
  `acknowledge_checkpoint_timeline/3`; generation-threaded contract).
- `test/integration/checkpoint_binding_test.exs` (the acceptance marquees),
  `test/ash_replicant/checkpoint_identity_test.exs` (classifier matrix).
- Executed probes on the live substrate: `FOR UPDATE` serialization blocks a
  second transaction until the holder's COMMIT; `ADD COLUMN … NOT NULL`
  aborts on legacy rows.
