# 6. Destination transaction boundary

Date: 2026-08-14

## Status

Accepted for the 1.0.0 release line.

## Context

AshReplicant acknowledges WAL only after the destination work succeeds. A mapped
row, a host action reached from that row, an auxiliary action, an AshOnetime claim,
or the checkpoint can still escape rollback if it uses another Repo or opens an
independent transaction. A primary-key upsert can hide that escape because replay
converges to the same final row while the physical effect happened twice.

Ash can describe framework-owned changes, validations, preparations,
relationships, and manual actions, but it cannot prove the body of arbitrary
Elixir code. AshPostgres also permits a dynamic Repo identity, so comparing only
the configured Repo module is insufficient. AshOnetime's nonce strategy rejects
reuse and is therefore incompatible with normal WAL replay; a commit LSN alone is
also not unique when one transaction contains several effects.

## Decision

- Sink compilation and activation build one deterministic destination manifest.
  Its roots are the checkpoint action and every mapped resource's selected read,
  create, destroy, and SCD2 close actions. Reflection recursively follows
  framework-managed relationships and every declared custom participant. Cycles,
  missing actions, opaque callbacks, and a mismatch between discovered resources
  and an action's `touches_resources` declaration fail admission.
- Every resource in that closure must use `AshPostgres.DataLayer`, declare the
  sink's literal Repo, and resolve to that Repo's admitted effective dynamic Repo.
  The raw and effective Repo checks reject callable, foreign, non-Postgres, and
  split read/write targets before delivery. The admitted dynamic Repo is pinned in
  the process and passed through Ash data-layer context for every action.
- `AshReplicant.DestinationParticipant` is the only public declaration mechanism
  for arbitrary custom code. A provider returns `:no_database` or literal Ash
  resource/action references. A declaration cannot authorize raw SQL, a different
  Repo, asynchronous work, or an external effect. This is a trust boundary: the
  manifest verifies the declaration and its closure, but cannot prove that an
  arbitrary function body told the truth.
- Start, stop, and mutating callbacks share the per-slot destination lease. One
  immutable admitted generation holds the sink config, manifest, code/config
  fingerprints, source-session expectation, publication, dynamic Repo identity,
  and generation reference. A mutating callback holds the lease through database
  commit or rollback and rechecks the generation around each participant and the
  checkpoint. Supported replacement is stop, then start and re-admit; in-place
  code/config drift fails closed.
- Generated Replicant callbacks invoke the admitted `Sink.Impl` operations
  directly and are final. There is no host-overridable effect hook that can
  acknowledge delivery without the mapped actions and checkpoint.
- Mapped writes continue through host Ash actions with `authorize?: false` and
  their nested transaction disabled so they join the sink's ambient transaction.
  Host validations, changes, AshCloak hooks, and tenancy run; host policies are not
  re-gated. Existing sink-owned truncate SQL remains its narrow, quoted,
  in-transaction trust boundary and is not extensible through participant metadata.
- The permanent checkpoint remains the WAL replay/resume authority. A local
  auxiliary action may additionally use AshOnetime only when admission proves
  `:idempotency` with `:with_action`, fail-closed PostgreSQL storage in the same
  destination Repo, no external effect, a private non-null `operation_key`, the
  exact versioned participant scope and supported response handling. The replay
  identity is exactly source system identifier, source database, slot name,
  commit LSN, ordinal, and participant. `operation_key/2` derives the key supplied
  to the protected action. Nonce, independent-commit, external, opaque-store, and
  incomplete identity profiles are rejected.
- Action and preparation `SetContext` declarations may not replace `:data_layer`;
  admission rejects table/schema/Repo redirection. AshOnetime must use
  `AshOnetime.Cache.None`; a behavior-conforming external cache is still an
  out-of-transaction effect and is rejected.
- Static AshOnetime relations are checked at activation. Context-tenant relations
  are checked inside the destination transaction under the resolved tenant before
  the protected action. Claims, auxiliary effects, stored responses, mapped rows,
  and checkpoint therefore commit or roll back together.
- Append-only effect observers, callback sequencing, and fault switches are
  compiled from test configuration only. No
  production `apply_ledger` API or table participates in the guarantee.
- The currently exported delivery callbacks cover streaming transactions and
  Replicant v1 snapshot batches/handoff. Message actions, sink-owned transaction
  batches, incremental snapshot progress, and append-log delivery remain absent
  until roadmap C1 through C4 compose their own participants with this boundary.

## Consequences

- Cross-Repo and non-Postgres action graphs fail before a destination effect or
  checkpoint write. A fault after an admitted effect rolls the whole destination
  transaction back, including AshOnetime state.
- Distinct same-transaction effects do not collide because ordinal and participant
  are part of the replay identity. Normal replay returns the stored idempotent
  result instead of rejecting a reused nonce.
- The guarantee covers declared and framework-discoverable database effects. A
  dishonest arbitrary provider remains outside what Elixir reflection can prove;
  hosts must not conceal raw SQL, external calls, asynchronous work, or foreign
  Repo use behind a declaration.
- A Replicant v1 snapshot batch is atomic, but an incomplete multi-batch snapshot
  restart can physically repeat already committed batch effects before the target
  is cleared and rebuilt. Roadmap C3 must prove zero physical repeats for both v1
  and incremental restart before the stable release claim can include snapshots.
- The checkpoint row is still keyed by the existing schema until B2 binds the
  admitted source identity and canonical manifest durably. B5, B6, and C1 through
  C4 retain their classified-data, host-action, message, batch, snapshot, and
  append-specific obligations.

## Evidence

- `AshReplicant.Destination` builds the recursive manifest, validates Repo and
  participant closure, admits the WAL-safe AshOnetime profile, and preflights its
  PostgreSQL relations.
- `AshReplicant.run_callback/4` pins the admitted generation and holds the per-slot
  lease; `AshReplicant.Sink.Impl` owns the outer transaction and checkpoint.
- Destination, effect-once, SCD2, and snapshot tests use append-only observers plus
  cross-Repo and rollback mutations to distinguish logical convergence from
  physical effect-once behavior.
