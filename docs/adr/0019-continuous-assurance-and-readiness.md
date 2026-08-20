# 19. Continuous assurance and readiness reuse the pipeline owner

Date: 2026-08-19

## Status

Status: Proposed for the 1.0.0 release line (roadmap C5 and D2-D4).

## Context

ADR-0008 validates source coverage at activation, reconnect, and first affected
delivery. DDL or destination drift on an otherwise quiet table remains invisible
between reconnects. Owner liveness also cannot distinguish healthy,
catching-up, halted, misconfigured, and never-started after a pipeline exits.
A second health process would create competing lifecycle authority.

## Decision

1. The existing temporary `PipelineOwner` schedules a jittered, bounded source
   and destination invariant census. No additional long-running process is
   introduced.
2. The census reuses `Coverage`, checkpoint manifest classification, and
   `Destination` admission. It checks source identity/publication/types/RIF,
   target resources/actions/tables/indexes/provenance/SCD2 uniqueness,
   AshOnetime storage and recovery horizon, migrations, and configuration.
3. Compatible additive transitions are classified and persisted only under the
   checkpoint lock. Incompatible or unreadable state halts the pipeline, records
   a bounded value-free lifecycle tombstone, and freezes checkpoint advance.
4. `preflight/1` and `mix ash_replicant.doctor` are read-only views over the same
   classifiers. Stable check/report structs serve machine and operator output;
   no separate diagnostic interpretation is allowed.
5. `status/1` combines live owner/generation, the latest successful census,
   durable checkpoint/manifest/snapshot state, lifecycle tombstone, and observed
   frontier. Its closed states are `:not_started`, `:catching_up`, `:healthy`,
   `{:halted, reason}`, and `{:misconfigured, reason}`. Healthy requires all
   authoritative facts to agree.
6. Telemetry emits typed low-cardinality transitions and measurements but is
   never the readiness authority. OpenTelemetry remains an optional adapter.

## Consequences

- Quiet source/destination drift becomes a bounded halt instead of waiting for a
  reconnect or affected row.
- A dead owner can never report healthy, and node restart recomputes facts before
  readiness.
- Poll intervals, query budgets, lag/frontier thresholds, and alert defaults are
  set from D5 measurements; a timeout fails closed rather than silently skipping
  the census.

## Required proof before acceptance

- Live between-reconnect DDL/index/RIF/migration mutations, permission and timeout
  faults, stale tombstone/owner death/node restart, subscriber failure, and a
  tamper proving each new check can go red.
