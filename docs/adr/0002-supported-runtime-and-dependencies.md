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
  ymlr 5.1.6, and Replicant 1.2.3 (a point-in-time proof snapshot; patch
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
`>= 1.2.3 and < 2.0.0-0`, the release lock is 1.2.3, and CI exercises both the
exact 1.2.3 floor and the selector-free current lock.

The Ash, AshPostgres, and AshOnetime portions were amended September 22, 2026
to carry the AshOnetime 1.3 floor (1.3.2 published September 21, 2026): Ash is
declared `>= 3.33.4 and < 4.0.0-0`, AshPostgres `~> 2.13`, optional Igniter
`>= 0.8.4 and < 1.0.0-0`, and AshOnetime `>= 1.3.2 and < 2.0.0-0` (current
lock 1.3.2). AshSQL `>= 0.7.1` and Mint `>= 1.10.1` enter only as transitive
requirements of that floor, not as direct dependencies. The Elixir `~> 1.20.3`
requirement, the OTP 29 release evidence, and the selector/CI shape above are
unchanged; the exact-floors CI cell now proves Ash 3.33.4 and AshOnetime 1.3.2
together, and the selector-free metadata assertion checks the published
`ash_onetime` requirement alongside Ash and Replicant. Consumers additionally
pin Ash's string-length counting basis
(`config :ash, default_string_length_count: :codepoints`) in their own host
config — the library never mutates global Ash config.

The AshCloak portion was amended September 22, 2026 for security: AshCloak is
declared `>= 0.4.0 and < 1.0.0-0` (previous range `~> 0.1`, previous lock
0.3.1). Two advisories — EEF-CVE-2026-81319 (unsafe deserialization of
decrypted terms, node DoS) and EEF-CVE-2026-81322 (cloaked plaintext leak
through a non-sensitive action argument) — affect every AshCloak release
below 0.4.0 and are fixed only in 0.4.0, so a floor below 0.4.0 admits a
known-vulnerable dependency and the range now refuses to resolve to one.
ash_replicant itself owns no decrypt path (rule 1: writes route through the
host actions where AshCloak's before_action hook fires), so the fix rides the
host dependency, and the release contract pins the requirement in both the
local mix contract and the selector-free metadata assertion, each guarded by
a mutation probe that weakens the floor back to `~> 0.1`. The same amendment
moves the Replicant release lock to 1.2.4 within the unchanged
`>= 1.2.3 and < 2.0.0-0` requirement (the exact 1.2.3 floor cell keeps
proving the declared floor), and refreshes the development-only dialyxir and
ex_doc locks, which are not shipped in the package.

## Evidence

- Package contract: `mix.exs`, `.tool-versions`, and `mix.lock`.
- Resolution assertion: `scripts/assert-dependency-version.sh` and the CI
  compatibility matrix.
- Security gates: `mix hex.audit` and `mix deps.audit`.
- Runtime gates: compile warnings-as-errors, the live PostgreSQL suite, and
  Dialyzer on the Elixir 1.20.3 PLT.
