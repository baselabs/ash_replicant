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
   physical attempt, progress, target provenance, restart classification, and
   completion ordering. Snapshot state is not split across independently
   callable progress/provenance services.
2. The source-bound checkpoint row remains the serialization authority. Its
   `snapshot_generation` is an opaque logical backfill generation that survives
   incomplete retries and changes only after durable completion or explicit
   reset. `snapshot_progress` is an opaque confidential token persisted in the
   same destination transaction as its chunk and never rendered.
3. Every snapshot-capable state mirror declares four non-sensitive writable
   provenance attributes: a closed origin (`snapshot | stream`), logical
   generation, host-keyed canonical row fingerprint, and physical attempt
   marker. The fingerprint is a versioned HMAC over the canonical mapped source
   record using host-managed `:ash_replicant, :snapshot_provenance_keys`; no row
   value or guessable bare digest is stored or emitted.
4. The host declares private tenant-scoped mark-seen and retire-unseen actions.
   On retry, an admitted read compares provenance: an unchanged snapshot row
   runs only mark-seen; a new or changed row runs the ordinary host business
   action; a stream-origin row wins and is never reset by snapshot cleanup.
   Completion retires only snapshot-origin rows in the logical generation that
   were not seen in the completing physical attempt. SCD2 records provenance
   per version and retires through the host close action.
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
- Key rotation retains old provenance keys until every generation and supported
  recovery horizon that used them has completed or been explicitly abandoned.
- Progress/provenance writes are expected internal effects and receive their own
  telemetry; they are never disguised as zero physical writes.

## Required proof before acceptance

- Red-before-green v1 and incremental crash/retry marquees for SCD1, SCD2,
  tenancy, empty/keyed/PK-less tables, stream collision, batch/backpressure, key
  rotation, stale attempt cleanup, and a fingerprint/attempt bypass mutation.
- Append-only observers on host business actions prove no repeated effect while
  provenance/checkpoint rows demonstrate durable progress.
