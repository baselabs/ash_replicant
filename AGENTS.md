# AshReplicant — AI Agent & Contributor Guide

Critical Rules are binding; each rule's mechanism lives in the ADR it cites (`docs/adr/`). The
full pre-October 28, 2026 wording is in `docs/reference/agent-history.md`.

## What this is

An Ash `Replicant.Sink` adapter (`replicant do ... end` Spark section) owning per-row multitenancy
via `tenant:`, sensitive-attribute verification and resource resolution over the tenant-blind
`replicant` CDC framework; it re-implements neither transport nor Ash's `multitenancy` DSL.

## Architecture (realized)

Effect-once rests on a durable `commit_lsn` watermark checkpointed atomically with the mirrored
changes. The checkpoint is bound to the session-verified identity (system identifier, database,
slot; timeline recorded) and a contract manifest classified at every reconnect (ADR-0007). One
`AshReplicant.PipelineOwner` owns each slot's generation (ADR-0014); a dead owner's generation
fails closed. Generated internal resources (the checkpoint) are default-deny.

The same owner runs the C01 continuous invariant census through the admitted
callback guard (never a second Replicant callback or lifecycle process): one
jittered, bounded, monitored worker rechecks destination, live contract,
checkpoint contract/fingerprint, and full source coverage. Drift halts
immediately; timeout/unreachable/checker faults are typed non-pass results and
halt at the exact consecutive budget. The next run is scheduled only after the
current one settles, and pipeline/owner teardown kills any in-flight worker.

## Critical rules

**1. Route writes through Ash actions, never raw Ecto.** The sink writes through the host
resource's own primary `:create` (as upsert) and `:destroy` with `authorize?: false`, so AshCloak
and tenancy still fire; the extension generates neither. SCD2 closes route through the host
`history_close_action` (tenant-scoped `Ash.bulk_update`). The only raw SQL is `on_truncate
:close` and the `:mirror` truncate `DELETE`: tenant-blind, quoted idents, parameterized values,
DSL-sourced names, never a row value (ADR-0010).

**2. Multitenancy is fail-closed.** A nil/`false`/blank tenant on a multitenant resource fails
closed — no query runs. `tenant_attribute` or `tenant_mfa` resolves the per-row tenant, passed as
`tenant:`; a resolution failure rolls the transaction back. Verifiers (ADR-0001):
`ValidateTenantSource`; `ValidateMultitenancy` (an Ash `multitenancy` block whenever a source is
declared, and a plaintext, non-sensitive, non-binary `:attribute` discriminator);
`ValidateActionMultitenancy` (no `:bypass`/`:bypass_all` on any sink-selected action).
Operational requirements — activation preflight enforces them and the census re-checks them
(ADR-0008): tenant-scoped source tables, SCD2 resources whose `history_business_key` is not the
source primary key, and every append-log source table must be `REPLICA IDENTITY FULL`; an
absent, blank or raising old-side tenant resolution halts (`:tenant_required` /
`:tenant_resolution_failed`) before any write, never a base-tenant delete.

**3. Sensitive = AshCloak-encrypted or binary, verified by type-shape.** Sensitive attrs map to
an AshCloak-encrypted attribute, a binary-storage-typed attribute, or `skip`. The verifier checks
type shape, never ciphertext; AshCloak is the single source of truth. Never list the
`tenant_attribute` as `sensitive` (ADR-0013).

**4. Value-free — no row value in any error, log, or telemetry event, including the halt
path.** Errors scrub to a structural reason (operator + field) before Ash inspects them; column
names are strings, never atoms. Telemetry metadata is allowlisted and typed per key with a
closed measurement-key set (ADR-0009), each key carrying a mutant in the mutation matrix
(ADR-0022); the OTel mapping is pinned complete against `emitted_event_names/0` (ADR-0011). All
ten sink boundary bodies catch `:throw`/`:exit` into the same scrub. Raw-SQL identifiers route
through the ONE quoting home, which rejects control characters.

**5. Stay one layer up: tenant-blind.** Never add tenant resolution or row classification to
the tenant-blind `replicant`, and never import `ash_replicant` there.

**6. Effect-once = one admitted destination graph, one transaction, watermark dedup.** Build
the recursive destination manifest before delivery (framework relationships plus
`AshReplicant.DestinationParticipant` declarations, exact `touches_resources` tie-out, every
resource on `AshPostgres.DataLayer` with the sink's literal Repo and its admitted dynamic
identity); any other participant fails before effects. A declaration is trusted metadata, not
proof of an arbitrary body; it never authorizes raw SQL, another Repo, async work, or external
effects. Apply each committed transaction in ONE `Repo.transaction` under the per-slot lease;
skip any change whose `commit_lsn <= checkpoint` of the source-bound checkpoint row
(`FOR UPDATE`-locked, monotonic) and upsert the checkpoint in the same transaction. A failure
rolls everything back; un-acked WAL re-streams and dedups on resume (ADR-0006/0007).

AshOnetime is permitted only for an admitted local auxiliary action: `:idempotency` with
`:with_action`, fail-closed storage in the same Repo, no external effect, and a private non-null
`operation_key` carrying the full source identity plus the sink-minted per-invocation label
(`DestinationParticipant.operation_key/2`; ADR-0010/0015/0017/0018).
Reject nonce, independent, external, opaque-store, or incomplete-identity profiles.
Message routes (C1, ADR-0015) are the one external-effect exception: host-keyed HMAC digest
(`:ash_replicant, :message_digest_keys`), declared retention, watermark after finalized success;
an unknown prefix halts. A loading notifier declares `DestinationParticipant` AND routes through
`AshReplicant.Notifier`; drift halts value-free (`:destination_notifier_unwrapped`,
`:notifier_load_drift`). Callbacks are final; no `:data_layer`-replacing `SetContext`;
require `AshOnetime.Cache.None`.

**7. Whole-table snapshot retry is effect-once for a resource that opts in (S02, ADR-0017).**
No snapshot callback clears a resource. Each activation mints a delivery run and binds a fresh
attempt in the checkpoint's authenticated `snapshot_state`; on a fingerprint match a
`snapshot_provenance true` resource runs ONLY the private mark action, and completion (after the
replay fence) retires managed open rows whose marker differs through the host retire action with
`tenant:` set, per tenant scope. Undecodable, tampered, drifted or unknown state fails CLOSED;
attempt ids, runs, fingerprints and tenants never reach an error, log, or telemetry event.
A snapshot-backed resource that does NOT opt into `snapshot_provenance` keeps
rows the source has dropped — the documented cost of not opting in.

**8. A generated sink is EXCLUSIVELY a state mirror or an append log (ADR-0018).**
`sink_kind: :append_log` (default `:state_mirror`) applies per SINK; a mixed set fails
activation (`:sink_kind_mixed`). The append target is host-owned and immutable (create only;
`ValidateAppendLog` moves every obligation to build time); the append identity is exactly
`(source system, database, slot, commit LSN, ordinal)` with an empty `upsert_fields`; rules
1–4 and 6 apply; no INCREMENTAL snapshots or `:context` targets. A go-forward sink writes
the immutable `origin_floor` at first admitted activation — no completeness claim
covers data below it; gaps and divergence halt (`:append_origin_gap`,
`:append_frontier_divergent`). Message (C1), sink-owned batch (`handle_batch/1`, ADR-0016),
incremental snapshot progress (`snapshot_progress/0`, ADR-0017), and append-log
delivery (`sink_kind/0` + `handle_slot_origin/2`, ADR-0018) are live.

**9. The install path generates host-owned code and never guesses (ADR-0024).**
`mix ash_replicant.install` writes four host modules and NO connection, publication,
source-identity or key material: a fresh install boots as a no-op, and an incomplete
configuration raises (naming keys, never values); every refusal writes nothing. The README's
"Manual installation" block is test-tied to the installer output.

**10. The 0.4.0 to 1.0.0 upgrade never infers checkpoint ownership.** `mix ash_replicant.upgrade
0.4.0 1.0.0` (ADR-0007) requires exactly one operator-declared binding per populated legacy row;
anything else writes nothing. The generated migration requires an all-node stop assertion,
converts the table and writes its checksummed rollback ledger in one locked transaction, and
refuses down after any 1.0-only state; once 1.0 state exists, restore from backup or remain on 1.0.

**11. The read-only diagnosis surface never writes, and never guesses (ADR-0025).**
`mix ash_replicant.preflight` / `mix ash_replicant.doctor` (and `AshReplicant.preflight/1` /
`AshReplicant.doctor/1`) run on three no-writes legs: `Doctor.Probe.admit!/1` admits only
read-only statements, the probe connection sets `default_transaction_read_only=on`, and the
destination read never locks. The doctor delegates to the same body activation runs, never a
copy; anything unjudgeable is `:skipped`, never `:pass`.

**12. Runtime status is one DERIVED model; tombstones are value-free and bounded (O02,
ADR-0019).** `AshReplicant.status/1` is derived, never stored; tombstones carry closed-vocabulary
causes, never a row value, and decode never mints atoms. One writer home: `AshReplicant.Status`.

**13. Recovery horizons alert BEFORE recovery becomes impossible (O03, ADR-0022).** A sink
with `message_routes` MUST declare `recovery_horizon:`; digest-key state fails closed; WAL loss,
at-risk retention and crossed horizons alert or refuse; `AshReplicant.Horizon` is the one
classification body.

## Development workflow

The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash
`>= 3.34.6 and < 4.0.0-0` (current lock 3.34.6) and Replicant
`>= 1.4.0 and < 2.0.0-0` (current lock 1.4.2), plus
AshOnetime `>= 1.3.2 and < 2.0.0-0` (current lock 1.5.0) and AshCloak
`>= 0.4.0 and < 1.0.0-0` (current lock 0.4.0; releases below 0.4.0 carry
CVE-2026-81319 and CVE-2026-81322 and are not admitted). Replicant 1.4's
decoder options pass through with FULL decoder admission (ADR-0026).

```bash
asdf install
scripts/with-release-runtime.sh scripts/assert-runtime-version.sh
scripts/with-release-runtime.sh mix deps.get
set -a; . ./.env; set +a    # loads ASH_REPLICANT_TEST_URL from the gitignored .env (live lane)
scripts/prepush.sh          # the declared local gate: every CI gate except mutation gates,
                            # integration discovery and the performance lane
```

The complete release battery is itemized in `CONTRIBUTING.md`; `mix quality` covers only
format, Credo, and Dialyzer. Unit tests run without a server; integration tests
(`test/integration/**`, `@moduletag :integration`) need a live logical-replication Postgres and
skip when unset. **Commit messages state what the containing run proves** (law, 2026-10-02):
"CI runs X" / "the lanes are green" only about a run whose tested head is that commit, and
artifact checksums name the exact tree they were built from.

## Workflow (owner ruling, October 28, 2026)

Process is sized to the risk of the specific change, never the repository. Each check, gate,
record or review names the failure it prevents.

- **Heavy** when the diff touches delivery and the watermark (`sink*`, `apply*`, `checkpoint*`,
  `append.ex`, `pipeline_owner.ex`), destination admission (`destination*`, `notifier.ex`,
  `messages.ex`), tenancy and sensitive verification (`resolver.ex`, `resource/verifiers/`),
  the scrub, telemetry allowlist or quoting home (`error.ex`, `telemetry.ex`, `sql.ex`),
  status and horizons (`status.ex`, `horizon*`), the doctor probe (`doctor/probe.ex`), the
  upgrade migration (`upgrade*`), or a dependency floor above. Write the failing test first, get
  one independent review and do one fix round, and run the declared local gate once before
  pushing. Heavy pushes need the owner's approval.
- **Light** for everything else: focused checks on the changed behavior, then push; hosted CI
  is the gate. No outcome record, gauge or review; the commit message is the record. A light
  change the owner asked for lands without a separate push approval.
- Publishing, deploying and pushes to mirrors always need the owner's approval for that action.
- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update the CHANGELOG when behavior, a dependency or a contract changes; other docs only when
  a contract changes.
- `main` is protected by a ruleset (pull request plus required checks); land through a PR.
- Tracked docs: root docs, `docs/` (charter, roadmap, ADRs, historical handoffs, instruction
  history) and the tour notebook. Local-only: `.kimosabe/`, `graphify-out/`.
