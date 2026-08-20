# 2. Support Elixir 1.20.3/OTP 29 and an audit-clean Ash 3 line

Date: 2026-08-13

## Status

Accepted for the 1.0.0 release line.

## Context

The package previously declared Elixir `~> 1.15`, Ash `~> 3.11`, and
AshPostgres `~> 2.6`, while its release lock carried known Ash, Postgrex, and
ymlr advisories. Those broad requirements did not describe the runtime or
dependency graph being prepared for the stable release.

AshOnetime 0.6.0 is the project-owned idempotency mechanism for admitted local
auxiliary actions and the future logical-message actions that need replay guards.
It requires the Elixir 1.20 and current AshPostgres families. Live floor
resolution also established two stricter facts:

- Ash 3.31.1 is retired;
- Ash 3.31.2 has HIGH CVE-2026-67579.

Elixir requirement matching admits `4.0.0-rc.*` under `< 4.0.0`, so that upper
bound does not mean “Ash 3 only.”

## Decision

- The package requires Elixir `~> 1.20.3`. The repository and release evidence
  use Elixir 1.20.3 compiled for Erlang/OTP 29, with Erlang 29.0.3 in
  `.tool-versions`.
- Ash is declared as `>= 3.31.3 and < 4.0.0-0`. The lower bound excludes the
  known-vulnerable patches; the `-0` upper bound excludes every Ash 4
  prerelease.
- The release lock at the 1.0.0-rc decision point resolved Ash 3.31.3,
  AshPostgres 2.11.0, AshOnetime 0.6.0, EctoSQL 3.14.0, Postgrex 0.22.4,
  ymlr 5.1.6, and Replicant 1.2.1 (a point-in-time proof snapshot; patch
  versions drift with `mix.lock` — derive the current set from the lock,
  never from this sentence).
- Public dependency families are bounded with patch-qualified requirements for
  AshPostgres 2.11, AshOnetime 0.6, Replicant 1.x, Spark 2.7, Telemetry 1.4,
  Postgrex 0.22.4, and ymlr 5.1.6.
- `ASH_REPLICANT_ASH_VERSION` is a repository CI selector. Unset, empty, or
  `latest` publishes the public Ash range; an exact selector must be a semantic
  version inside that range. Invalid, vulnerable, and Ash 4 prerelease values
  fail while loading the Mix project.
- CI resolves and tests the exact floor and floating latest compatible Ash 3.x,
  while a separate selector-free job proves the dependency requirement shipped
  in the package.

AshOnetime supplements the checkpoint for an admitted local auxiliary action when
its claim, response, effect, mapped rows, and checkpoint share the destination
transaction. It will also support message idempotency when C1 implements those
actions. It does not replace the indefinitely durable commit-LSN checkpoint:
transaction admission, restart position, and checkpoint dedup remain one
destination transaction with the mirrored Ash actions. The accepted WAL profile
and nonce rejection are recorded in
[ADR-0006](0006-destination-transaction-boundary.md).

## Consequences

- Consumers of the stable line need Elixir 1.20.3/OTP 29-compatible deployment
  infrastructure and the current AshPostgres family.
- A known-vulnerable Ash patch cannot satisfy dependency resolution, even if it
  still satisfies AshOnetime's broader published requirement.
- Future compatible Ash 3 security releases can resolve without an
  AshReplicant release, but the floating CI cell detects behavior drift.
- Ash 4 requires a deliberate compatibility decision and a new package range;
  prereleases cannot enter through the current constraint.

The Replicant portion of this decision was amended by
[ADR-0005](0005-replicant-coordination.md): the public requirement is now
`>= 1.2.1 and < 2.0.0-0`, the release lock is 1.2.1, and CI exercises both the
exact 1.2.1 floor and the selector-free current lock.

## Evidence

- Package contract: `mix.exs`, `.tool-versions`, and `mix.lock`.
- Resolution assertion: `scripts/assert-dependency-version.sh` and the CI
  compatibility matrix.
- Security gates: `mix hex.audit` and `mix deps.audit`.
- Runtime gates: compile warnings-as-errors, the live PostgreSQL suite, and
  Dialyzer on the Elixir 1.20.3 PLT.
