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
`replicant do ... end` resource section. The sink carries config
(repo/domains/checkpoint plus, since C1, `pg_logical_emit_message` prefix
`message_routes`/`ignored_message_prefixes` — ADR-0015);
the resolver index maps `{schema,table}` → resource; effect-once is guaranteed by
a durable `commit_lsn` watermark checkpointed atomically with the mirrored changes.
Activation requires the expected PostgreSQL system identifier and database;
Replicant 1.x verifies that identity from the actual replication session before
the first checkpoint read. The durable checkpoint is additionally bound to the
actual session identity (source system, database, slot, with the session
timeline recorded and any timeline change an explicit operator decision) and
carries a canonical contract manifest classified at every reconnect under the
checkpoint lock. Each slot has one serialized runtime generation, **owned by an
`AshReplicant.PipelineOwner`** that runs activation and monitors the pipeline
(`:temporary` under the host supervisor; Replicant retains transport ownership):
when the pipeline exits the owner erases the generation, a dead owner's
generation fails closed at callback entry and is replaceable at the next
activation, and duplicate starts cannot replace or erase the live generation's
configuration ([ADR-0014](docs/adr/0014-internal-trust-and-lifecycle-ownership.md)).
Generated internal resources (the checkpoint) are **default-deny**: the policy
authorizer with an empty policy set forbids every external actor; the sink and
operator paths run `authorize?: false`.

The same owner runs the C01 continuous invariant census through the admitted
callback guard (never a second Replicant callback or lifecycle process): one
jittered, bounded, monitored worker rechecks destination, live contract,
checkpoint contract/fingerprint, and full source coverage. Drift halts
immediately; timeout/unreachable/checker faults are typed non-pass results and
halt at the exact consecutive budget. The next run is scheduled only after the
current one settles, and pipeline/owner teardown kills any in-flight worker.

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
>
> **Every append-log source table also requires `REPLICA IDENTITY FULL`.** A delete
> is an immutable event whose payload is the complete old record; DEFAULT identity
> supplies only the primary key and would silently record an incomplete event. The
> activation census enforces FULL whether or not the append resource is tenant-scoped.

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
measurement-key set — never row values (ADR-0009); the data-boundary mutation
matrix carries one mutant per typed metadata key and per measurement key, with
a completeness tripwire test, so a key whose gate is vacuous cannot ship
(ADR-0022). The moduledoc's metrics and OpenTelemetry examples are executable
(test-extracted) and the OTel mapping table is pinned complete against
`emitted_event_names/0`. All nine sink boundary bodies
(including C1's `handle_message/2`, C2's `handle_batch/1`, and C3's
`snapshot_progress/0`)
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
:destroy_prior | :upsert | :message | :mark_seen | :retire_unseen` —
ADR-0010/0015/0017; declarations stay 6-axis,
the label is appended at encode). Use `DestinationParticipant.operation_key/2`.
Reject nonce, independent, external, opaque-store, or incomplete-identity
profiles. **Message-route actions (C1 / ADR-0015)** are the one exception to
"no external effect": a sink-declared `message_routes` prefix targets a create
action carrying the closed message profile — idempotency, fail-closed store,
`key({:argument, :operation_key})`, `fingerprint(arguments: [:content_digest])`
(a versioned host-keyed HMAC over the content from
`:ash_replicant, :message_digest_keys`; the claim persists no content in any
derivable form), declared positive retention, and an OPTIONAL `external_effect`
module admitted only here (AshOnetime three-state recovery; the watermark
advances only after finalized/replayed success). A nonce never gates WAL
re-delivery. An unknown prefix at delivery halts (`:message_prefix_unmapped`). A
notifier whose load statement is non-empty must declare
`DestinationParticipant` (the `:notifier` kind) AND route the statement through
`AshReplicant.Notifier` (`preload/2`; the wrapper owns `load/2`) — its
dependency pre-load read runs inside the admitted transaction; suppression
covers dispatch only. Admission behaviorally verifies both stability probes
entered the live wrapper; retaining its behaviour marker while overriding
`load/2` is rejected. Ash re-derives that statement at delivery, so admission
BINDS it: the manifest carries each notifier's statement digest and declared
action-closure digest, the wrapper compares both before handing Ash the
statement, and the sink re-checks before each admitted action for what the
wrapper cannot see (an empty-at-admission statement turning non-empty, a
changed notifier list, a faulting load). Unwrapped, undeclared, or
irreproducible statements fail admission
(`:destination_notifier_unwrapped` / `:destination_notifier_required` /
`:destination_notifier_unstable`); drift at delivery halts value-free
(`{:invalid_destination_config, :notifier_load_drift |
:notifier_load_unadmitted | :notifier_load_probe_failed}`). Static stores preflight at activation;
context-tenant stores preflight inside the outer transaction.

Generated delivery callbacks are final and call `Sink.Impl` directly. Never add a
host-overridable effect hook. Reject `SetContext` changes/preparations that replace
`:data_layer` (a dynamic/MFA context is admissible only when its module declares
`DestinationParticipant`), and require `AshOnetime.Cache.None`; both otherwise
create effects outside the admitted action/transaction boundary.

**7. Whole-table snapshot retry is effect-once for a resource that opts in
(S02, ADR-0017).** No snapshot callback clears a resource — the pre-S02
whole-resource `DELETE` on `first_for_table?` repeated every committed host
business effect on a retry and could erase a stream-applied row. Instead, each
`PipelineOwner` activation mints a 256-bit delivery run; the first actual
`handle_snapshot/2` of that run binds it to a fresh random attempt in the
checkpoint's authenticated `snapshot_state` envelope, under the checkpoint row
lock. A `snapshot_provenance true` resource compares each row's stored
fingerprint and, on a match, invokes ONLY the private mark action — the host
business action does not re-run. Completion checks a permanent replay fence
(same delivery run + LSN) BEFORE any scan, then enumerates every destination
tenant scope and retires the managed open rows whose marker differs, through the
host retire action with `tenant:` set. Attribute tenancy enumerates its
discriminator with `SELECT DISTINCT`; `strategy :context` requires the declared
`snapshot_tenant_scope_action`; global and non-tenant resources take one scoped
pass. SCD2 retirement closes the open version only. Undecodable, tampered,
impossible, or contract-drifted state, an unknown fingerprint answer, and a
missing or malformed scope enumeration each fail CLOSED. Attempt ids, delivery
runs, fingerprints, and tenants are data-plane values: never in an error, log,
or telemetry event.

A snapshot-backed resource that does NOT opt into `snapshot_provenance` keeps
rows the source has dropped — there is no marker to retire them by. That is the
documented cost of not opting in, and it is strictly less destructive than the
wipe it replaces.

**8. A generated sink is EXCLUSIVELY a state mirror or an append log
(ADR-0018).** `use AshReplicant.Sink, sink_kind: :append_log` (default
`:state_mirror`) makes every mapped resource an immutable append target; a
mixed set fails activation (`:sink_kind_mixed`) because Replicant exposes
`sink_kind/0` per SINK, not per resource. An append sink additionally declares
`initial_state: :snapshot | :go_forward`, its ONE initial-state intent, which
must agree with the `snapshot:` start option.

The append target is HOST-owned: an AshPostgres resource in the admitted Repo
declaring `append_log true`, its structural attributes (source system, source
database, slot, commit LSN, ordinal, operation, origin, snapshot attempt), an
IMMUTABLE create action, and the append identity. Update, upsert and destroy
are never delivery paths, and `ValidateAppendLog` moves every one of those
obligations — plus the refusal of SCD2 history, snapshot provenance and the
state-mirror truncate policies — to build time.

**The append identity is exactly `(source system, database, slot, commit LSN,
ordinal)`.** Delivery upserts against it with an EMPTY `upsert_fields`, which
AshPostgres renders as a no-op conflict clause: a re-delivered WAL position
appends ONCE and never overwrites the stored payload. That unique identity is a
defensive database constraint; effect-once still rests on rule 6 — the append
and the checkpoint committing in one locked destination transaction. Payload
mapping, tenancy and sensitive-type classification are rules 1–4 unchanged; a
source column colliding with a structural attribute name halts before insert.
`on_truncate :append` records the structural truncate event (no payload) and is
admitted only on an append target with NO declared tenant source, because a
TRUNCATE is tenant-blind.

A go-forward append sink implements `handle_slot_origin/2` and writes the log's
IMMUTABLE `origin_floor` on its first admitted activation; no completeness claim
covers data below it. Later origins are resume facts — a slot CREATED this
session under an existing floor halts `:append_origin_gap`, an appended event
above the durable checkpoint halts `:append_frontier_divergent`. An append sink
cannot run INCREMENTAL snapshots (that mode requires `snapshot_provenance` on
every mapped resource, which an append target may not declare), and a
`strategy :context` append target is refused on a go-forward sink because its
per-tenant schema leaves no tenant-blind frontier to tie out against.

Message (C1), sink-owned batch (C2, `handle_batch/1` — one destination
transaction, one trailing watermark write per flushed batch, ADR-0016),
incremental snapshot progress (`snapshot_progress/0`, ADR-0017), and append-log
delivery (`sink_kind/0` + `handle_slot_origin/2`, ADR-0018) are live.

**9. The install path generates host-owned code and never guesses (I01).**
`mix ash_replicant.install` (`Mix.Tasks.AshReplicant.Install`, behind an
**optional** Igniter dependency) writes four host modules — an Ash domain, the
checkpoint resource, the sink, and an `AshReplicant.Pipeline` supervisor — then
registers the domain, supervises the pipeline, imports AshReplicant's formatter
metadata, and queues `mix ash.codegen`. It writes **no** connection, publication,
source identity, or key material, so a
fresh install compiles and boots as a no-op; the generated pipeline supervises
nothing until the operator configures it, and a present-but-incomplete
configuration RAISES (naming keys, never values) rather than supervising nothing.
Every refusal — malformed module name, illegal slot, missing/ambiguous/unknown or
non-AshPostgres repo, incomplete facts, foreign target, unreadable binding, or a
checkpoint/sink/pipeline bound to another identity — writes nothing and names
the resolving flag or structural fact. Refusal decisions live in the
Igniter-free `AshReplicant.Install` planner so each one carries a unit test; the
Mix task only gathers facts and renders. The README's "Manual installation"
block is tied to the installer's real output by a test — change one and the other
must change.

**10. The 0.4.0 to 1.0.0 upgrade never infers checkpoint ownership.**
`mix ash_replicant.upgrade 0.4.0 1.0.0` is the only generated upgrade path for
the published slot-only checkpoint. Every populated legacy row must have exactly
one operator-declared sink/source binding; dormant bindings are allowed, while
unbound, duplicate, foreign, interrupted, dynamically unreadable, or wrong-
destination state writes nothing. Dry-run and apply share the same classifier
and print only structural counts. The generated migration requires an explicit
all-node stop assertion, converts the table and writes its checksummed rollback
ledger in one locked transaction, and refuses down after any 1.0-only durable
state or watermark change. Roll the database migration back before downgrading
the package; once 1.0 state exists, restore from backup or remain on 1.0.

**11. The read-only diagnosis surface never writes, and never guesses.**
`mix ash_replicant.preflight` / `mix ash_replicant.doctor` (and their in-process
twins `AshReplicant.preflight/1` / `AshReplicant.doctor/1`) diagnose source,
slot, checkpoint, contract, retention, and runtime readiness through
`AshReplicant.Doctor`. The no-writes guarantee rests on THREE independent legs:
`Doctor.Probe.admit!/1` refuses any statement that is not provably read-only
(leading `SELECT`, no separator, no write verb, no row lock, no
session-escaping function); the probe connection carries
`default_transaction_read_only=on` so PostgreSQL refuses what admission missed;
and the destination read uses the checkpoint's `:read` action with
`authorize?: false` and NEVER a lock. Adding a statement means adding it to
`Probe.statements/1`, which the non-vacuity test admits and the live gate
executes.

The doctor is an ADAPTER over the rules activation already runs — `Coverage`,
`Identity.classify_stored_contract/3`, `Destination.manifest/1`,
`Pipeline.start_options/3`. Never re-implement a rule here: a diagnosis that
disagrees with the runtime it diagnoses is worse than none. Where a rule is
private and short-circuiting, expose a delegate to the SAME body
(`Coverage.replica_identity_check/2`, `Coverage.probe_identity_check/2`), never
a copy. Results are one canonical `%Doctor.Check{}` with a closed reason
vocabulary; `detail` is a fail-closed ALLOWLIST of reasons whose `%Error{}.shape`
is a catalog identifier, so an identity-class shape (which embeds the source
database) can never reach operator output. Anything unjudgeable is `:skipped`
with the reason it could not be judged — never `:pass`.

**12. Runtime status is one DERIVED model; tombstones are value-free and
bounded (O02, ADR-0019).** `AshReplicant.status/1` answers the closed public
five (`:healthy | :catching_up | {:halted, reason} | {:misconfigured, reason}
| :not_started`); `AshReplicant.Status.derive/2` is the six-state generation
model underneath (`:activating`, `:ready`, `:degraded`, `:halted`,
`:stopped`, `:superseded`). The answer is DERIVED, never stored: precedence
walks the live owner's own facts (a `handle_call` seam the owner answers in
BOTH pending and admitted phases — an unmatched call would kill a healthy
activation), then the generation entry (a DEAD owner is the fault
`{:halted, :owner_lost}` — never ready, never `:not_started`), then the
tombstone legs (node-local first, durable second), then nothing. Because
activation clears the node-local leg BEFORE the entry exists, a node-local
tombstone under a live or dead entry is necessarily THAT generation's own
halt/stop decision and outranks every other reading — the
healthy-while-halting window cannot open. `:healthy`
requires a live owner AND pipeline AND an enabled census whose last run passed
AND no in-flight snapshot — owner liveness alone is insufficient. A call
TIMEOUT on a live owner is `:catching_up` (the conservative bucket), not owner
loss. Tombstones record WHY a generation ended: cause atoms from the CLOSED
reason vocabulary (plus `:operator_stopped`, `:pipeline_terminated`,
`:owner_lost`, `:tombstone_unknown`), a class (`halt | misconfigured |
stopped`, fail-closed default `halt`), and a timestamp — never a row value,
prefix, or progress token; decode is closed-set with a fixed fallback and
NEVER mints atoms from persisted bytes. The durable leg lives on the checkpoint
row (`terminal_cause`/`terminal_class`/`terminal_at`), is written ONLY when the
row already exists (a tombstone never creates watermark-less rows), is cleared
by EVERY admitted checkpoint write (bind AND advance, including the
otherwise-verify-only steady-state `:equal` reconnect — a stale cause must not
outlive its successor), and is written by the party that knows the cause: the
GENERATED sink callbacks' boundary (`Status.record_callback_error/2` — every
`{:error, %Error{}}` leaving a callback halts the pipeline, so the halt
funnels AND the bind-conflict/session-identity/slot-origin paths all cross
this one home); the owner's census halt — node-local at the decision, durable
AFTER `safe_stop`; `stop_supervised` before it stops. A
tree shutdown writes nothing; an unexplained pipeline death records
`:pipeline_terminated` only when no tombstone is already present. One writer
home: `AshReplicant.Status` — never re-derive the walk in the doctor, the
owner, or a host health endpoint.

**13. Recovery horizons alert BEFORE recovery becomes impossible (O03,
ADR-0022).** A claim-backed message route's AshOnetime claim is the standalone
message's ONLY dedup, and it dies at `retain_until` — so a sink with
`message_routes` on a state-mirror sink MUST declare `recovery_horizon:
{count, unit}` (compile-required; rejected on route-less and `:append_log`
sinks, whose routes dedup structurally), and activation refuses
`:retention_below_recovery_horizon` when the manifest's minimum route
retention does not cover it. The digest-key rotation window is witnessed by the
checkpoint's authenticated `digest_key_state` envelope (under the ORTHOGONAL
`:ash_replicant, :horizon_provenance_keys` family — never the rotating digest
keys), rebound at bind AND on every census-observed key-set change (a bind-only
witness goes blind on long-lived connections); a version removed within
`max(route retention)` of the last observation containing it is
`:digest_key_horizon_violated`, tampered/impossible state is
`:digest_key_state_invalid` (both fail closed). The WAL side has three alert
legs: the census classifies slot facts through `Doctor.Probe.probe_slot/2` (the
ONE extended `sql_replication_slot/0` statement — `lost` drifts
`:source_wal_lost`; `unreserved`/exhausted emits
`[:ash_replicant, :retention, :at_risk]` — META ONLY, no measurement — and
continues); a resume after a halt longer than the minimum retention while WAL
is retained refuses `:retention_horizon_crossed` (never block on an
unreachable probe; a lost slot defers to the stream's own failure); and the
doctor's `:retention_horizon` check DELEGATES to `AshReplicant.Horizon` — the
one classification body (rule 11: no copies). While halted nothing in the
library watches the clock — the doctor on the operator's scheduler is the
documented pull channel.

## Development workflow

The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash
`>= 3.31.3 and < 4.0.0-0` and Replicant
`>= 1.2.3 and < 2.0.0-0` (current release-candidate lock 1.2.3), plus
AshOnetime `>= 1.1.0 and < 2.0.0-0` (current lock 1.2.1).

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
release-contract tests, and the data-boundary guard-mutation gates
(`scripts/run-mutation-gates.py`, ADR-0003 — one guard removed, or one notifier
guard moved after its first effect, at a time in an isolated project copy must
turn its named no-database focused test red) listed
in `CONTRIBUTING.md`. `mix quality` covers only
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
  (`docs/CHARTER.md`), `docs/ROADMAP.md`, the ADR corpus (`docs/adr/`), the
  historical implementation handoffs (`docs/handoffs/`), and the guided tour
  notebook (`notebooks/ash_replicant_tour.livemd`).
- **Never tracked (local-only):** the superpowers lifecycle artifacts — brainstorm
  specs, plans, exec notes, reviews, and handoffs — under `/docs/superpowers/`,
  plus the tool-state directories `.forge/`, `.kimosabe/`, and `graphify-out/`;
  all are **gitignored** (the `replicant` convention). Keep them there.

## Next action

Start from a working feature or bugfix; TDD against the critical rules above.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook when that hook is installed — not on a fresh clone; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
