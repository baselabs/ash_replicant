# 11. Frozen reason and event taxonomy: the error reasons and telemetry event names are a pinned public contract

Date: 2026-08-17

## Status

Accepted. The mechanisms this record freezes were shipped with ADR-0009's
classified-boundaries work (2026-08-14) and the u3 cross-vendor closure; the
freeze tests predate this record. This ADR pins what was already enforced and
assigns the ownership the roadmap gap list was missing (B5 / D3 / D8).

## Context

Rule 4 (value-free boundaries) requires that every error, log line, and
telemetry event carry structure an operator can branch on and nothing a row
value could ride on. That requirement forces exactly two closed vocabularies:

- the **error reason set** — the atoms `AshReplicant.Error` can carry. Hosts
  match on reasons to build runbooks and alerting; an open set means a
  patch release can silently rename a reason out from under a host's `case`.
- the **telemetry event-name inventory** — the event prefixes/names the
  library emits. Monitoring configs bind to these names; drift is silent
  dashboard breakage.

Both vocabularies were already mechanically pinned by tests before this
record: `@closed_reasons` in `AshReplicant.Error` (with a live grep pin that
the set equals every `reason:` minted anywhere in `lib/`, and scrub dropping
any forged reason to `:sink_failed`), and
`AshReplicant.Telemetry.emitted_event_names/0` (with the integration
conformance gate attaching a validated handler to EVERY emitted name). What
did not exist was the *contract statement*: nothing told a contributor that
changing these sets is a public-contract change requiring migration notes,
not routine internal cleanup.

ADR-0009 covers the value-free MECHANICS (scrub, typed telemetry metadata,
the quoting home). This record covers the VOCABULARY freeze.

## Decision

1. The closed reason set (`AshReplicant.Error.@closed_reasons` plus the one
   structural tuple `{:invalid_destination_config, :onetime_store}`) and the
   telemetry event-name inventory (`emitted_event_names/0`) are pinned
   public contract for the 1.0.0 line.
2. Additive growth (a NEW reason for a NEW halt class, a NEW event for a NEW
   capability) is allowed with a CHANGELOG entry in the same landing.
3. Removal, rename, or semantic re-pointing of an existing reason or event
   name is breaking: it requires a minor-version boundary, a migration note
   (old name → new name), and a grep sweep of docs/tests that match the old
   name. The freeze tests are the tripwire: the live reason-mint pin and the
   conformance gate go red if the sets drift from the code.
4. Ownership: B5 owns the reason set's semantics, D3 owns the event
   inventory's operational contract, D8 freezes both in the public package
   inventory. A change to either set routes through those rows.

## Consequences

- Contributors cannot casually reword a reason atom while refactoring — the
  live grep pin (`error_test.exs`) forces the set and the mints to move
  together, and this record forces the CHANGELOG entry the freeze implies.
- Hosts may `case` on reasons and subscribe to event names without pinning a
  library patch version defensively.
- The scrub pipeline's closed-set behavior (forged reasons drop to
  `:sink_failed`) composes with this freeze: even a hostile struct cannot
  introduce a reason outside the frozen set.

## Evidence

- `lib/ash_replicant/error.ex` — `@closed_reasons`, the `typed_reason/1`
  compile-time generated clauses, the drop-to-`:sink_failed` default.
- `test/ash_replicant/error_test.exs` — "the closed reason set equals every
  reason minted in lib (live pin)".
- `lib/ash_replicant/telemetry.ex` — `emitted_event_names/0`.
- `test/integration/telemetry_conformance_test.exs` — handlers attached to
  every emitted event name, each emission validated.
- ADR-0009 (mechanics), ADR-0010 (the per-invocation identity that rides on
  typed telemetry).
