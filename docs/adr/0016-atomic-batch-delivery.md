# 16. Atomic sink-owned batch delivery: `handle_batch/1` and the forwarded `batch_delivery` option

Date: 2026-08-18

## Status

Accepted for the 1.0.0 release line (roadmap C2). Composes with
[ADR-0007](0007-source-bound-checkpoint-effect-once.md) (the locked monotonic
watermark the batch advances once, at its highest LSN),
[ADR-0006](0006-destination-transaction-boundary.md) (the batch body is one
admitted destination transaction),
[ADR-0010](0010-host-action-contract.md) (the per-change operation identity —
the batch mints the same labels, no batch-specific axis), and
[ADR-0015](0015-logical-message-effects.md) (whose residual named this
slice: the batch body must carry the transactional-message interleave).

## Context

Replicant's batch-delivery mode, read first-hand this slice
(`deps/replicant/lib/replicant/sink.ex` `handle_batch/1` row,
`assembler/batch.ex`, `assembler_server.ex`, `config.ex`):

- The top-level `batch_delivery` pipeline option (sibling of
  `:checkpoint_store`, mutually exclusive with it in Replicant; sink-owned
  mode only) routes delivery through `handle_batch/1` instead of
  `handle_transaction/1`. Replicant normalizes the shape
  (`max_transactions` default 100, `max_delay_ms` default 1000, a DERIVED
  `max_span`) and rejects a malformed value at start (`:config_invalid`).
- The config gate requires `supports_batch?/1` (`handle_batch/1` exported)
  plus `checkpoint/0`, else `:batch_unsupported` / `:invalid_sink`;
  `handle_transaction/1` is never called in this mode.
- The assembler buffers committed transactions WITHOUT a sink call, and
  flushes on the count cap, the LSN-span cap, the `max_delay_ms` timer, or a
  standalone-message boundary (the §8.4 flush-before-message rule —
  transport-owned). At flush it calls `sink.handle_batch(txns)` with `txns`
  in **ascending `commit_lsn` order** and expects `{:ok, lsn}` after a
  durable apply; the framework then acks its own `pending_lsn` (the batch's
  highest LSN — the sink's returned value is ignored).
- **HARD OBLIGATION** (the callback doc's words): persist ALL rows AND
  `checkpoint := List.last(transactions).commit_lsn` in ONE atomic database
  transaction (or, at minimum, checkpoint-after-all-persist). Effect-once
  (dup = 0) rests on it. A non-`{:ok, _}` return or a raise/throw/exit halts
  fail-closed; the batch is discarded un-acked and re-delivered on resume.
  The arity is frozen at 1 for 1.0 — no context argument.
- A buffered transaction's `changes` may be a lazy, single-pass spill-backed
  Reader (the batch owns the spill file until flush); `txn.messages` is
  always an in-memory list sharing the changes' one ascending ordinal space.

Before C2 the adapter had none of this: the generated sink exposed no
`handle_batch/1` (pinned ABSENT by the action-contract freeze table) and
`AshReplicant.start_link/1` silently withheld a caller's `batch_delivery`
option (pinned by the start-link forwarding test as "owned by Replicant but
unsupported by AshReplicant").

## Decision

1. **The generated sink implements `handle_batch/1` unconditionally.** The
   body is parameterized by exactly what `handle_transaction/2` already
   consumes (the admitted generation's config); no sink-level declaration is
   introduced. `batch_delivery` stays a PIPELINE-level tuning knob —
   Replicant's own contract makes it a top-level start option, and latency/
   durability caps are deployment concerns, not data topology. This differs
   deliberately from C1's conditional `handle_message/2`: a message routing
   surface is sink-baked topology (which prefixes exist, which resources
   they target); batch semantics need nothing beyond the admitted
   destination graph. `handle_transaction/1` remains generated for
   non-batch pipelines — the two modes share the same apply core.
2. **`:batch_delivery` is forwarded, not validated twice.** It joins
   `@replicant_option_keys` and reaches `Replicant.start_link/1`, whose
   config gate fails closed on a bad shape; the adapter adds no duplicate
   normalization (one owning layer). The adapter never passes
   `:checkpoint_store`, so Replicant's mutual exclusion cannot trip here.
3. **The batch body is one admitted transaction with a single trailing
   watermark write.** `Impl.handle_batch/2` (the EIGHTH value-free boundary
   body — `rescue` AND `catch :throw`/`:exit` into the same scrub as
   `handle_transaction`, firing the sink's own `:halted`): guard
   generation → `locked_checkpoint!` → whole-batch skip when the batch's
   highest LSN is at/below the watermark (no write, one skip event) → else
   iterate the transactions ascending, skipping any individual
   `commit_lsn <= checkpoint` (the callback doc's belt-and-suspenders; the
   framework's Commit-time pre-skip already dropped most) and applying each
   survivor through the SAME single-pass `apply_all` core that
   `handle_transaction` uses — so the transactional-message ordinal
   interleave (ADR-0015) carries through unchanged — then
   `upsert_checkpoint(config, List.last(txns).commit_lsn)` AFTER all
   effects, then final guards. The checkpoint write happens only when the
   highest LSN exceeds the locked watermark, preserving ADR-0007's
   monotonicity; ascending order makes the applied set a suffix, so a
   mid-list skip never strands an unapplied higher transaction.
4. **Spilled streams stay single-pass.** Each transaction's `changes` is
   enumerated exactly once (counting during the pass, as `apply_all`
   already does); the body never calls `length`/`Enum.count`/`Enum.reverse`
   on a transaction's changes, and never materializes the batch itself
   beyond the list the framework hands it (which is already materialized —
   only the changes inside each transaction are lazy). `txn.messages` is
   iterated freely (in-memory by contract).
5. **Telemetry counts one pass.** A flush emits ONE
   `[:ash_replicant, :sink, :batch_applied]` event — measurements
   `change_count` + `duration`, metadata `commit_lsn` (the batch's highest)
   and `txn_count` (a new typed, value-free metadata key) — never one event
   per transaction. The whole-batch skip reuses
   `[:ash_replicant, :sink, :skipped]` with the batch's highest LSN. The
   per-transaction `[:ash_replicant, :sink, :applied]` event does not fire
   in batch mode: delivery IS the flush.
6. **Effect-once argument.** The data + checkpoint write is atomic, so a
   mid-batch halt/crash/teardown leaves zero partial effects and zero
   checkpoint advance; Replicant discards the un-acked batch and re-streams
   from the durable checkpoint; the re-delivered batch skips every
   transaction at/below the watermark and upserts the survivors by PK —
   zero net duplicate, the same reasoning as `handle_transaction` at batch
   granularity, and strictly stronger than Replicant's lib-mode batched
   checkpointing (dup ≤ `max_transactions` there, dup = 0 here).

A defensive `handle_batch(config, [])` returns `{:ok, nil}` — the framework
never flushes an empty batch (`pending_lsn: nil` short-circuits to
`:empty`); the clause exists so the frozen-arity callback cannot crash on a
future caller's shape.

## Consequences

- The action-contract freeze table's batch row flips ABSENT → PRESENT
  (always, not when-configured); `snapshot_progress/0` and `:append` stay
  absent until C3/C4. The start-link forwarding test's withheld-option pin
  inverts: `batch_delivery: :invalid` now fails closed
  `{:error, :config_invalid}` instead of starting.
- AGENTS Rule 4's boundary count moves seven → eight; Rule 6's "sink-owned
  batch … callbacks remain absent until C1–C4" clause retires (the v1
  snapshot restart-repeat caveat remains C3's).
- ADR-0015's batch-composition residual closes: the interleave rides the
  batch body, and the §8.4 flush-before-message boundary stays
  transport-owned (the standalone message is never a member of the batch).
- The destination manifest, operation-key identity, tenancy, SCD2, and
  AshOnetime participation of C1 all apply unchanged — the batch is an
  envelope, not a new effect class; no participant or label widens.
- Larger single transactions: a batch applies up to `max_transactions`
  transactions under one destination lock hold with the same
  `@snapshot_transaction_timeout` ceiling as the snapshot path; sizing
   guidance (batch caps vs lock duration) is D5's measured-bounds work.
