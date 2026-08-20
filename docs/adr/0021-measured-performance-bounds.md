# 21. Performance bounds are release correctness constraints

Date: 2026-08-19

## Status

Status: Proposed for the 1.0.0 release line (roadmap D5).

## Context

Batch, message claims, SCD2, incremental snapshots, append delivery, continuous
census, and destination graph checks add different lock, memory, query, and WAL
retention costs. Fixed unmeasured timeouts or throughput claims can turn a safe
path into a production halt, while relaxing them without bounds can hide memory,
pool, or lag failure.

## Decision

1. The release publishes reproducible throughput, latency, memory, database
   round-trip, lock-hold, WAL-retention, and census-cost baselines for every
   delivery mode on named hardware/runtime/data fixtures.
2. Spilled transaction and snapshot streams remain single-pass. Batch tuning may
   amortize commits but cannot weaken transaction order, checkpoint atomicity, or
   bounded memory.
3. Timeouts, pool guidance, batch/chunk defaults, census cadence, recovery
   horizon, and alert thresholds are derived from measured distributions with a
   documented safety factor. A timeout in a correctness-critical check fails
   closed.
4. Stable CI sentinels gate regressions with noise-tolerant statistical bounds;
   full benchmark publication runs on the exact release candidate. A green
   correctness suite cannot waive a budget regression.

## Consequences

- Concrete numeric budgets are evidence artifacts and may evolve; changing the
  protected invariants requires an ADR amendment.
- Hyperscale claims remain absent until measured fixtures support them.

## Required proof before acceptance

- Reproducible benchmark harness, baseline receipts, negative single-pass and
  unbounded-cardinality mutations, load-sensitive timeout tests, and exact-RC
  regression reports.
