# Measured performance baselines (ADR-0021 / B01)

Reproducible receipts from `test/integration/performance_bounds_test.exs`
(run with `ASH_REPLICANT_BENCH_RECEIPT=<path>` against a live substrate).
The sentinel floors in that module sit at ~1/4 of these numbers — they
catch class regressions (lost single-pass, O(n²), unbounded
materialization, lost batch amortization), never percent drift.
Changing a protected bound is an ADR amendment, not a test tweak.

Dominant cost finding (all modes): the per-change generation-guard
re-validation — the `run_transaction` timeout note's "guard overhead
alone" class. Batch amortization is real and visible (throughput up ~40%,
statement count down ~25% at equal rows vs per-transaction).

- 2026-08-24 · Apple-silicon laptop (M-series), throwaway `postgres:16`
  container (digest-pinned CI image), 10-row source transactions:
  - streaming/per-transaction: rows=1000 wall_ms=17034 rows_per_s=59 statements=2221 beam_mb=96
  - streaming/batch-20:       rows=1000 wall_ms=11934 rows_per_s=84 statements=1657 beam_mb=97
  - scd2/versioned:           rows=1000 wall_ms=13890 rows_per_s=72 statements=3492 beam_mb=98
  - append/log:               rows=1000 wall_ms=14944 rows_per_s=67 statements=1446 beam_mb=96
