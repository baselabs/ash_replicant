# AshReplicant — AI Agent & Contributor Guide

How to work effectively in this repo. This file is the *how*; its Critical Rules are binding.
The *what & why* is tracked at `docs/CHARTER.md`; every decision the rules rest on has an ADR
in `docs/adr/`.

## What this is

An Ash `Replicant.Sink` adapter — the "`ash_postgres` of `replicant`" — a `Spark.Dsl.Extension`
exposing a `replicant do ... end` resource section. It owns the Ash-native mechanism (per-row
multitenancy via the `tenant:` action option, sensitive-attribute verification, resource
resolution) and executes through the tenant-blind `replicant` CDC framework; it does NOT own
transport and does NOT re-implement Ash's `multitenancy` DSL. See Architecture below.

## Architecture (realized)

Effect-once is guaranteed by a durable `commit_lsn` watermark checkpointed atomically with
the mirrored changes. Activation requires the expected PostgreSQL system identifier and
database; Replicant 1.x verifies that identity from the actual replication session before
the first checkpoint read. The durable checkpoint is bound to the actual session identity
(source system, database, slot, with the session timeline recorded and any timeline change
an explicit operator decision) and carries a canonical contract manifest classified at every
reconnect under the checkpoint lock (ADR-0007). Each slot has one serialized runtime
generation, **owned by an `AshReplicant.PipelineOwner`** that runs activation and monitors
the pipeline (`:temporary` under the host supervisor; Replicant retains transport ownership):
when the pipeline exits the owner erases the generation, a dead owner's generation fails
closed at callback entry and is replaceable at the next activation, and duplicate starts
cannot replace or erase the live generation's configuration (ADR-0014). Generated internal
resources (the checkpoint) are **default-deny**: the policy authorizer with an empty policy
set forbids every external actor; the sink and operator paths run `authorize?: false`.

The same owner runs the C01 continuous invariant census through the admitted
callback guard (never a second Replicant callback or lifecycle process): one
jittered, bounded, monitored worker rechecks destination, live contract,
checkpoint contract/fingerprint, and full source coverage. Drift halts
immediately; timeout/unreachable/checker faults are typed non-pass results and
halt at the exact consecutive budget. The next run is scheduled only after the
current one settles, and pipeline/owner teardown kills any in-flight worker.

## Critical rules

**1. Route writes through Ash actions, never raw Ecto.** The host resource's OWN primary
`:create` (used as the upsert) and `:destroy` action carry AshCloak encryption and multitenancy
scoping — the extension generates NEITHER; the sink writes through them with `authorize?: false`
(AshCloak and tenancy still fire; policies are not re-gated). Direct Ecto is a data-loss /
classification / encryption failure vector. An SCD2 mirror keeps the rule: the version close
routes through the host `history_close_action` via tenant-scoped `Ash.bulk_update`, the new
version opens through the `:create` upsert, and the ONLY raw SQL is `on_truncate :close` — a
tenant-blind, window-columns-only `UPDATE` (quoted idents, parameterized values, DSL-sourced
names, never a row value), the same trust boundary as the `:mirror` truncate `DELETE` (ADR-0010).

**2. Multitenancy is fail-closed.** A nil/`false`/blank tenant on a multitenant resource fails
closed — no query runs (`false` too: Ash treats a falsy tenant as unscoped). `tenant_attribute`
or `tenant_mfa` resolves the per-row tenant, passed as `tenant:` so `Ash.Changeset` scopes every
row write; a resolution failure rolls the transaction back. Compile-time verifiers (ADR-0001):
`ValidateTenantSource` requires a tenant source on every non-global Ash-multitenant resource;
`ValidateMultitenancy` requires an Ash `multitenancy` block whenever either source is declared
(without one, Ash silently ignores `tenant:` and mirrors unscoped; any strategy, incl. `global?`,
satisfies it) and requires a `strategy :attribute` discriminator to be plaintext, non-sensitive,
non-binary; `ValidateActionMultitenancy` rejects `multitenancy :bypass`/`:bypass_all` on any
sink-selected action (including the `bulk_update`/`bulk_destroy` row match). Operational
requirements — activation preflight enforces them and the census re-checks them (ADR-0008):

- **Tenant-scoped source tables must be `REPLICA IDENTITY FULL`** — a delete, PK-changing, or
  tenant-reassigning update derives the old tenant from `old_record`, which under DEFAULT
  identity carries only the PK columns, so resolution halts fail-closed (`:tenant_required`,
  never a base-tenant delete). A `tenant_mfa` must resolve from both record shapes; an absent,
  blank, or raising old-side resolution is a structural halt (`:tenant_required` /
  `:tenant_resolution_failed`) before any write. Non-tenant mirrors work under DEFAULT identity.
- **SCD2 resources whose `history_business_key` is not the source primary key** also require
  FULL (the close reads the business key from `old_record`).
- **Every append-log source table requires FULL** — a delete's payload is the complete old
  record; DEFAULT identity would silently record an incomplete event, tenant-scoped or not.

**3. Sensitive = AshCloak-encrypted or binary, verified by type-shape.** Sensitive attrs must
map to an AshCloak-encrypted attribute (the durable `before_action` fires on upsert), a
binary-storage-typed attribute (app-side encryption), or `skip`. The verifier checks type shape,
never ciphertext — encryption is the host app's job. AshCloak is the single source of truth (no
hand-rolled path). Never list the `tenant_attribute` as `sensitive` (ADR-0013).

**4. Value-free — no row value in any error, log, or telemetry event, including the halt
path.** Assume every value is PII or a secret. Errors are scrubbed to a structural reason
(operator + field) before Ash inspects them; column names are strings, never atoms. Telemetry
metadata is allowlisted AND typed per key with a closed measurement-key set (ADR-0009); the
mutation matrix carries a mutant per typed metadata and measurement key with a completeness
tripwire (ADR-0022); the moduledoc's metrics/OTel examples are executable and the OTel mapping
is pinned complete against `emitted_event_names/0` (ADR-0011). All TEN sink boundary bodies —
including `handle_message/2`, `handle_batch/1`, `snapshot_progress/0`, and `handle_slot_origin/2`
— catch `:throw`/`:exit` into the same scrub; the schema-change body fires the sink's own
`:halted` with the structural reason (never the sibling's `:decode_failure` mislabel). Raw-SQL
identifiers route through the ONE quoting home, which rejects control characters at admission.
Failures carry a cause, never the offending value.

**5. Stay one layer up: tenant-blind.** The `replicant` sibling is tenant-blind and
classification-blind by design. Never add tenant resolution or row classification to
`replicant`; never import `ash_replicant` in `replicant`. The split is verified by separate
repos and separate test fixtures.

**6. Effect-once = one admitted destination graph, one transaction, watermark dedup.** Build
the recursive destination manifest before delivery — framework relationships plus
`AshReplicant.DestinationParticipant` declarations, exact `touches_resources` tie-out, every
resource on `AshPostgres.DataLayer`, the sink's literal Repo, and that Repo's admitted
effective dynamic identity; callable, foreign, non-Postgres, missing, opaque, cyclic, or
mismatched participants fail before effects. A declaration is trusted metadata, not proof of
an arbitrary body; it never authorizes raw SQL, another Repo, asynchronous work, or external
effects. Apply each committed streaming transaction in ONE `Repo.transaction` while the
per-slot generation lease is held through commit/rollback; skip any change whose
`commit_lsn <= checkpoint` of the source-bound checkpoint row — session-bound (system
identifier, database, slot, timeline recorded), `FOR UPDATE`-locked, monotonic — then apply
through the admitted action graph and upsert the checkpoint in the same transaction. A failure
rolls back every mapped row, auxiliary effect, AshOnetime claim/response, and checkpoint;
un-acked WAL re-streams and dedups on resume (ADR-0006/0007).

AshOnetime is permitted only for an admitted local auxiliary action: `:idempotency` with
`:with_action`, fail-closed storage in the same Repo, no external effect, a private non-null
`operation_key`, the exact versioned source-system/database/slot/commit-LSN/ordinal/participant
identity plus the SINK-MINTED per-invocation label — nine labels: `:close_prior | :close_current
| :open | :destroy_prior | :upsert | :message | :mark_seen | :retire_unseen | :append`
(ADR-0010/0015/0017/0018; use `DestinationParticipant.operation_key/2`). Reject nonce, independent, external,
opaque-store, or incomplete-identity profiles. **Message-route actions
(C1, ADR-0015)** are the one external-effect exception — a `message_routes` prefix targets a
create action carrying the closed message profile (idempotency, fail-closed store,
`key({:argument, :operation_key})`, `fingerprint(arguments: [:content_digest])` as a versioned
host-keyed HMAC from `:ash_replicant, :message_digest_keys` persisting no derivable content,
declared positive retention, optional three-state-recovery `external_effect`; the watermark
advances only after finalized/replayed success). A nonce never gates WAL re-delivery; an unknown
prefix halts `:message_prefix_unmapped`.

A notifier with a non-empty load statement must declare `DestinationParticipant` (the `:notifier`
kind) AND route it through `AshReplicant.Notifier` (`preload/2`; the wrapper owns `load/2`);
admission BINDS the statement (statement + action-closure digests in the manifest, behavioral
stability probes, value-free drift halts — `:destination_notifier_unwrapped` /
`:destination_notifier_required` / `:destination_notifier_unstable`,
`{:invalid_destination_config, :notifier_load_drift | :notifier_load_unadmitted |
:notifier_load_probe_failed}`). Generated callbacks are final and call `Sink.Impl` directly — no
host-overridable effect hook; reject `SetContext` that replaces `:data_layer` (a dynamic/MFA
context only when its module declares `DestinationParticipant`) and require
`AshOnetime.Cache.None`.

**7. Whole-table snapshot retry is effect-once for a resource that opts in (S02, ADR-0017).**
No snapshot callback clears a resource (the pre-S02 whole-resource `DELETE` could erase a
stream-applied row). Each activation mints a 256-bit delivery run; the first `handle_snapshot/2`
binds a fresh random attempt in the checkpoint's authenticated `snapshot_state` envelope under
the row lock. A `snapshot_provenance true` resource compares stored fingerprints and, on a
match, invokes ONLY the private mark action — the host business action does not re-run.
Completion checks the permanent replay fence (same delivery run + LSN) BEFORE any scan, then
enumerates every destination tenant scope and retires managed open rows whose marker differs,
through the host retire action with `tenant:` set (`SELECT DISTINCT` for attribute tenancy; the
declared `snapshot_tenant_scope_action` for `strategy :context`; one scoped pass for
global/non-tenant; SCD2 closes the open version only). Undecodable, tampered, impossible, or
contract-drifted state, an unknown fingerprint answer, and a missing or malformed scope
enumeration each fail CLOSED; attempt ids, delivery runs, fingerprints, and tenants never reach
an error, log, or telemetry event. A snapshot-backed resource that does NOT opt into `snapshot_provenance` keeps
rows the source has dropped — no marker exists to retire them by. That is the documented cost
of not opting in, and it is strictly less destructive than the wipe it replaces.

**8. A generated sink is EXCLUSIVELY a state mirror or an append log (ADR-0018).** `use
AshReplicant.Sink, sink_kind: :append_log` (default `:state_mirror`) makes every mapped resource
an immutable append target; a mixed set fails activation (`:sink_kind_mixed`; `sink_kind/0` is
per SINK). An append sink declares `initial_state: :snapshot | :go_forward`, which must agree
with the `snapshot:` start option. The append target is HOST-owned: an AshPostgres resource
declaring `append_log true`, its structural attributes (source system, database, slot, commit
LSN, ordinal, operation, origin, snapshot attempt), an IMMUTABLE create action, and the append
identity — update, upsert, and destroy are never delivery paths (`ValidateAppendLog` moves every
obligation, plus the refusal of SCD2 history, snapshot provenance, and state-mirror truncate
policies, to build time). **The append identity is exactly `(source system, database, slot,
commit LSN, ordinal)`**, upserted with an EMPTY `upsert_fields` (a no-op conflict clause: a
re-delivered WAL position appends ONCE, never overwrites) — a defensive constraint; effect-once
still rests on rule 6. Rules 1–4 apply unchanged; a source column colliding with a structural
attribute name halts before insert; `on_truncate :append` records the structural truncate event
(no payload) only on an append target with NO declared tenant source. A go-forward sink
implements `handle_slot_origin/2` and writes the IMMUTABLE `origin_floor` at its first admitted
activation — no completeness claim
covers data below it; a slot CREATED this session under an existing floor halts
`:append_origin_gap`; an event above the durable checkpoint halts `:append_frontier_divergent`;
it cannot run INCREMENTAL snapshots (that mode requires `snapshot_provenance` on every mapped
resource, which an append target may not declare), and a `strategy :context` append target is
refused (no tenant-blind frontier). Message (C1), sink-owned batch (`handle_batch/1`, ADR-0016),
incremental snapshot progress (`snapshot_progress/0`, ADR-0017), and append-log
delivery (`sink_kind/0` + `handle_slot_origin/2`, ADR-0018) are live.

**9. The install path generates host-owned code and never guesses (ADR-0024).** `mix
ash_replicant.install` writes four host modules (domain, checkpoint resource, sink,
`AshReplicant.Pipeline` supervisor), registers the domain, supervises the pipeline, imports
formatter metadata, and queues `mix ash.codegen` — and writes NO connection, publication,
source-identity, or key material: a fresh install compiles and boots as a no-op, and a
present-but-incomplete configuration RAISES (naming keys, never values). Every refusal writes
nothing and names the resolving flag or structural fact; refusals live in the Igniter-free
`AshReplicant.Install` planner, each with a unit test. The README's "Manual installation" block
is test-tied to the installer's real output — change one, change the other.

**10. The 0.4.0 to 1.0.0 upgrade never infers checkpoint ownership.** `mix ash_replicant.upgrade
0.4.0 1.0.0` is the only generated upgrade path for the published slot-only checkpoint
(ADR-0007). Every populated legacy row must have exactly one operator-declared sink/source
binding (dormant bindings allowed); unbound, duplicate, foreign, interrupted, dynamically
unreadable, or wrong-destination state writes nothing. Dry-run and apply share one classifier
and print only structural counts. The generated migration requires an explicit all-node stop
assertion, converts the table and writes its checksummed rollback ledger in one locked
transaction, and refuses down after any 1.0-only durable state or watermark change — roll the
migration back before downgrading; once 1.0 state exists, restore from backup or remain on 1.0.

**11. The read-only diagnosis surface never writes, and never guesses (ADR-0025).**
`mix ash_replicant.preflight` / `mix ash_replicant.doctor` (and `AshReplicant.preflight/1` /
`AshReplicant.doctor/1`) diagnose through `AshReplicant.Doctor` on THREE independent no-writes
legs: `Doctor.Probe.admit!/1` admits only provably read-only statements; the probe connection
carries `default_transaction_read_only=on`; the destination read uses the checkpoint's `:read`
action with `authorize?: false` and NEVER a lock. New statements join `Probe.statements/1`
(non-vacuity test + live gate). The doctor is an ADAPTER over the rules activation already
runs — delegates to the SAME body, never a copy (a diagnosis that disagrees with the runtime it
diagnoses is worse than none). Results are one canonical `%Doctor.Check{}` with a closed reason
vocabulary and a fail-closed allowlist of `detail` reason shapes; anything unjudgeable is
`:skipped` with its reason — never `:pass`.

**12. Runtime status is one DERIVED model; tombstones are value-free and bounded (O02,
ADR-0019).** `AshReplicant.status/1` answers the closed public five (`:healthy | :catching_up |
{:halted, reason} | {:misconfigured, reason} | :not_started`); `Status.derive/2` is the six-state
model underneath (`:activating | :ready | :degraded | :halted | :stopped | :superseded`). The
answer is DERIVED, never stored: precedence walks the live owner's own facts (a `handle_call`
seam the owner answers in BOTH pending and admitted phases), then the generation entry (a DEAD
owner is `{:halted, :owner_lost}`), then the tombstone legs (node-local first, durable second)
— activation clears the node-local leg BEFORE the entry exists, so a node-local tombstone under
a live or dead entry is necessarily THAT generation's own halt/stop decision and outranks every
other reading; the healthy-while-halting window cannot open. `:healthy` requires a live owner
AND pipeline AND an enabled, last-run-passed census AND no in-flight snapshot; a call TIMEOUT
on a live owner is `:catching_up`. Tombstones
carry cause atoms from the CLOSED reason vocabulary (plus `:operator_stopped`,
`:pipeline_terminated`, `:owner_lost`, `:tombstone_unknown`), a class (`halt | misconfigured |
stopped`, fail-closed default `halt`), and a timestamp — never a row value, prefix, or progress
token; decode is closed-set
and never mints atoms from persisted bytes. The durable leg on the checkpoint row is written
only when the row exists, cleared by EVERY admitted checkpoint write (bind AND advance,
including the otherwise-verify-only steady-state `:equal` reconnect), and written only by the
party that knows the cause — the callbacks' one boundary funnel
(`Status.record_callback_error/2`), the owner's census halt (node-local at the decision,
durable after `safe_stop`), and `stop_supervised` before it stops. A tree shutdown writes
nothing; an unexplained pipeline death records `:pipeline_terminated` only when no tombstone
is already present. One writer home: `AshReplicant.Status` — never re-derive the walk in the
doctor, the owner, or a host health endpoint.

**13. Recovery horizons alert BEFORE recovery becomes impossible (O03, ADR-0022).** A
claim-backed message route's AshOnetime claim is the standalone message's ONLY dedup and dies
at `retain_until` — a state-mirror sink with `message_routes` MUST declare `recovery_horizon:
{count, unit}` (compile-required; rejected on route-less and `:append_log` sinks), and
activation refuses `:retention_below_recovery_horizon`. The digest-key rotation window is
witnessed by the checkpoint's authenticated `digest_key_state` envelope (the orthogonal
`:ash_replicant, :horizon_provenance_keys` family; rebound at bind and on every census-observed
key-set change; violations fail closed: `:digest_key_horizon_violated` /
`:digest_key_state_invalid`). Three WAL alert legs: the census classifies slot facts through
`Doctor.Probe.probe_slot/2` (`lost` drifts `:source_wal_lost`; `unreserved`/exhausted emits
`[:ash_replicant, :retention, :at_risk]`, META ONLY); a resume after a halt longer than the
minimum retention while WAL is retained refuses `:retention_horizon_crossed`; the doctor's
`:retention_horizon` check DELEGATES to `AshReplicant.Horizon` — the one classification body.
While halted nothing watches the clock — the doctor on the operator's scheduler is the pull
channel.

## Development workflow

The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash
`>= 3.33.11 and < 4.0.0-0` and Replicant
`>= 1.4.0 and < 2.0.0-0` (current lock 1.4.1), plus
AshOnetime `>= 1.3.2 and < 2.0.0-0` (current lock 1.4.0) and AshCloak
`>= 0.4.0 and < 1.0.0-0` (current lock 0.4.0; releases below 0.4.0 carry
CVE-2026-81319 and CVE-2026-81322 and are not admitted). Replicant 1.4's
decoder options pass through with FULL decoder admission —
pgoutput/pglogical/wal2json, the plugin decoders live-tested on PostgreSQL
9.6 and 12 (ADR-0026).

```bash
asdf install
scripts/with-release-runtime.sh scripts/assert-runtime-version.sh
scripts/with-release-runtime.sh mix deps.get
set -a; . ./.env; set +a    # loads ASH_REPLICANT_TEST_URL from the gitignored .env (live lane)
scripts/prepush.sh          # the local fail-fast chain: every CI gate except the mutation
                            # gates, integration discovery, and the performance lane (see CONTRIBUTING)
```

The complete release battery (live integration, integration discovery, resource-snapshot
drift, checker self-tests, release-contract tests, and the data-boundary guard-mutation gates
of ADR-0003 — `scripts/run-mutation-gates.py`) is itemized in `CONTRIBUTING.md`. `mix quality`
covers only format, Credo, and Dialyzer. Record changes under `[Unreleased]` in `CHANGELOG.md`.
**Unit** tests (`test/*_test.exs`) run without a server; **integration** tests
(`test/integration/**`, `@moduletag :integration`) require a live logical-replication Postgres,
gate on environment setup, and skip when unset. TDD: test first.

**Commit messages state what the containing run proves, nothing more** (law, 2026-10-02 —
bab4107 claimed "new CI cells run the lanes" while those lanes were red as merged, and
9aba665's message carried a checksum from a tree the release then superseded). A commit
message may say "CI runs X" / "the lanes are green" ONLY about a CI run whose tested head IS
that commit's bytes: a red run, a cancelled run, a superseded run, or a run of a LATER commit
receipts nothing, and an unpushed commit has no run at all. Artifact claims (package
checksums, published bytes) name the exact tree they were built from — a checksum from a
superseded tree is a stale record, not a release fact.

## Docs & lifecycle-artifact policy

- **Tracked/published:** `AGENTS.md`, `CLAUDE.md`, `README.md`, `CHANGELOG.md`,
  `CONTRIBUTING.md`, `usage-rules.md`, `LICENSE`, `NOTICE`, `docs/CHARTER.md`, `docs/ROADMAP.md`,
  `docs/adr/`, the historical handoffs (`docs/handoffs/`), and the tour notebook
  (`notebooks/ash_replicant_tour.livemd`).
- **Local-only (gitignored tool state):** `.kimosabe/` and `graphify-out/`.

## Next action

Start from a working feature or bugfix; TDD against the critical rules above.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook
when installed — not on a fresh clone; gitignored). Prefer `graphify query|explain|path` over
grep/Read fan-outs for orientation. Graph output is NAVIGATION, never evidence: edges reflect
the last build, and Elixir file-local call edges miss alias-mediated calls — load-bearing
claims verify against live code (grep + file:line). `graphify update .` refreshes it after
large uncommitted changes.
