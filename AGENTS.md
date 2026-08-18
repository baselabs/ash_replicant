# AshReplicant — AI Agent & Contributor Guide

How to work effectively in this repo. This file is the *how* and is
self-contained; its Critical Rules are binding. A fuller *what & why* charter is
**tracked** at `docs/CHARTER.md` (only the `/docs/superpowers/` lifecycle
artifacts — specs, plans, handoffs, reviews — are gitignored / local-only).

## What this is

An Ash `Replicant.Sink` adapter — the "`ash_postgres` of `replicant`." It owns the
Ash-native mechanism (multitenancy via the `tenant:` option on the Ash action —
resolved per-row from the source record's `tenant_attribute`, sensitive-attribute
verifiers, encryption confirmation, resource resolution) and executes through the
tenant-blind `replicant` CDC framework. It does **not** own transport, and does
**not** re-implement Ash core's `multitenancy` DSL / tenant concept.

## Architecture (realized)

A `Spark.Dsl.Extension` implementing the `Replicant.Sink` behaviour, exposing a
`replicant do ... end` resource section. The sink carries config (repo/domains/checkpoint);
the resolver index maps `{schema,table}` → resource; effect-once is guaranteed by
a durable `commit_lsn` watermark checkpointed atomically with the mirrored changes.
Activation requires the expected PostgreSQL system identifier and database;
Replicant 1.x verifies that identity from the actual replication session before
the first checkpoint read. The durable checkpoint is additionally bound to the
actual session identity (source system, database, slot, with the session
timeline recorded and any timeline change an explicit operator decision) and
carries a canonical contract manifest classified at every reconnect under the
checkpoint lock. Each slot has one serialized runtime generation, so
duplicate starts cannot replace or erase the active resolver and identity state.

## Critical rules

**1. Route writes through Ash actions, never raw Ecto.** The host resource's OWN
primary `:create` action (used as an upsert) and its `:destroy` action carry AshCloak
encryption and multitenancy scoping — the extension generates NEITHER; the host
defines them. The sink writes through them with `authorize?: false`, so AshCloak and
tenancy still fire (policies are not re-gated). Direct Ecto bypasses AshCloak and
tenancy — a bypass is a data loss / classification / encryption failure vector.

An **SCD2** mirror keeps the rule: the version close routes through the host
`history_close_action` (`:close_version`) via `Ash.bulk_update` (tenant-scoped, so it
never retires another tenant's identically-keyed version) and the new version opens
through the host `:create` upsert. The **only** raw SQL SCD2 adds is `on_truncate
:close` — a tenant-blind, window-columns-only `UPDATE` (quoted idents + parameterized
values, table/columns from the resource DSL, never a row value), the same trust boundary
as the existing `:mirror` truncate `DELETE`.

**2. Multitenancy is fail-closed.** A nil/`false`/blank tenant on a multitenant resource
must fail closed (no query runs), never silently span tenants (`false` too — Ash treats a
falsy tenant as unscoped). Source column `tenant_attribute` or `tenant_mfa` resolves the
per-row tenant; the mirror action passes it as `tenant:` so `Ash.Changeset` scopes **every
row write** — any multitenancy DSL will validate the tenant at write time. If tenant
resolution fails, the row's mirror write fails and the transaction rolls back (fail-closed).
Compile-time verifiers move the misconfigurations to build time (fail-closed at compile, per
[ADR-0001](docs/adr/0001-fail-closed-multitenancy.md)):
`ValidateTenantSource` requires a `tenant_attribute` or `tenant_mfa` on any **non-global**
Ash-multitenant resource; `ValidateMultitenancy` requires an Ash `multitenancy` block whenever
either source is declared (with no block Ash silently ignores `tenant:` and mirrors every
tenant **unscoped**; any strategy — `:attribute`/`:context`, incl. `global?` — satisfies it)
AND requires the block's own `strategy :attribute` discriminator to be a plaintext,
non-sensitive, non-binary column; and `ValidateActionMultitenancy` rejects `multitenancy
:bypass`/`:bypass_all` on any sink-selected action (primary read/create/destroy or the SCD2
close), which would otherwise let Ash ignore the tenant on a write OR a `bulk_update`/
`bulk_destroy` row match.

> **Operational requirement — tenant-scoped source tables must be `REPLICA IDENTITY FULL`.**
> A `:delete`, PK-changing `:update`, or tenant-reassigning `:update` derives the
> old tenant from `old_record`, but
> under the Postgres-DEFAULT replica identity `old_record` carries **only the primary-key
> columns** — the tenant discriminator (a non-PK attribute) is absent, so tenant
> resolution fails and the pipeline halts **fail-closed** (`:tenant_required`, never a
> base-tenant delete). Set `ALTER TABLE <src> REPLICA IDENTITY FULL` on every source
> table backing a tenant-scoped mirror so `old_record` carries the tenant column.
> Ordinary same-tenant, non-PK-changing updates need only the new `record`; tenant
> reassignment also needs the old record and is not exempt. A `tenant_mfa` must resolve
> deterministically from both record shapes. An absent, blank, or raising
> old-side resolution is a structural halt (`:tenant_required` /
> `:tenant_resolution_failed`) before any write; activation preflight enforces
> the FULL-identity requirement, so `old_record` carries the tenant on every
> update and delete. (Non-tenant mirrors work under the default identity.)
>
> The same `REPLICA IDENTITY FULL` requirement applies to an **SCD2 resource whose
> `history_business_key` is not the source primary key** — a delete / key-changing
> update reads the business key from `old_record`, absent under the default identity —
> so the close would match no open version.

**3. Sensitive = AshCloak-encrypted or binary, verified by type-shape.** Enforce
via verifier: sensitive attrs must map to an AshCloak-encrypted attribute (the
durable `before_action` hook fires on upsert) OR a binary-storage-typed attribute
(app-side encryption) OR be in `skip`. The verifier checks the type shape, not
ciphertext — encryption is the host app's job. AshCloak is the **single source of
truth** for encryption (there is NO "hand-rolled encrypted_<name>" path — that was
removed). Never list the `tenant_attribute` as `sensitive`.

**4. value-free — no row value in any error, log, or telemetry event, INCLUDING
the halt path.** Assume every value is PII or a secret. Errors are scrubbed to a
structural reason (operator + field) before Ash inspects them into logs. Column
names are strings, never atoms. Telemetry metadata is allowlisted AND TYPED
per key (LSNs, table names, counts, durations, error classes) with a closed
measurement-key set — never row values (ADR-0009). All six sink boundary bodies
catch `:throw`/`:exit` into the same scrub (the schema-change body fires the
sink's own `:halted` with the structural reason — never the sibling's
`:decode_failure` mislabel), and raw-SQL identifiers route through the ONE
quoting home, which rejects control characters at admission. Sink failures and
schema-change halts carry a cause (the `Replicant.Error` reason or `SchemaChange`
classification), not the offending column value.

**5. Stay one layer up: tenant-blind.** The `replicant` sibling is tenant-blind
and classification-blind by design — multitenancy and classification live here, in
`ash_replicant`. Never add tenant resolution or row classification logic to
`replicant`. Never import `ash_replicant` in `replicant`. The split is verified by
separate repos and separate test fixtures.

**6. Effect-once = one admitted destination graph, one transaction, watermark dedup.**
Before delivery, build the recursive destination manifest from the checkpoint and
every mapped read/create/destroy/SCD2-close action. Follow framework relationships
and custom `AshReplicant.DestinationParticipant` declarations; require exact
`touches_resources` tie-out. Every resource must use `AshPostgres.DataLayer`, the
sink's literal Repo, and that Repo's admitted effective dynamic identity. Callable,
foreign, non-Postgres, missing, opaque, cyclic, or mismatched participants fail
before effects. A declaration is trusted metadata, not proof of an arbitrary body;
it never authorizes raw SQL, another Repo, asynchronous work, or external effects.

Every committed streaming transaction is applied in ONE `Repo.transaction` while
the per-slot generation lease is held through commit/rollback. Skip any change whose
`commit_lsn <= checkpoint` of the source-bound checkpoint row — bound to the actual
replication-session identity (system identifier, database, slot name, with the
session timeline recorded and any timeline change an explicit operator decision),
locked `FOR UPDATE` for admission, and advanced monotonically so lower/equal LSNs
never regress or reapply and concurrent callers produce one effect — apply each
change through the admitted Ash action graph, then upsert the checkpoint in the
same transaction. A failure rolls back every mapped
row, declared local auxiliary effect, AshOnetime claim/response, and checkpoint; the
un-acked WAL re-streams and dedups on resume.

AshOnetime is permitted only for an admitted local auxiliary action using
`:idempotency` with `:with_action`, fail-closed PostgreSQL storage in the same Repo,
no external effect, a private non-null `operation_key`, and the exact versioned
source-system/database/slot/commit-LSN/ordinal/participant identity plus the
SINK-MINTED per-invocation label (`:close_prior | :close_current | :open |
:destroy_prior | :upsert` — ADR-0010; declarations stay 6-axis, the label is
appended at encode). Use `DestinationParticipant.operation_key/2`. Reject nonce,
independent, external, opaque-store, or incomplete-identity profiles. A
notifier whose `load/2` returns a non-empty statement must declare
`DestinationParticipant` (the `:notifier` kind) — its dependency pre-load read
runs inside the admitted transaction; suppression covers dispatch only. Static stores preflight at activation;
context-tenant stores preflight inside the outer transaction.

Generated delivery callbacks are final and call `Sink.Impl` directly. Never add a
host-overridable effect hook. Reject `SetContext` changes/preparations that replace
`:data_layer` (a dynamic/MFA context is admissible only when its module declares
`DestinationParticipant`), and require `AshOnetime.Cache.None`; both otherwise
create effects outside the admitted action/transaction boundary.

Current v1 snapshot batches are atomic, but an incomplete multi-batch restart can
physically repeat committed batch effects before rebuilding the target. Do not claim
snapshot-wide physical effect-once until C3 proves zero repeats. Message, sink-owned
batch, incremental-progress, and append-log callbacks remain absent until C1–C4.

## Development workflow

The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash
`>= 3.31.3 and < 4.0.0-0` and Replicant
`>= 1.0.0 and < 2.0.0-0` (current release-candidate lock 1.1.0).

```bash
asdf install
scripts/with-release-runtime.sh scripts/assert-runtime-version.sh
scripts/with-release-runtime.sh mix deps.get
scripts/with-release-runtime.sh mix format --check-formatted
scripts/with-release-runtime.sh mix compile --warnings-as-errors
scripts/with-release-runtime.sh mix credo --strict
env -u ASH_REPLICANT_TEST_URL \
  scripts/with-release-runtime.sh scripts/run-structural-tests.sh \
    --allow-excluded --exclude integration
scripts/with-release-runtime.sh mix deps.audit
scripts/with-release-runtime.sh mix dialyzer
scripts/with-release-runtime.sh mix docs --warnings-as-errors
scripts/with-release-runtime.sh mix hex.build
```

The complete release battery also includes the live PostgreSQL integration,
explicit integration discovery, resource-snapshot drift, checker self-tests,
and release-contract tests listed in `CONTRIBUTING.md`. `mix quality` covers only
format, Credo, and Dialyzer. Changes are recorded under `[Unreleased]` in
`CHANGELOG.md`.

## Testing

- **Unit** (`test/*_test.exs`): DSL/verifier/compilation tests, no server.
- **Integration** (`test/integration/**`, `@moduletag :integration`): require a
  live Postgres with the source logical-replication stream running; gate on
  environment setup, skip when unset. TDD: test first.

## Docs & lifecycle-artifact policy

- **Tracked / published:** `AGENTS.md`, `CLAUDE.md`, `README.md`, `CHANGELOG.md`,
  `CONTRIBUTING.md`, `usage-rules.md`, `LICENSE`, `NOTICE`, the project charter
  (`docs/CHARTER.md`), `docs/ROADMAP.md`, the ADR corpus (`docs/adr/`), and the
  historical implementation handoffs (`docs/handoffs/`).
- **Never tracked (local-only):** the superpowers lifecycle artifacts — brainstorm
  specs, plans, exec notes, reviews, and handoffs — under `/docs/superpowers/`, which
  is **gitignored** (the `replicant` convention). Keep them there.

## Next action

Start from a working feature or bugfix; TDD against the critical rules above.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
