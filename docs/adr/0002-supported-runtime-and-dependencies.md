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

## Amendment (2026-09-29): the Ash and Replicant floors move; the AshOnetime and Mint locks move

Four facts, all observed on 2026-09-28/29, move the floors:

- **Ash floor rises to `>= 3.33.11 and < 4.0.0-0`.** Every release in the
  advisory's affected range (`>= 2.17.15` and `< 3.33.11`) carries
  EEF-CVE-2026-93477; the exact-floors CI cell runs
  `mix deps.audit` against the resolved floor set, and that cell is red
  against the old 3.33.4 floor — the floor itself admitted a
  vulnerable patch, so the floor must rise with the advisory database.
- **Replicant floor and lock move to 1.3.0** (`>= 1.3.0 and < 2.0.0-0`).
  Replicant 1.3.0 changes the public `lsn_from_string/1` return shape
  (a deliberate minor-shipped contract change, its ADR-0008) and fixes
  silent casting corruption in 1.2.x (`interval[]` truncation,
  locale-dishonest `money`, truncated `timetz`); a mirror sink's value is
  its fidelity, so the floor guarantees the corrected casting contract.
  The sink does not call the changed function; the two
  test fixtures unwrap the new tuple (under the tuple shape one prior
  assertion passed vacuously — Elixir orders tuples above integers), and the
  only `lib/` change is the doctor's runtime requirement literals.
- **Replicant floor and lock move to 1.4.0** (`>= 1.4.0 and < 2.0.0-0`).
  Replicant 1.4 added the decoder option grammar this package now forwards
  (`decoder:` and its per-decoder keys, ADR-0026); the documented decoder
  contract — the `:decoder_unsupported` admission refusal, Replicant's own
  grammar and capability refusals — is only true of a 1.4 runtime, and a
  1.3.x resolution would silently drop forwarded options instead of
  validating them. No casting, checkpoint, or sink-callback changes ship in
  1.4 that the adapter calls directly (PG15+ delivery is byte-identical to
  1.3.0); the lock-only behaviors the adapter documents are the pre-PG15
  empty-transaction suppression and the every-decoder dropped-column halt,
  both transport-internal on the supported 16–18 matrix.
- **AshOnetime lock moves to 1.4.0** (requirement unchanged): the pre-peer
  claim lock closes the in-flight-retry double-spend window on
  external-effect message routes; no ash_replicant code depends on new API.
- **Mint lock moves to 1.11.0** (optional requirement unchanged):
  EEF-CVE-2026-91043 (HIGH), EEF-CVE-2026-92103, EEF-CVE-2026-94194.
- **Replicant lock moves to 1.4.1** (October 2, 2026; requirement unchanged
  at `>= 1.4.0 and < 2.0.0-0`): a transport patch — no public API additions,
  removals, or signature changes — whose four consumer-facing deltas were
  verified against its bytes with no impact here (RI-FULL column key flags
  uniform across decoders, consumed nowhere in this adapter; wal2json JSON
  numbers halting `:decode_failure`, unreachable under the
  transport-mandatory `numeric-data-types-as-string`; the wal2json
  schema-guard timer no longer stacking across reconnects; NULL columns as
  in-array nulls). The earlier "release lock is 1.2.3" sentence above is the
  ADR-0005-era amendment, superseded by the 1.4.0 floor move and this note.
- **Replicant lock moves to 1.4.2** (October 3, 2026; requirement unchanged
  at `>= 1.4.0 and < 2.0.0-0`; tar checksum `aa150113…8d56e` verified
  against the Hex release API before locking): a transport patch whose
  single library change — verified against the `v1.4.1…v1.4.2` bytes,
  `query_builder.ex` alone — admits PostgreSQL 9.6's two-part
  exported-snapshot name (`"%08X-%d"`) in `set_transaction_snapshot/1`
  alongside the 10+ three-part form, same character class, the
  string-literal guard intact. No adapter code calls that function
  (re-verified: zero references in `lib/`); the consumer-facing effect
  lands on the supported 9.6 plugin-decoder matrix (ADR-0026), where
  `snapshot: true` previously failed its back-fill (`:snapshot_failed` →
  `:snapshot_incomplete`, fail-closed, delivering nothing) and now
  completes. The floor deliberately stays 1.4.0: the broken slice is loud
  and fail-closed — not the silent-casting or advisory class of the 1.3.0
  and AshCloak floor moves above — and ADR-0026's same-day amendment
  records the delegated 9.6 snapshot evidence (upstream's connected leg)
  that now exists.

## Evidence

- Package contract: `mix.exs`, `.tool-versions`, and `mix.lock`.
- Resolution assertion: `scripts/assert-dependency-version.sh` and the CI
  compatibility matrix.
- Security gates: `mix hex.audit` and `mix deps.audit`.
- Runtime gates: compile warnings-as-errors, the live PostgreSQL suite, and
  Dialyzer on the Elixir 1.20.3 PLT.
