# 19. Continuous assurance and readiness reuse the pipeline owner

Date: 2026-08-19

## Status

Status: Partially accepted for the 1.0.0 release line. C01's continuous census
is implemented; the doctor, status/readiness, tombstone, and remaining
destination/migration checks stay owned by their later roadmap children.

## Context

ADR-0008 validates source coverage at activation, reconnect, and first affected
delivery. DDL or destination drift on an otherwise quiet table remains invisible
between reconnects. Owner liveness also cannot distinguish healthy,
catching-up, halted, misconfigured, and never-started after a pipeline exits.
A second health process would create competing lifecycle authority.

## Decision

1. The existing temporary `PipelineOwner` schedules a jittered, bounded source
   and destination invariant census. No additional long-running process is
   introduced. Each run is one unlinked monitored worker entering through the
   existing admitted callback guard; the next one-shot schedule is armed only
   after that run settles, so work cannot overlap.
2. C01 reuses `Coverage`, checkpoint manifest classification, and `Destination`
   admission. It continuously checks the admitted destination generation, the
   live source contract, the durable source-bound checkpoint plus authenticated
   contract, and source publication/column/type/RIF coverage. Later children
   extend the same classifier/report seam to destination indexes, provenance and
   SCD2 uniqueness, AshOnetime recovery horizon, and migrations.
3. C01 treats compatible additive checkpoint-contract growth as healthy but
   persists it only through the existing reconnect bind under the checkpoint
   lock. Incompatible or unreadable state halts the pipeline and freezes
   checkpoint advance. The durable value-free lifecycle tombstone is owned by
   the later status/tombstone child.
4. `preflight/1` and `mix ash_replicant.doctor` will be read-only views over the same
   classifiers. Stable check/report structs serve machine and operator output;
   no separate diagnostic interpretation is allowed.
5. The later `status/1` child combines live owner/generation, the latest successful census,
   durable checkpoint/manifest/snapshot state, lifecycle tombstone, and observed
   frontier. Its closed states are `:not_started`, `:catching_up`, `:healthy`,
   `{:halted, reason}`, and `{:misconfigured, reason}`. Healthy requires all
   authoritative facts to agree.
6. C01 telemetry emits typed low-cardinality transitions and measurements but is
   never the readiness authority. OpenTelemetry remains an optional adapter.
7. Drift halts immediately. A timeout, unreachable substrate, or checker fault
   is a typed non-pass and advances a consecutive-fault counter; a healthy run
   resets it, and the exact configured limit halts `:census_unverifiable`.

## Consequences

- Quiet source/destination drift becomes a bounded halt instead of waiting for a
  reconnect or affected row.
- The later status surface can never report a dead owner as healthy, and node
  restart will recompute facts before readiness.
- Poll intervals, query budgets, lag/frontier thresholds, and alert defaults are
  set from D5 measurements; a timeout fails closed rather than silently skipping
  the census.

## Required proof

- C01: live between-reconnect publication drift, destination/contract/checkpoint/
  coverage mutations, permission/unreachable/timeout faults, exact fault-budget
  halt, owner/worker teardown, typed value-free telemetry, and a tamper proving
  every admitted check can go red.
- Later children retain the remaining live DDL/index/migration, tombstone,
  owner-death/node-restart, readiness, and subscriber-failure proofs.
