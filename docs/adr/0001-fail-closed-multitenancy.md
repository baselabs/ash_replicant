# 1. Multitenancy is fail-closed; a declared tenant source requires a multitenancy block

Date: 2026-07-14

## Status

Accepted. Records CHARTER decision **[D2]** (previously governed by charter prose only).
Strengthened 2026-07-14 by three fixes surfaced during closeout: the `tenant_mfa` compile-gate
symmetry (mode 2), the `false`-tenant runtime fail-close (mode 1), and the sink-action
`:bypass` gate (mode 3, `ValidateActionMultitenancy`).

## Context

`ash_replicant` mirrors CDC changes into host Ash resources. Tenant-scoped resources declare
a per-row tenant **source** in the `replicant` section — either `tenant_attribute :col` (the
tenant is a source column) or `tenant_mfa {M, F, A}` (the tenant is a function result). The
sink resolves the tenant per row and passes it to the host Ash action as the `tenant:` option.

Two failure modes must be closed:

1. **Nil/blank tenant at runtime.** A source row whose tenant resolves to nil/blank must not
   fall back to a "base tenant" or span tenants — that would mirror one tenant's data into
   another's scope.
2. **No Ash `multitenancy` block declared (silent, verified against Ash source).**
   `Ash.Changeset.validate_multitenancy` is a **no-op when the resource's
   `multitenancy_strategy` is nil**: the `tenant:` option is accepted and then silently
   ignored, so every tenant's rows are written UNSCOPED into one table. No error is raised —
   the failure is completely silent (the most dangerous class). Both Ash strategies
   (`:attribute`, which force-sets the discriminator; `:context`, which threads the tenant to
   the data layer) honor `tenant:`; only the ABSENCE of a block is the fail-open.

## Decision

**Multitenancy is fail-closed. There is never a base-tenant fallback.**

- **Runtime (mode 1):** `AshReplicant.Resolver.resolve_tenant/2` returns
  `{:error, :tenant_required}` on a nil/`false`/blank/whitespace tenant, and `resolve_tenant!/3`
  raises a value-free `AshReplicant.Error` before the write is attempted — defense in depth on
  top of Ash's own multitenancy validation. `false` is included because Ash treats a falsy
  tenant as **no scoping** (neither force-set nor required — `create.ex` `handle_multitenancy`
  guards on truthiness), so a `tenant_mfa` returning `false` would otherwise write unscoped.
  A tenant-scoped delete / key-changing update needs the tenant in `old_record`, so the source
  table must be `REPLICA IDENTITY FULL` (see AGENTS.md Critical Rule 2 and the operational note).

- **Compile time (mode 2):** a declared tenant source requires an Ash `multitenancy` block —
  **symmetrically for both sources**:
  - `tenant_attribute` ⇒ requires a block (any strategy). Additionally shape-checked:
    non-sensitive, not in `skip`, declared, non-binary-storage.
  - `tenant_mfa` ⇒ requires a block (any strategy). No shape checks — the tenant is a function
    result, not a column. `:context` is the typical pairing.
  - Any strategy satisfies (both honor `tenant:`); `global?` is fine (a global resource still
    honors `tenant:` when one is given). Only the ABSENCE of a block is rejected.
  - The converse — a non-global multitenant resource with NO tenant source — is rejected by
    `ValidateTenantSource` (fires only when a block exists; the two verifiers' fire-conditions
    are disjoint, so they never both fire on one resource).

- **Compile time (mode 3) — sink-action bypass:** the sink writes through the host's PRIMARY
  create / destroy (and the SCD2 `history_close_action`). An Ash action can declare
  `multitenancy :bypass` / `:bypass_all`, which makes Ash ignore the tenant even with a valid
  block (`create.ex` `handle_multitenancy`: neither force-set nor required). `ValidateActionMultitenancy`
  rejects `:bypass`/`:bypass_all` on any sink-selected write action of a multitenant resource.
  `:enforce` (default) and `:allow_global` are permitted — both force-set when a tenant is
  present, and the sink always passes a resolved one.

The compile gates move these fail-opens to build time under `--warnings-as-errors`, matching the
project's fail-closed-at-compile-time posture (`ValidateSensitive`, `ValidateTenantSource`).

## Consequences

- A resource declaring `tenant_attribute` or `tenant_mfa` **must** also declare a `multitenancy`
  block or the build fails — a deliberate, documented constraint (AGENTS.md Rule 2, README,
  usage-rules). Host authors get a value-free compile error naming the fix.
- No cross-tenant leak via the silent no-block path is reachable; the runtime `:tenant_required`
  halt remains the backstop for nil-tenant rows.
- **Known residual (not closed by this ADR):** neither arm validates that the multitenancy
  *block's own* `attribute` (under `strategy :attribute`) is non-sensitive/non-binary. A block
  whose discriminator column is AshCloak-encrypted would mis-scope at runtime — a LOUD class
  (reads return empty), symmetric across both arms, tracked as a follow-up.

## Evidence

- Runtime: `lib/ash_replicant/resolver.ex:60-93,267-277` (incl. the `false` fail-close clause);
  `apply.ex:95,128`; `apply/scd2.ex:30,34,44`.
- Compile: `lib/ash_replicant/resource/verifiers/validate_multitenancy.ex` (both arms),
  `validate_tenant_source.ex` (converse), `validate_action_multitenancy.ex` (sink-action bypass).
- Tests: `test/ash_replicant/validate_multitenancy_test.exs` + `validate_action_multitenancy_test.exs`
  + `resolver_test.exs` (all fail-opens RED-proven), `validate_tenant_source_test.exs`.
- Ash-source verification: `Ash.Changeset.validate_multitenancy` no-op when strategy nil;
  `create.ex` `handle_multitenancy` truthiness/bypass guards — confirmed in
  `.forge/reviews/2026-07-14-tenant-mfa-*.md`.
- History: `tenant_attribute` gate `c0a379f` (2026-07-10); `tenant_mfa` symmetry + `false`
  fail-close + sink-action bypass gate 2026-07-14.
