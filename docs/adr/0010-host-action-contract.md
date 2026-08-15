# 10. Host action contract: per-invocation operation identity and notifier admission

Date: 2026-08-14

## Status

Accepted for the 1.0.0 release line (roadmap B6). Amends
[ADR-0006](0006-destination-transaction-boundary.md) (its walk gains notifier
admission; its "exactly six components" replay identity is superseded by the
sink-minted seventh axis below). Composes with
[ADR-0007](0007-source-bound-checkpoint-effect-once.md) (the checkpoint
watermark the admitted effects advance).

## Context

Two silent-failure classes sat inside the admitted destination graph:

1. **The intra-change operation-key collision.** Replicant assigns ONE
   ordinal per CHANGE; the apply path fans one change to up to three effects
   (SCD2 close-prior + close-current + open), and the two closes run the
   SAME `history_close_action`. With a six-component operation identity
   (system, database, slot, commit LSN, ordinal, participant), the two
   closes minted IDENTICAL AshOnetime operation keys: the second close
   replayed the first's stored response, its body never ran, and a declared
   effect was silently missing — exactly the loss class the one-claim
   contract exists to prevent. Per-action participant scoping cannot
   discriminate them (same action, same change, same ordinal).
2. **Notifier `load/2` executed host code outside the admitted graph.** Ash
   runs a notifier's dependency pre-load read after every successful single
   create/destroy with NO notify gate — and the sink's own snapshot
   `bulk_create` keeps it alive under `return_records?: false` by passing
   `return_notifications?: true` (which preserves `need_notifications?`).
   The sink's suppression story ("documented + tested: notifiers do not
   fire") was true for DISPATCH only; "documented suppression" of the
   pre-load would have documented a falsehood.

## Decision

- **A sink-minted per-invocation discriminator.** The private
  `:ash_replicant_operation` context gains `invocation: <label>` from a
  CLOSED label set — one per apply call site (`:close_prior`,
  `:close_current`, `:open`, `:destroy_prior`, `:upsert`) — appended to the
  canonical AshOnetime encoding; absent/mistyped/off-set labels fail
  `:invalid_declaration`. `DestinationParticipant.operation_components/0`
  is the ONE home for the component list, consumed by both minting
  (`operation_key/2`) and the declaration check.
- **Declarations stay SIX-axis.** `valid_replay_identity?/1` requires the
  declared component list to equal `operation_components() -- [:invocation]`.
  Rationale: a declaration is trusted metadata over the declared graph, but
  operation-key UNIQUENESS within one change is the SINK's guarantee — a
  host-declared discriminator axis is a forgeable/aliasable replay identity
  (the host controls the changeset; it could alias two invocations onto one
  key and silently suppress a declared effect, the exact collision class).
  The host has nothing legitimate to declare about intra-change identity;
  `SetContext` over `:ash_replicant_operation` is already rejected for the
  same reason.
- **Replay stability, no migration surface.** The per-change effect order is
  fixed by the apply path, so static call-site labels re-mint identically on
  re-delivery (rollback + re-stream dedups exactly as before). Claims and
  responses live and die inside the same transaction as their effects; a
  committed change is acked and never re-claimed, so the 6→7-element
  encoding change has no durable-key migration surface.
- **Breaking change for manual minters:** `operation_key/2` requires the
  `:invocation` key; host code and probes minting keys by hand (tests,
  replay probes) must carry the label the sink mints at that effect site.
- **Notifier `load/2` admission.** The manifest walk inspects, for every
  admitted action, the exact notifier set Ash consults
  (`Ash.Resource.Info.notifiers(resource) ++ List.wrap(action.notifiers)`).
  A notifier whose `load/2` returns a non-empty statement — probed exactly
  as Ash probes (`implements_load?` first: the callback is optional and a
  `load/2`-absent notifier imposes nothing; then `Ash.Notifier.load/2` with
  non-empty = `List.wrap != []`; probe faults fail closed) — must implement
  `DestinationParticipant` for the new `:notifier` context kind; missing →
  `{:destination_notifier_required, resource, action, notifier}`. Declared
  refs enter the walked graph (sourced from the notifier) but not the host
  action's `touches_resources` tie-out: a same-resource load read cannot be
  declared on a `defaults [:read]` action, and the tie-out remains the
  ACTION-participant contract. `{:ok, :no_database}`/empty refs admit with
  no new edge (the same-resource read is already in the graph). This is the
  same trust model as `tenant_mfa`: sink-triggered host code that touches
  the database must declare its participants.
- **The freeze table** (`action_contract_freeze_test.exs`): every action
  class the sink drives is pinned against live reflection — the primary
  read/create/destroy, the SCD2 close (its `:update` type-check at compile
  is `ValidateHistory.check_close`'s, an existing enforcement cited rather
  than a new gap), the checkpoint roots, declared auxiliaries, and the
  append/message rows that stay ABSENT until C1/C4. The reason space is
  enumerated by arity + module-ness (a field-dropping diagnostic regression
  goes red), and the after-compile RENDERING names resource + declaring
  module (identify-each, first-failure halting).
- **Ash-bump procedure:** the old-contract greps (dispatch suppression,
  pre-load gate, bulk ordinal context shape, AshOnetime replay semantics)
  are documented in CONTRIBUTING and owed on every Ash bump.

## Residual (named, not silent)

**Probe-to-use gap (cross-vendor, named):** admission probes `load/2` on a
best-effort basis, but Ash calls `load/2` AGAIN at action runtime — a
stateful callback can return empty at every admission probe and non-empty
mid-action, executing an undeclared preload while every guard stays green.
This is the same declared-semantics trust boundary as the lying module
below: the declaration carries the trust, the probe is advisory; closing it
would require wrapping Ash's own notifier dispatch, outside the admitted
action path. Named here rather than silently assumed. The same boundary
covers the walk's `declared_by` skip: while walking an action that notifier
N declared, N is not re-probed for THAT action's context — a
context-parameterized declaration could carry different edges per
(resource, action); its edges from every OTHER probe still validate.

The discriminator is minted per SINK call site and rides the ONE operation
map per host-action invocation: a HOST change module that invokes its
declared protected auxiliary twice inside ONE invocation still mints one
identical key, and AshOnetime replays the first's stored response — the same
silent-loss class one layer down. This is a declared-semantics obligation on
every declared participant (SINGLE-INVOCATION: an auxiliary action invoked
twice within one host action invocation must key itself, e.g. by its own
ordinal argument); the admission trust boundary absorbs it as a named
obligation. The enumeration test pins the sink-side inventory and cannot see
host-side fanout.
