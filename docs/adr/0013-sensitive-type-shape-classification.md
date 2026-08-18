# 13. Sensitive type-shape classification: AshCloak ∪ binary storage ∪ `skip`

Date: 2026-08-18

## Status

Accepted. Governs the `replicant do sensitive [...] end` classification
contract as shipped (the compile verifier, the write routing, and the
tenant-discriminator ban). Authored on-touch by the docs-alignment slice
that found the gap list had retired this row by mis-attribution to
ADR-0009 (which governs the value-free boundary, a different decision).

## Context

A source column declared `sensitive` must never be mirrored as plaintext:
the mirror's destination row is the classified data's new home, and a
plaintext write there defeats the classification entirely. But the adapter
cannot verify ciphertext (encryption happens in the host's write path),
so "sensitive" can only be admitted by the SHAPE of the declared write
target — the column must provably land in an encrypted-at-rest attribute
or never be written at all.

A second failure shape is the tenant discriminator: a multitenancy
`:attribute` strategy discriminator must be a plaintext comparator column
(it scopes every mirrored write). Classifying it `sensitive` — or letting
it be an encrypted/binary column — would make the scoping comparison
meaningless while appearing protected.

## Decision

1. A name in `sensitive [...]` is admitted at COMPILE time (Spark
   verifier, build-blocking under `--warnings-as-errors`) if and only if
   it is any of:
   - **(a)** an AshCloak cloak attribute of the resource
     (`name in AshCloak.Info.cloak_attributes!/1`, guarded to resources
     that actually use AshCloak);
   - **(b)** a declared attribute whose storage type is `:binary`
     (`Ash.Type.storage_type/2 == :binary` — the host encrypts
     app-side and stores ciphertext there); or
   - **(c)** listed in `skip` (never written).
   Anything else fails closed with a value-free structural message.
2. The verifier checks the TYPE SHAPE, never ciphertext — encrypting is
   the host resource's (AshCloak's) job. AshCloak is the single source of
   truth for encryption: a hand-rolled `encrypted_<name>` attribute
   WITHOUT AshCloak is NOT accepted (no encryptor the verifier can
   confirm, and the resolver would mirror the column as plaintext —
   blessing that shape would leak).
3. Write routing follows the classification
   (`AshReplicant.Resolver.upsert_input/2`): cloak attributes pass their
   source value as plaintext under the cloak argument while the upsert
   names the AshCloak-managed `encrypted_<col>` field (AshCloak's
   durable `before_action` hook fires on the host's own upsert action);
   binary-storage attributes carry the value through to the host's
   encryption; `skip` columns are never mapped. Resources with any
   sensitive attribute route the snapshot path per-record — bulk is
   conservative there, not a plaintext guard.
4. The multitenancy `:attribute` discriminator is NEVER sensitive: it
   must be a plaintext, non-sensitive, non-binary comparator column
   (enforced by `ValidateMultitenancy` alongside this verifier).

## Consequences

- A mis-declared `sensitive` column is a COMPILE failure, not a runtime
  plaintext leak discovered later.
- The adapter never owns encryption keys or ciphertext policy; it owns
  only the admission shape and the routing discipline.
- `skip` is the only "do nothing" escape — there is deliberately no
  plaintext-tolerance escape.
- The classification is per-resource at compile time; drift (a host
  removing AshCloak from an attr the sink classified) is caught by the
  generation admission's runtime re-validation of the sink config, not
  re-verified per row.

## Evidence

- `lib/ash_replicant/resource/verifiers/validate_sensitive.ex` — the
  three-clause admission, the hand-rolled-`encrypted_<name>` refusal,
  the type-shape-not-ciphertext stance.
- `lib/ash_replicant/resource/verifiers/validate_multitenancy.ex:39-40,
  82-86` — the discriminator plaintext/non-sensitive/non-binary ban.
- `lib/ash_replicant/resolver.ex` (`upsert_input/2`) — cloak plaintext
  under the cloak argument + `encrypted_<col>` upsert fields; binary
  passthrough; skip exclusion.
- `test/ash_replicant/validate_sensitive_test.exs` — six cases: the
  plaintext tripwire, the skip green control, both hand-rolled
  refusals (string and binary), the binary-storage green, and the
  AshCloak-backed green.
- `AGENTS.md` Critical Rule 3 (the normative statement this record
  governs).
