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

**2. Multitenancy is fail-closed.** A nil/blank tenant on a multitenant resource
must fail closed (no query runs), never silently span tenants. Source column
`tenant_attribute` or `tenant_mfa` resolves the per-row tenant; the mirror action
passes it as `tenant:` so `Ash.Changeset` scopes **every row write** — any
multitenancy DSL will validate the tenant at write time. If tenant resolution fails,
the row's mirror write fails and the transaction rolls back (fail-closed). A
compile-time verifier (`ValidateTenantSource`) additionally requires a
`tenant_attribute` or `tenant_mfa` on any **non-global** Ash-multitenant resource —
so the misconfiguration fails closed at build time, not only at runtime.

> **Operational requirement — tenant-scoped source tables must be `REPLICA IDENTITY FULL`.**
> A `:delete` (and a PK-changing `:update`) derives the tenant from `old_record`, but
> under the Postgres-DEFAULT replica identity `old_record` carries **only the primary-key
> columns** — the tenant discriminator (a non-PK attribute) is absent, so tenant
> resolution fails and the pipeline halts **fail-closed** (`:tenant_required`, never a
> base-tenant delete). Set `ALTER TABLE <src> REPLICA IDENTITY FULL` on every source
> table backing a tenant-scoped mirror so `old_record` carries the tenant column. Insert
> and non-PK-changing update need only the new `record` (which always carries all
> columns), so they are unaffected; the requirement is specific to delete / PK-change of
> tenant-scoped resources. (Non-tenant mirrors work under the default identity.)
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
names are strings, never atoms. Telemetry metadata is allowlisted (LSNs, table
names, counts, durations, error classes) — never row values. Sink failures and
schema-change halts carry a cause (the `Replicant.Error` reason or `SchemaChange`
classification), not the offending column value.

**5. Stay one layer up: tenant-blind.** The `replicant` sibling is tenant-blind
and classification-blind by design — multitenancy and classification live here, in
`ash_replicant`. Never add tenant resolution or row classification logic to
`replicant`. Never import `ash_replicant` in `replicant`. The split is verified by
separate repos and separate test fixtures.

**6. Effect-once = one transaction, dedup by watermark, upsert by PK.** Every
transaction is applied in ONE `Repo.transaction`. Skip any change whose
`commit_lsn <= checkpoint` (the watermark is the durable LSN last persisted to the
checkpoint table). Apply each change per-record (upsert-by-PK-identity / destroy /
truncate per policy), then upsert the checkpoint **in the same transaction**.
A failure rolls the whole transaction back (fail-closed); the un-acked WAL
re-streams and dedups on resume.

## Development workflow

```bash
mix deps.get
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
mix dialyzer
# or: mix quality
```

All gates pass before commit/PR. Update `CHANGELOG.md` under `[Unreleased]`.

## Testing

- **Unit** (`test/*_test.exs`): DSL/verifier/compilation tests, no server.
- **Integration** (`test/integration/**`, `@moduletag :integration`): require a
  live Postgres with the source logical-replication stream running; gate on
  environment setup, skip when unset. TDD: test first.

## Docs & lifecycle-artifact policy

- **Tracked / published:** `AGENTS.md`, `README.md`, `CHANGELOG.md`,
  `CONTRIBUTING.md`, `usage-rules.md`, `LICENSE`, `NOTICE`, and the project charter
  (`docs/CHARTER.md`).
- **Never tracked (local-only):** the superpowers lifecycle artifacts — brainstorm
  specs, plans, exec notes, reviews, and handoffs — under `/docs/superpowers/`, which
  is **gitignored** (the `replicant` convention). Keep them there.

## Next action

Start from a working feature or bugfix; TDD against the critical rules above.
