# AshReplicant — AI Agent & Contributor Guide

Critical Rules are binding; each rule's mechanism lives in the ADR it cites (`docs/adr/`). The
full pre-October 28, 2026 wording is in `docs/reference/agent-history.md`.

## What this is

An Ash `Replicant.Sink` adapter (`replicant do ... end` Spark section) owning per-row multitenancy
via `tenant:`, sensitive-attribute verification and resource resolution over the tenant-blind
`replicant` CDC framework; it re-implements neither transport nor Ash's `multitenancy` DSL.
Read `docs/CHARTER.md` next for mission, layering, scope and the effect-once model. Design work
reads the sibling `../replicant` checkout, whose `AGENTS.md` holds the logical replication
contract; `ash_postgres` comes from Hex.

## Architecture (realized)

Effect-once rests on a durable `commit_lsn` watermark checkpointed atomically with the mirrored
changes. The checkpoint is bound to the session-verified identity (system identifier, database,
slot; timeline recorded) and a contract manifest classified at every reconnect (ADR-0007). One
`AshReplicant.PipelineOwner` owns each slot's generation (ADR-0014); a dead owner's generation
fails closed. Generated internal resources (the checkpoint) are default-deny.

The same owner schedules the C01 continuous invariant census through the admitted
callback guard (never a second Replicant callback): one
jittered, bounded, monitored worker rechecks destination, live contract,
checkpoint contract/fingerprint, and full source coverage. Drift halts
immediately; timeout/unreachable/checker faults are typed non-pass results and
halt at the exact consecutive budget. The next run is scheduled only after the
current one settles. Graceful owner/application teardown drains admitted work;
a supervised lifetime guard stops workers and transport left by owner death.

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

## Build and test

This public repository runs all checks on GitHub-hosted CI runners. Nothing that compiles
or tests runs on the owner's Mac or on the build box. Covering tests for changed files and
their direct dependents run by pushing a topic commit to `kci/<topic>`, reading that run once,
and fixing failures forward. Use the commands declared in `.github/workflows/qualification.yml`;
never fall back to a local build or test.

Every workflow declares `defaults: run: shell: bash`, so command pipelines preserve failures.
Jobs inherit that default. Job-level `defaults` are refused because even a working-directory
override replaces the workflow's run defaults and drops its shell.
Shell scripts use bash and `set -euo pipefail`. Checks capture command output in a standalone
assignment before testing it; listings never reach a comparison through process substitution.
Only grep's no-match status is allowed for optional counts; command errors fail the check.
Diagnostic output on an already-failing path and cleanup remain best effort.

Land only with the landing tool, given the full SHA.
It submits a fresh `kci/<commit>` candidate and moves `main` only after `qualified` succeeds.
The landing SHA must never have been pushed to any `kci/` ref: two `qualified` checks on one
SHA make landing ambiguous. After a green topic check, make a final docs-only commit, use
that new SHA for landing. It settles after promotion itself: it deletes local and origin branches that contain the landed
commits, retires clean delegate worktrees and sweeps `kci/` refs. Exit 0 means landed and settled;
exit 4 means landed with leftovers named, so fix the cause and run its sweep.
Never push `main` directly. Workflow and release-script changes go to the infrastructure maintainers for advice; the repository's owner decides and lands them.

## Development workflow

The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash
`>= 3.38.1 and < 4.0.0-0` (current lock 3.38.1) and Replicant
`>= 1.6.0 and < 2.0.0-0` (current lock 1.6.0), plus
AshOnetime `>= 1.3.2 and < 2.0.0-0` (current lock 1.5.0) and AshCloak
`>= 0.4.0 and < 1.0.0-0` (current lock 0.4.0; releases below 0.4.0 carry
CVE-2026-81319 and CVE-2026-81322 and are not admitted). Replicant 1.4's
decoder options pass through with FULL decoder admission (ADR-0026).

Postgrex requires `~> 0.23` (current lock 0.23.0), matching Replicant 1.6.0.
DBConnection requires `>= 2.10.3 and < 3.0.0-0` (current lock 2.10.3).

The CI gates install the exact runtime, fetch with `mix deps.get --check-locked`, and run
format, compile with warnings as errors, Credo, both dependency audits, the covering tests,
Dialyzer, and docs/package checks through the route above. The `fresh-consumer` job
consumes the qualified tarball and runs fresh resolution, both audits, compile with warnings
as errors, docs, migrations, and a live CDC smoke against its own logical-WAL platform engine.
The consumer's `deps.audit --path` runs from the dev repository root, where `mix_audit`
is declared; Hex's audit runs inside the consumer. The retired local `prepush.sh` route
authorizes no build or test on the owner's Mac or build box; CI runs its collector self-tests.

The shared action compiles an unpacked consumer against the package lock. CI fetches
committed locks: `mix.lock` for current-lock cells,
`locks/exact-floors.lock` and `locks/latest-compatible.lock` for those cells.
Qualification asserts compatible versions without querying newest upstream releases.
The generated fresh tarball consumer starts without a lock and resolves its dependencies.
`drift-report.yml` runs daily or by dispatch, refuses non-default refs first, and compares
the latest-compatible lock with the newest admitted Ash, Replicant, AshOnetime, AshPostgres,
and Spark releases. It also resolves fresh within the public requirements, reports all
version changes, runs both audits, compiles, and runs the live PostgreSQL suite. Its checks
continue independently after report failures, after ref and runtime admission. It holds only
`contents: read`, uses no secret, environment or cache, and supplies no `qualified` verdict;
only a reviewed, committed lock refresh changes qualification's admitted dependencies.
Nothing compiles or tests on the owner's Mac, and this public repository uses GitHub-hosted
CI rather than the build box.

`.github/postgres.ref` is the checked platform engine reference. The single
`.github/actions/postgres` action checks the public engine digest, starts every disposable
server with password authentication, waits for TCP readiness, and logs and removes it on
every exit. `.github/postgres-lanes.json` declares compatibility majors and source roles;
`scripts/ci/postgres-lanes.sh` alone expands those declarations into matrices and the
qualification inventory in the BEAM-equipped `postgres-lanes` job. The reusable workflow
passes that inventory to the runtime-free `qualified` job as `EXPECTED_CHECKS`;
the verdict never runs the lane reader. Dependency-range cells derived from `mix.exs`,
performance, consumers, drift reporting, and decoder destinations run the engine.
Supported sources are PostgreSQL 15–19 with pgoutput or pglogical, and supported
AshPostgres destinations are PostgreSQL 16–18 (ADR-0027). The existing full-suite cells cover
PostgreSQL 15–17 on upstream images and 18 on the engine. Separate decoder sources cover 15–19
and the deprecated 9.6/12 lanes, where wal2json still runs in 1.x. Source versions below 15 and
wal2json are scheduled for removal in 2.0. Tests require the declared live major on each server.
All fixture passwords are disposable test data.

`.tool-versions` is the single checkout runtime source. Only the shared, unedited
`scripts/toolchain.sh` reads it; the local toolchain action tests the reader and exposes
its outputs. The local BEAM action installs those versions strictly, immediately refuses
an Elixir, build-suffix or full OTP mismatch through `--installed`, and installs Hex from
the shared publication action's pinned `hex-version` file.
The wrapper and checkout config use the same reader; package requirements stay in `mix.exs`.
Job timeouts follow infra's binding CI requirements linked below; each comment
names its slowest measured green run and duration. Publish has no green run yet
and uses `90 # no green run yet` until infra measures one. No workflow runs repository code from a pull
request; a maintainer qualifies a fork's change through `kci/<commit>`.

The `release-artifact` qualification job calls the shared Hex action with no publishing
identity. It builds locked package and docs archives, checks the exact files and
requirements in `.github/hex-packages.json`, and compiles the unpacked package in a
locked consumer. It builds HTML and Markdown docs once with warnings as errors and stamps
`release.json` with the package, version and qualification commit. The
`hex-hexpm-ash_replicant` artifact holds both archives and their manifest for seven days.

Infra dispatches `publish.yml` on the default branch with the full landed
`release_commit`. Every job admits both the dispatch actor and the rerun actor.
`upload` alone uses environment `publish` and OIDC. Its runtime setup executes only
the checksum-pinned shared reader and installed tools outside the Mix project.
The shared action verifies default-branch ancestry, exact-commit qualification,
the artifact, changelog stamp, version tags, public package existence and private
OTP-app version collisions. It requests a package-scoped token only when an
upload is needed and verifies revocation.

`read-back` runs outside the publish environment. It retrieves the qualification
identified by upload's run ID and manifest digest, compares both served archives
byte for byte, and requires the docs provenance to name `release_commit`.
`release-assets` retains the package, served docs and `SHA256SUMS` for seven days.
Infra creates the scoped tag `baselabs_ash_replicant-v<version>` and the GitHub
release, generating its notes from the packaged changelog. Retry an approved
hold against the same qualified archives. First publication of a package name
requires the owner's decision.

The release checker fixtures are recorded data, never fetched or executed as
an Elixir project: `recorded.lock` is replayed with `assert-dependency-version.sh
--lock PATH`, whose default is the repository root's `mix.lock`. There is no
fixture `mix.exs` or `mix.lock` and no advisory ignore for recorded data.
Fixture hygiene audits a temporary upgrade consumer that inherits the root lock
exactly as the live upgrade test does, using a locked fetch and both audits.
It shares the root's GCM-only Cloak policy and cipher source guard. Its database
URL is required only at repo initialization, so metadata audits need no service
configuration. No audit rewrites a committed lock.

The complete release battery is itemized in `CONTRIBUTING.md`; `mix quality` covers only
format, Credo, and Dialyzer. Unit tests run without a server; integration tests
(`test/integration/**`, `@moduletag :integration`) need a live logical-replication Postgres and
skip when unset. **Commit messages state what the containing run proves:**
"CI runs X" / "the lanes are green" only about a run whose tested head is that commit, and
artifact checksums name the exact tree they were built from.

## Workflow

Make the change, commit with named paths, and use the route in [Build and test](#build-and-test).
`main` moves only on that commit's `qualified` check. If it goes red, fix forward in the next commit. A version
bump (`scripts/bump-version.sh`) is an ordinary commit and lands the same way.

- A test that fails on every run is a defect: fix it, or quarantine it with a reason, in the
  change that finds it.
- Update the CHANGELOG when behavior, a dependency or a contract changes; other docs only when
  a contract changes.
- Tracked docs: root docs, `docs/` (charter, roadmap, ADRs, instruction history) and the tour
  notebook. Local-only: `graphify-out/` and each contributor's own untracked tool state.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook when
installed; gitignored). Prefer `graphify query`, `graphify explain` and `graphify path` for orientation.
Graph output is navigation, never evidence: Elixir edges are file-local only, so verify
load-bearing claims against live code. `graphify update .` refreshes it after large uncommitted
changes.

## CI/CD and releases

The infrastructure maintainers own CI/CD, the build box, releases and their keys for every
BaseLabs product, and their CI requirements bind this repository. Maintainers read the current
requirements from their default branch, not from a local checkout, and reread them whenever
they touch a workflow, a Dockerfile, a release script or a secret.

- An agent's work ends at `main`, and it lands through the landing tool and nothing else. It never
  releases, deploys, publishes, tags a version, dispatches a workflow, pushes an image by hand,
  or handles a release, publish or CI key. When something should go out, it sends the infrastructure
  maintainers one message: the repository, the full commit, what goes out, and anything they need.
- An agent writes its own workflow changes. Before landing a change to `.github/`, a Dockerfile,
  a release script or anything that touches a secret, it sends the infrastructure maintainers
  the branch and head for their advice; the repository's owner decides and lands the change.
  Any CI/CD, runner, box or key problem goes to them, not around it.
- This public repository never builds on the build box. Never list process arguments:
  no `ps` with `args` or `-f`, no `/proc/*/cmdline`; use `ps -eo pid,etimes,pcpu,comm`.
- A secret never appears on a command line, in a log or in a message. If you see one exposed,
  tell the infrastructure maintainers where it sits without copying the value.
- Messages to the infrastructure maintainers carry one result each and are complete enough to act on without a reply.
  No acknowledgements and no status notes.
- Every brief given to a child agent carries these same rules.
