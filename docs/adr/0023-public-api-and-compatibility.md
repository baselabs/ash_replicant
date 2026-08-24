# 23. Public API and compatibility policy

Date: 2026-08-24

## Status

Accepted for the 1.0.0 release line (roadmap D8 / PKG01).

## Context

The package ships every internal module (Elixir has no package-private
visibility): delivery internals, verifiers, census machinery, snapshot
bookkeeping. Without a declared boundary, "what consumers may call" is
whatever compiles — and any internal refactor becomes an accidental
breaking change, or an internal module becomes an accidental dependency
of a host app that nothing guards.

## Decision

1. **The public API is the module inventory frozen by
   `test/ash_replicant/public_api_freeze_test.exs`** — the operator
   surface (`AshReplicant.start_link/1`, `stop_supervised/1`, `status/1`,
   `preflight/1`, `doctor/1`, the checkpoint operator functions), the two
   DSL entry points (`use AshReplicant.Sink`, `use AshReplicant.Resource`)
   plus `AshReplicant.Resource.Info`, `AshReplicant.PipelineOwner` (the
   host-supervised child), `AshReplicant.Status` (derive/classify),
   `AshReplicant.DestinationParticipant` (the host behaviour +
   `operation_key/2`), `AshReplicant.Notifier` (the wrapper contract),
   `use AshReplicant.Checkpoint` / `AshReplicant.Pipeline` (generated
   internal resources' base modules), the Doctor surface and Report/Check
   shapes, `AshReplicant.Telemetry.emitted_event_names/0`, the Install
   planner + the four Mix tasks, the Upgrade planner, and `AshReplicant.Error`.
2. **Everything else is internal-by-convention.** Internal modules ship,
   are tested, and may change in ANY release — patch releases included.
   Hosts must not call them; a host that does has no compatibility
   contract and the repo owes them nothing.
3. **SemVer.** Within 1.x: new public modules/functions/DSL options are
   minor; fixes are patches; removing or narrowing any frozen inventory
   entry, changing a listed signature, or changing a documented default
   is a MAJOR. The freeze test reds on silent removals and renames —
   extending it is the conscious API decision.
4. **Deprecation.** A deprecated public surface keeps working for at
   least one minor cycle, emits a compile-time warning via
   `@deprecated`, and its removal lands in a major with the CHANGELOG
   carrying the migration. No silent removals, ever.
5. **Package contents** are frozen by the release contract's inspection
   predicate (no test/build residue, no secret-shaped files, required
   code/templates/docs/licenses present) — that gate is part of this
   policy's enforcement, not prose.

## Consequences

- Adding a public capability means: implement, document (README/docs +
  moduledoc), extend the freeze inventory + this ADR's list, CHANGELOG
  entry — the review sees all of them together.
- The generated-surface modules (`Checkpoint`, `Pipeline`) are API only
  as `use` targets; their generated internal bodies remain internal.
- Test fixtures are never API (the freeze excludes them by namespace).

## Evidence

- `test/ash_replicant/public_api_freeze_test.exs` — the inventory, its
  key function heads, and the ship-assertion (removal/renaming reds).
- `test/ash_replicant/action_contract_freeze_test.exs` — the frozen host
  action contract beneath the DSL (D8's behavioral half).
- The release contract's package-inspection predicate + self-test.
