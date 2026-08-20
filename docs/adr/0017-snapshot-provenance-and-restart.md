# 17. Snapshot provenance and restart form one atomic protocol

Date: 2026-08-19

## Status

Status: Proposed for the 1.0.0 release line (roadmap C3).

## Context

The checkpoint already reserves `snapshot_progress` and
`snapshot_generation`, but the current v1 snapshot commits batches without
durable per-row provenance. A failed v1 attempt may export a new PostgreSQL
snapshot on retry. Origin and generation alone cannot distinguish an unchanged
row already applied by the failed attempt from a row whose source content
changed, nor can they identify a source row absent from the completing attempt.
Re-running the host create/close/destroy actions would physically repeat their
business effects even if the final target state converged.

Incremental snapshots additionally require the opaque Replicant progress token
to commit atomically with each chunk, while live stream writes may overtake a
backfill row and must always win the collision.

## Decision

1. One internal `AshReplicant.Snapshot` module owns logical generation,
   membership attempt, progress, target provenance, restart classification, and
   completion ordering. Snapshot state is not split across independently
   callable progress/provenance services.
2. The source-bound checkpoint row remains the serialization authority. Its
   `snapshot_generation` is an opaque logical backfill generation that survives
   incomplete retries and changes only after durable completion or explicit
   reset. `snapshot_progress` is an opaque confidential token persisted in the
   same destination transaction as its chunk and never rendered. For an
   incremental backfill, activation installs the checkpoint-bound logical
   generation before Replicant transport starts and derives one stable attempt
   marker from it; reconnect and owner restart resume that marker because the
   durable progress token skips completed rows. A new incremental generation
   derives a new marker. For a v1 whole-snapshot retry, the marker is instead
   derived from the generation and that run's `snapshot_lsn`, so the full re-read
   rotates membership without repeating unchanged host effects. The local owner
   rejects duplicate starts on one node; PostgreSQL slot exclusivity plus the
   checkpoint lock serialize cross-node transport and effects. No node-local
   random marker becomes durable authority.
3. Every snapshot-capable state mirror declares four non-sensitive writable
   provenance attributes: a closed origin (`snapshot | stream`), logical
   generation, host-keyed canonical row fingerprint, and membership attempt
   marker. The fingerprint is a versioned HMAC over the canonical mapped source
   record using host-managed `:ash_replicant, :snapshot_provenance_keys`; no row
   value or guessable bare digest is stored or emitted.
4. The host declares private tenant-scoped mark-seen and retire-unseen actions.
   The attempt marker records membership in the current pass, not
   permanent ownership by snapshot or stream. An unchanged snapshot row runs
   only mark-seen; a new or changed row runs the ordinary host business action.
   The current whole-resource `first_for_table?` clear is removed for
   snapshot-managed resources; the callback flag starts membership processing
   and never authorizes a blanket delete. Every stream write admitted while an
   incremental attempt is live stamps that attempt's marker, including a write
   delivered before the first snapshot chunk. The accepted Replicant artifact
   opens collision tracking before each chunk's low watermark, takes a
   current-state chunk read, waits for the high-watermark frontier, drops keyed
   rows touched by a later stream insert, update, delete, or key change, and
   discards and re-reads a table when filtering is unsafe or its keyed drop-set
   exceeds the memory bound. A write delivered before the window is reflected by
   the subsequent current-state read. Contention retries are bounded; the
   accepted 1.2.0 build halts `:snapshot_table_contended` after three failed
   table attempts. A01 and S03 bind this behavior to the fetched artifact with a
   black-box collision suite; module/function presence is not proof, and a
   resolved build that fails the behavior gate is unsupported. Consequently a
   stream write wins and a stream delete cannot be resurrected by a stale chunk.

   Completion first enumerates every extant destination tenant scope, including
   a scope absent from the source attempt. For attribute multitenancy this is a
   read-only `DISTINCT` of the verifier-approved plaintext, non-sensitive tenant
   discriminator through the admitted Repo, inside the checkpoint transaction,
   with identifiers supplied by the DSL and the one quoting home. Context
   multitenancy requires an admitted host tenant-enumeration read action whose
   contract covers retained destination scopes; absence fails preflight. Tenant
   values remain data-plane values and are never rendered. AshReplicant then
   invokes the private retire-unseen action separately with each tenant; no
   unscoped write is allowed. Global resources run the action once. The action
   retires every row in that declared resource/scope lacking the completing
   marker, regardless of prior origin or generation, including a stale
   stream-origin row deleted while delivery was offline. Rows outside the
   declared managed resource/scope are untouched. SCD2 records provenance per
   version, applies unseen retirement only to open versions, and retires through
   the host close action; closed history remains immutable.
5. The normal create/destroy/SCD2-close actions, private provenance actions,
   checkpoint/progress writes, and every declared participant remain in the one
   admitted Repo/action graph. Internal provenance bookkeeping is reported
   separately from the zero-repeat claim, which covers host business effects.
6. Incremental chunks commit row effects, provenance, and progress atomically.
   V1 retries use the fingerprint/attempt protocol because Replicant supplies no
   v1 progress token. Nondeterministic, PK-less, missing-action, sensitive
   provenance, key-rotation-within-horizon, or cross-Repo shapes fail preflight.

## Consequences

- V1 and incremental retries can prove zero repeated host business effects with
  an append-only observer; final-state convergence alone is insufficient.
- Hosts enabling snapshots add four provenance attributes and two private
  actions to each mapped state resource. Install/upgrade tooling generates the
  shape and a manual path documents it.
- Attribute-multitenant retirement performs one privileged read-only discriminator
  enumeration followed only by tenant-scoped Ash actions. Context-multitenant
  snapshots additionally declare an admitted authoritative scope enumeration.
- Key rotation retains old provenance keys until every generation and supported
  recovery horizon that used them has completed or been explicitly abandoned.
- Progress/provenance writes are expected internal effects and receive their own
  telemetry; they are never disguised as zero physical writes.

## Required proof before acceptance

- Red-before-green v1 and incremental crash/retry marquees for SCD1, SCD2,
  tenancy, empty/keyed/PK-less tables, an insert/update/delete or key change
  delivered before the first chunk and during an open window,
  batch/backpressure, key rotation, incremental owner restart after completed
  tables and a partial current table, stale attempt cleanup, removal of the
  whole-resource clear, an entirely absent tenant, a stale stream-origin row
  deleted while delivery was offline, preservation of closed SCD2 history,
  contention exhaustion, and
  fingerprint/attempt/tenant-enumeration and fetched-transport collision-gate
  bypass mutations.
- Append-only observers on host business actions prove no repeated effect while
  provenance/checkpoint rows demonstrate durable progress.
