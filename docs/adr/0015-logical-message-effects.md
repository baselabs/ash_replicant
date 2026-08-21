# 15. Logical-message effects: routing, claims, and the content digest

Date: 2026-08-18

## Status

Accepted for the 1.0.0 release line (roadmap C1). Composes with
[ADR-0007](0007-source-bound-checkpoint-effect-once.md) (the watermark the
message paths advance), [ADR-0009](0009-classified-boundaries.md) (the
message-claim confidentiality boundary this record now lands), and
[ADR-0010](0010-host-action-contract.md) (the 6+label operation identity the
message key mints `:message` into).

## Context

Replicant delivers `pg_logical_emit_message` output in two shapes with two
different guarantees (read first-hand in `deps/replicant/lib/replicant/sink.ex`
and `assembler.ex` this slice):

1. **Transactional** (`transactional => true`) — rides
   `%Transaction.messages` with an `ordinal` from the transaction's ONE
   ascending numbering space (shared with its changes), delivers inside
   `handle_transaction/1`, and inherits the transaction path's effect-once:
   rollback rolls the effect back with everything else; the committed
   watermark dedups re-delivery. The framework emits
   `[:replicant, :message, :received]` with `transactional: true`.
2. **Non-transactional** (`transactional => false`) — arrives STANDALONE via
   `handle_message/2` (gated by the top-level `messages: true` start option,
   `:messages_unsupported` when the callback is absent) with NO commit
   bracket and NO framework dedup key. The framework acks the message's LSN
   after `:ok`; a crash between effect and ack re-delivers it. This is an
   at-least-once downgrade the SINK must dedup — the exact hole C1 closes.

Both kinds are off for a pipeline started without `messages: true` (the
pgoutput `messages` option gates the wire itself), so a sink with no message
routes never sees a message.

Before C1 the adapter had no message path at all: `handle_transaction/1`
iterated `changes` only, the generated sink exposed no `handle_message/2`
(pinned ABSENT by the freeze table), and nothing routed a prefix anywhere.

## Decision

### Routing (sink-owned, prefix → create action)

Message routes are declared at the sink use-site — the same trust boundary as
`ignored_sources` — because a logical message is not table-shaped and has no
mirror-resource semantics:

      use AshReplicant.Sink,
        repo: MyApp.Repo,
        domains: [MyApp.Shop],
        checkpoint_resource: MyApp.ReplicantCheckpoint,
        slot_name: "shop_orders",
        message_routes: [{"mail", MyApp.MailOutbox, :record}],
        ignored_message_prefixes: ["telemetry_noise"]

- Compile-time validation: route prefixes are non-empty unique binaries,
  never both routed and ignored; ignores are non-empty unique binaries. The
  routed action is a `:create` action (the mirror's own effect vocabulary —
  update/destroy/generic-action routes are a future widening, not a silent
  gap; the admission check names the mismatch).
- The routed resource enters the destination manifest as a `:message`-role
  ROOT with the same repo/data-layer/identifier/notifier/`touches_resources`/
  participant admission as every other root. It needs no
  `AshReplicant.Resource` extension (nothing about it is table-mapped).
- Unknown prefix at delivery **halts** fail-closed
  (`:message_prefix_unmapped`). An explicitly ignored prefix is acknowledged
  (watermark advanced) with no effect.
- `handle_message/2` is generated ONLY on sinks that declare routes or
  ignores; `AshReplicant.start_link/1` then passes `messages: true` to
  Replicant automatically (an explicit `messages: false` from the caller
  still wins). A route-less sink keeps the frozen ABSENT posture.

### The claim (every routed action is protected, exactly one profile)

Every message-route action MUST carry an `AshOnetime` protection — the claim
is the only dedup the standalone kind gets, and uniformity is what makes
digest mismatch, replay, and retention testable. The admission-validated
profile:

- `strategy :idempotency`, `on_definite_store_failure :fail_closed` — a
  nonce is single-use by construction and MUST NOT gate WAL re-delivery
  (the C1 acceptance line; a spent nonce would turn every legitimate
  redelivery into a halt).
- `key [{:argument, :operation_key}]`; scope is the closed static pair
  `ash_replicant:message-route:1` + the resource module name.
- `fingerprint(arguments: [:content_digest])` — EXACTLY. The fingerprint is
  the replay-binding: the same identity with different content is
  `:key_reused_with_different_request`, the action body never runs, the
  pipeline halts value-free. The message `content` itself never enters the
  claim in any derived form.
- The action carries the private non-nil string arguments `operation_key` and
  `content_digest` (sink-fed via `private_arguments:`) plus an accepted
  `content` string attribute — the payload lands as an ordinary attribute
  write, exactly like a mirrored column.
- `retention` is REQUIRED (positive): retention bounds replay protection,
  so it must exceed the operator's plausible crash/restart window — an
  expired claim re-executes the effect on re-delivery by package design.
- `external_effect` MAY be declared — on message routes ONLY, never on a
  row-mirror auxiliary (that rejection is unchanged). An external route is
  the "external peer action" of the C1 acceptance: AshOnetime's three-state
  recovery (`:ok` finalize / `:absent` execute / `:unknown` recover-or-halt)
  owns the ambiguity; the sink returns `:ok` — and the framework acks —
  only after a finalized or replayed success.

### Operation identity and the versioned host-keyed digest

The message operation key is the SAME 6+label canonical identity as every
other sink effect — `[system, database, slot, LSN, ordinal, participant,
:message]` — minted by the one home (`DestinationParticipant.operation_key/2`
with `participant` = the routed resource). The axes:

- A transactional message keys on the transaction's `commit_lsn` + the
  message's own `ordinal` (the shared numbering space makes change-vs-message
  collisions impossible).
- A standalone message keys on its OWN LSN (its only identity — each
  standalone emission owns one WAL position) with ordinal `0`.

The `content_digest` argument is a VERSIONED HOST-KEYED HMAC
(`v<n>:<hex(hmac_sha256(key_vN, content))>`) over the message body, from
`Application.get_env(:ash_replicant, :message_digest_keys)` — a non-empty
list of `{positive_integer_version, binary_key ≥ 16 bytes}` with unique
versions; activation fails closed (`:config_invalid`) when routes exist
without valid keys. Keyed, not bare SHA-256, because claims are destination
rows: an unkeyed digest admits offline content guessing against the claim
store. Versioned because rotation must not orphan live claims: the ACTIVE
version (max) mints new digests, and on a fingerprint mismatch under the
active version the sink retries the retained older versions before halting
(a mismatch is an admission rejection — the body never ran — so the retry is
effect-free; all-versions mismatch is the genuine corruption/restore case
and halts). Dropping a version while a claim minted under it is still inside
its retention/recovery window is the rejected hard cut (ADR-0009).

### Atomicity: where the watermark moves

- **Database-local route, standalone message:** ONE destination transaction —
  claim + action effect + monotonic watermark upsert to the message's LSN.
  Crash before commit: everything rolls back, the un-acked WAL re-delivers.
  Crash after commit but before the framework ack: re-delivery replays the
  claim (`:ok`, no effect) and re-advances an already-advanced watermark.
- **External route, standalone message:** no wrapping destination
  transaction (AshOnetime commits the claim independently and finalizes
  separately); the watermark advances in its own locked monotonic
  transaction ONLY after finalized/replayed success. A crash between
  finalize and watermark leaves a claim that replays on re-delivery.
- **Ignored prefix:** watermark advances, nothing else.
- **Transactional message:** rides `handle_transaction/1`'s existing
  transaction and its checkpoint upsert; no separate watermark write. An
  external route inside a transactional message relies on the independent
  claim commit: a post-finalize transaction rollback discards the stored
  response but not the peer effect nor the claim, and re-delivery runs the
  recover path — at-least-once to the peer, never silent loss.

### Delivery order and the seventh boundary body

`handle_transaction/1` interleaves `txn.messages` with `txn.changes` by
ordinal — a single lazy pass over `changes` (a spilled transaction's stream
must not be materialized) flushing the in-memory message list ahead of each
change with a higher ordinal, then the tail. Each message routes through the
same `AshReplicant.Messages.apply/3` seam with its own guards.

`handle_message/2` is the SEVENTH sink boundary body: rescue AND catch
`:throw`/`:exit` into the same value-free scrub as the other six, firing the
sink's own `[:ash_replicant, :sink, :halted]` with the structural reason.
New telemetry: `[:ash_replicant, :message, :applied]` with the
`byte_size` measurement ADR-0009 reserved for exactly this, metadata
`commit_lsn`/`resource`/`transactional` — never prefix or content.

## Consequences

- A standalone message no longer degrades to at-least-once effects: claim
  replay bounds re-delivery to zero net effect for local routes and to
  finalized/recovered outcomes for external peers.
- Digest rotation is an online operation: mint under the new version,
  retain the old ones at least one retention window.
- The freeze table's message row flips from ABSENT to
  PRESENT-when-configured; `handle_batch/1` and `snapshot_progress/0` were
  subsequently added by C2/C3, while append stays absent until C4.
- AGENTS Rule 4's boundary count moves six → seven; Rule 6's AshOnetime
  paragraph gains the message-route profile (external effects admitted
  there and only there).

## Residual (named, not silent)

- **Batch composition is C2's**: the framework's §8.4 flush-before-message
  boundary (a standalone message arriving mid-batch flushes and acks the
  batch first) is transport-owned and not re-proven here; C2's
  `handle_batch/1` must carry message interleave through the batch body.
- **Claim-store retention is host-operational**: the sink cannot observe an
  expired claim; the operator sizes `retention` against realistic outage
  windows and AshOnetime's own cleanup/reap jobs (D3/D5 own the alerting
  and measured bounds).
- **The external claim's finalize-vs-rollback window**: a transactional
  external route whose ambient transaction rolls back after finalize relies
  on the recover path to re-derive the peer outcome. The peer sees the
  effect at-least-once (never exactly-once) — the honest ceiling for any
  non-transactional peer and the reason the external-effect module's
  `recover/3` must be able to prove absence.

## Approved 1.0 hardening amendment

Message prefix and content are runtime user bytes, not structural identifiers.
Unknown-prefix errors now carry only `:message_prefix_unmapped`; neither prefix
nor content enters an error shape, log, telemetry event, doctor, status, or
machine output.

The remaining hardening item is the recovery-horizon contract. A sink with
message routes declares a positive
`message_recovery_horizon`. Activation requires every route's AshOnetime
retention and every retained digest-key version to cover that horizon.
Doctor/status warn before cleanup, reap, partition maintenance, or key removal
can cross it. The horizon is the supported outage/replay window; it is not a
promise that an external peer is exactly-once.

The unknown-prefix value-free mutation and the retention/horizon negative
matrix must land before this amendment is marked implemented.
