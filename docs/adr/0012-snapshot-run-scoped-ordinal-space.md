# 12. Snapshot run-scoped ordinal space: one continuing ordinal axis per snapshot run

Date: 2026-08-17

## Status

Accepted. Shipped with the v1 snapshot operation-key fix (2026-08-14) and
proven live by the two-table same-participant snapshot marquee; this record
governs the axis ADR-0010's per-invocation keys depend on (B6 / C3).

## Context

ADR-0010 mints AshOnetime operation keys as the exact versioned
source-system/database/slot/commit-LSN/**ordinal**/participant identity plus
the sink-minted per-invocation label. Everything in that key is
globally unique EXCEPT the ordinal: the ordinal must distinguish every
effect site of one streaming transaction or snapshot run, and nothing else
in the key will do it for snapshots.

A v1 snapshot exports ONE consistent point (`commit_lsn`) and then delivers
its tables as separate batches — but two mapped resources can lawfully share
a participant atom and claims prefix. Under a per-TABLE ordinal space, table
A row i and table B row i mint IDENTICAL operation keys; AshOnetime then
replays A's stored response for B, silently suppressing B's declared
auxiliary effect. This is not hypothetical: it is the collision the
two-table same-participant snapshot marquee proved live before the fix.

## Decision

1. ONE continuing ordinal space per snapshot RUN, keyed by the run's
   consistent point: the first batch of a run mints ordinal base 0 and each
   batch advances the base by its row count, so later tables in the same run
   CONTINUE the axis rather than restarting it.
2. The run space is slot-scoped runtime state (`:persistent_term` under the
   snapshot-ordinals key) and is cleared at snapshot completion (and slot
   teardown): a re-created slot exports a NEW consistent point, which resets
   the counter — a fresh run's ordinals can never collide with a completed
   run's because the LSN axis of the key differs.
3. A batch that arrives for a run whose base is absent AND is not the first
   batch is an error (`:error`), not an implicit restart — inventing a base
   would re-mint another run's ordinals.
4. Ownership: B6 (the operation-key contract this axis serves, ADR-0010) and
   C3 (snapshot provenance and progress — C3's incremental snapshots must
   either reuse this axis under their own provenance identity or mint a
   distinct, collision-free one; reusing the concept, not necessarily the
   implementation, is the default).

## Consequences

- V1 snapshot effect-once for declared auxiliary actions holds per run: no
  two effect sites of one run share an operation key.
- The physical effect-once claim stays scoped as ADR-0007/0010 state it: an
  incomplete multi-batch RESTART can still physically repeat committed batch
  effects (v1 limitation, owned by C3) — this axis prevents key COLLISION
  and silent claim replay, not re-execution after an incomplete run.
- The ordinal state is deliberately NOT durable: it lives exactly as long as
  the run it scopes. Durability would imply progress semantics C3 owns.

## Evidence

- `lib/ash_replicant/sink/impl.ex` — `snapshot_ordinal_base/3`,
  `snapshot_ordinals/1`, `put_snapshot_ordinal/3`,
  `clear_snapshot_ordinals/1` (completion + `stop_supervised` teardown).
- The two-table same-participant snapshot marquee
  (`test/integration/effect_once_discriminator_test.exs`) — the live proof
  that per-table spaces collide and the run space does not.
- ADR-0010 (the 6+label operation identity this axis completes).
