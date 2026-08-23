# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Coherent runtime status and lifecycle tombstones** (roadmap D3-status /
  issue #12 / ADR-0019). `AshReplicant.status/1` answers with the closed
  five-value contract `:healthy | :catching_up | {:halted, reason} |
  {:misconfigured, reason} | :not_started`, derived — never stored — from the
  live `PipelineOwner`'s own facts (census health, pipeline liveness), the
  node-local generation entry, the tombstone legs, and, when the repo is
  running, the durable checkpoint evidence. `AshReplicant.Status.derive/2`
  exposes the six-state generation lifecycle underneath (`:activating`,
  `:ready`, `:degraded`, `:halted`, `:stopped`, `:superseded`) with typed
  value-free evidence. Healthy requires a live owner and pipeline, an enabled
  census whose last run passed, and no in-flight snapshot — owner liveness
  alone is insufficient, and a dead or stale generation can never report
  healthy (it is the fault `{:halted, :owner_lost}`).

  When a generation ends, the party that knows the cause records a terminal
  tombstone: every error leaving a sink callback (Replicant halts the
  pipeline on any non-ok sink return, so the scrubbed reason riding the
  return is recorded at that one boundary — covering the halt funnels and
  the bind/session-identity/slot-origin error paths alike), the owner's
  census halt, and an operator stop (`:operator_stopped`). The tombstone is
  bounded (latest per slot) and value-free (closed reason atoms, a class, a
  timestamp); its durable leg lives in three new nullable checkpoint columns
  (`terminal_cause`, `terminal_class`, `terminal_at` — regenerate with
  `mix ash.codegen` and migrate), written only when the row already exists.
  Every admitted checkpoint write (bind — including the otherwise
  verify-only steady-state reconnect — and advance) clears the durable leg,
  so a stale cause cannot outlive the generation that superseded it. A halt
  while the destination is unreachable persists only the node-local leg; a
  host-tree shutdown writes no tombstone; an unexplained pipeline death
  records the generic `{:halted, :pipeline_terminated}` (Replicant discards
  halt reasons at teardown). Status/tombstone reasons never carry row,
  message, prefix, or progress-token bytes, and a foreign persisted cause
  decodes to the closed fallback `{:halted, :tombstone_unknown}` without
  minting atoms.

- **Read-only operator preflight and doctor commands** (roadmap D2).
  `mix ash_replicant.preflight --pipeline MyApp.Replicant.Pipeline` answers
  whether a pipeline may start — dependency requirements, sink configuration,
  destination admission, source reachability, PostgreSQL release, the
  connecting role's REPLICATION and per-table `SELECT` privileges, source
  identity, strict coverage, replica identity, slot shape, and the retention
  horizon — reading no checkpoint, so it is correct on a fresh install.
  `mix ash_replicant.doctor` adds the durable-state classes: checkpoint state,
  contract drift, and runtime readiness. Both resolve the generated pipeline's
  own admitted start options, and the same diagnosis is available in-process as
  `AshReplicant.preflight/1` and `AshReplicant.doctor/1`. The Mix task admits
  the generated marker from the BEAM export table before loading the named
  module, so an arbitrary module cannot execute `@on_load` or
  `start_options/0` through the read-only command.

  The commands perform **no writes**, on three independent legs: a fail-closed
  read-only statement admission (leading `SELECT` only, no separator, no write
  verb, no row lock, no session-escaping function such as `set_config` or
  `dblink*`); a probe connection opened `default_transaction_read_only=on`, so
  PostgreSQL itself refuses a write the admission missed; and a destination
  checkpoint read through its `:read` action with `authorize?: false` and no
  lock. They start only Postgrex's client runtime dependencies; they never
  start the host application, a repo, a pipeline, or a service.

  Machine (`--format json`) and operator output are both total functions of one
  canonical `AshReplicant.Doctor.Report`, so they cannot disagree. Missing
  privileges, unknown checkpoint state, replica identity, the retention horizon
  (`retention_extended` → `retention_at_risk` → `retention_lost`), contract
  drift, and the dependency/source version axes each carry their own reason
  atom. Reasons are a closed vocabulary and `detail` is a fail-closed allowlist
  of catalog identifiers, so no connection option, publication name, source
  identity, slot name, watermark, or row value reaches either format. A leg
  that could not be judged is reported `skipped` with the reason, never passed.
  Exit codes are `0` clean, `1` a failed check, `2` warnings only, and `3` an
  invocation that could not be diagnosed at all — distinct from `1` so a
  monitoring caller can tell an unhealthy deployment from a bad invocation.
  A never-matching `ignored_sources` entry now warns (`ignore_never_matches`).
  A permission or catalog-statement fault after connection is now reported as
  `privilege_probe_missing` / `source_probe_failed` while reachability remains
  passed, rather than misclassifying a responding server as unreachable.

  Coverage rules are reused, never re-implemented: `Coverage.evaluate/3`,
  the new `Coverage.replica_identity_check/2` and
  `Coverage.probe_identity_check/2` delegates to the existing private rules
  (so replica identity is reported even when an earlier rule short-circuits),
  and `Identity.classify_stored_contract/3` for drift.
  Missing declared tables remain a concrete `source_table_missing` coverage
  failure instead of being masked as an unjudgeable census, and replica
  identity is skipped independently when its relation does not exist. The
  identity probe now reads `pg_control_system().system_identifier` on every
  supported PostgreSQL 15 through 18 release rather than weakening PG15–16 to
  a database-name-only comparison.

- **Guarded 0.4.0 to 1.0.0 package upgrade and rollback.**
  `mix ash_replicant.upgrade 0.4.0 1.0.0` requires explicit per-sink source
  identity bindings, classifies the selected destination without printing
  identity-bearing source diffs, converts static 0.4 supervision to the
  generated `AshReplicant.Pipeline`, removes only the compile-time
  `apply_ledger` marker, and writes the guarded host migration plus the exact
  current AshPostgres resource snapshot (including a Repo-configured custom
  snapshot path). The migration upgrades populated or empty legacy tables in
  one locked transaction, refuses shared/ambiguous/foreign/interrupted state,
  and retains a checksummed rollback ledger. Down refuses after any durable
  1.0-only state or watermark change; the published procedure requires database
  rollback before package downgrade and otherwise says to restore from backup
  or remain on 1.0. A real consumer-process fixture proves redacted dry-run,
  apply, migration up/down, and no host application or pipeline start.

- **Data-boundary guard-mutation gates** (roadmap D7 / SEC01, ADR-0003).
  `scripts/run-mutation-gates.py` proves the fail-closed data-boundary guards
  are OBSERVED by the no-database focused tests: each of its 53 matrix cells
  removes exactly one production guard, removes one sibling call site of a
  shared guard, or moves one notifier guard after its first effect — across
  tenant absence, tenant reassignment, replica identity,
  sensitive type shape, sink-action multitenancy bypass, dynamic destination
  participants, notifier load drift, snapshot fingerprint collisions, and
  append identity, and requires the named focused selector to go red with a
  property-specific fingerprint. Mutants run serially in an isolated
  temporary project copy (dependencies copied and made read-only, mutant and
  restored BEAM digests proving build identity, `ASH_REPLICANT_TEST_URL` and
  Mix path redirections deleted from every child, zero `TestRepo` starts
  asserted); runner output is structural and value-free, SIGINT/SIGTERM
  teardown kills and confirms the child process group before scratch cleanup,
  and a sentinel self-test drives every
  failure class — missing/duplicate anchors, stale builds, restoration
  drift, baseline failures, vacuous mutants, wrong reds, timeouts with live
  descendants, and internal errors — proving no child byte reaches the
  runner's own output. The matrix runs once in the no-database CI job and is
  pinned by the release contract.
  - The pure B4 tri-modal tenant-transition tests moved from the
    `:integration`-tagged apply suite into `resolver_test.exs` so the
    reassignment guards have a no-database observation channel, gaining a
    tripwire for an update with NO old tuple on a tenant-scoped resource;
    live source pins now hold the `Apply`/`Apply.Scd2` tenant-pair preludes
    and extend the notifier-load guard count to the snapshot mark and retire
    call sites.

- **Fresh-install Igniter path with a tied-out manual equivalent** (roadmap
  D1/I01). `mix ash_replicant.install` — reachable as
  `mix igniter.install ash_replicant` — generates the Ash domain, the checkpoint
  resource, the sink, and the pipeline supervisor; registers the domain in
  `:ash_domains`; supervises the pipeline; imports AshReplicant's public DSL
  formatter metadata; and queues
  `mix ash.codegen install_ash_replicant`, so the checkpoint migration comes
  from the host's own resource snapshots rather than a shipped template that
  could drift. `--repo`, `--slot`, `--domain`, `--checkpoint`, `--sink`, and
  `--pipeline` override discovery and naming. Igniter is an **optional**
  dependency: without it the task prints the instruction to add it, and no
  shipped library code depends on it.
  - **Nothing speculative is written.** The installer emits no connection,
    publication, source identity, or key material — a plausible-looking
    placeholder is worse than an absent one — so a fresh install compiles and
    boots as a no-op. Re-running it over an installed project changes nothing.
  - **`AshReplicant.Pipeline`** is the new generated operator wiring: a host
    supervisor that supervises no children until
    `config :otp_app, MyApp.Replicant.Pipeline` supplies `:connection`,
    `:publication`, and `:source_identity`, and that RAISES on a
    present-but-incomplete configuration rather than supervising nothing (a
    silent outage). Its owner child stays `:temporary`, so a halt remains
    permanent (ADR-0014). Its messages name missing KEYS, never their values.
  - **A closed structural refusal set, each writing nothing:** malformed module
    names; an illegal PostgreSQL slot; no, ambiguous, unknown, or non-AshPostgres
    repo; incomplete project facts; a foreign target module; an unreadable
    existing binding; and checkpoint, sink, or pipeline identity drift.
    Re-keying a live sink would abandon its durable checkpoint row and
    re-deliver from the new slot's position, so the installer stops and names
    the resolving flag or structural fact.
  - The README's "Manual installation" block is tied to the installer's actual
    output by a test comparing parsed module/`use` contracts, so the documented
    hand path cannot drift from the generated one. Red-capable tripwires cover
    every refusal, the fail-closed pipeline admission, exact AST ownership,
    formatter import/export, the idempotency short-circuits, and the doc tie-out.
- **Continuous invariant census** (ADR-0019, roadmap C5/C01). The existing
  temporary `PipelineOwner` now schedules one jittered, bounded worker that
  enters through the same owner-liveness, destination-generation, and pinned
  dynamic-Repo guard as delivery callbacks. It rechecks the live destination
  and source contract, the durable source-bound checkpoint plus authenticated
  contract, and the full publication/column/type/RIF coverage even on a quiet
  stream. Drift halts immediately; timeout/unreachable/checker faults are typed
  non-pass states and the exact consecutive-fault budget halts
  `:census_unverifiable`. Schedule-after-settle timing, worker teardown, and
  mutation gates prevent overlap, orphan work, and vacuous green checks. A
  drift result that races its timeout still halts immediately, and stored
  contract terms decode in safe mode so checkpoint bytes cannot intern atoms.
- **Immutable append-log delivery** (ADR-0018, roadmap C4). A generated sink is
  now exclusively `sink_kind: :state_mirror` (the default — every existing host
  is unchanged) or `:append_log`, and an append sink records inserts, updates,
  deletes, truncates, logical messages, snapshot rows and batches as immutable
  events through a host-owned Ash create action.
  - `use AshReplicant.Sink` accepts `sink_kind:` and, for an append sink, the
    required `initial_state: :snapshot | :go_forward` — its ONE declared
    initial-state intent. Activation rejects a sink whose mapped resources
    disagree with its kind (`:sink_kind_mixed`) and an intent that contradicts
    the `snapshot:` start option (`:initial_state_mismatch`).
  - `replicant do append_log true end` marks a host AshPostgres resource an
    append target. It declares its own structural attributes (source system,
    source database, slot, commit LSN, ordinal, operation, origin, snapshot
    attempt), optional message prefix/content attributes, the immutable create
    action (`append_action`, default `:append`),
    and the append identity (`append_identity`) — verified at compile time by
    `ValidateAppendLog`, which also refuses SCD2 history, snapshot provenance,
    and the state-mirror truncate policies on an append target. `on_truncate`
    gains `:append` (record the structural truncate event), admitted only on an
    append target and only when no tenant source is declared.
  - The append identity is exactly `(source system, database, slot, commit LSN,
    ordinal)`. Delivery upserts against it with an EMPTY `upsert_fields`, which
    renders as a no-op conflict clause: a re-delivered WAL position appends ONCE
    and never overwrites the stored payload. Effect-once still rests on the
    append and the checkpoint committing in one locked destination transaction.
    Every non-attempt structural attribute is non-null, and the verifier rejects
    manual append actions or arbitrary action/global create changes that could
    rewrite the admitted identity after input validation.
  - Operation shapes are explicit and value-safe. A delete appends the admitted
    old record; a truncate is a structural event with no payload; a backfill row
    carries origin `"snapshot"` plus the checkpoint-owned attempt id, reusing
    none of the state-mirror row-provenance attributes. A routed message appends
    through the same action with operation `"message"`: transactional messages
    use the commit LSN/shared ordinal and standalone messages use their WAL LSN
    with ordinal zero. Payload mapping, tenancy and sensitive-type classification
    are the state-mirror rules unchanged. Every append source is activation-gated
    on `REPLICA IDENTITY FULL`, so a delete can never silently degrade to a
    primary-key-only event.
  - A go-forward append sink implements `handle_slot_origin/2` and persists the
    log's IMMUTABLE origin floor on its first admitted activation (new checkpoint
    attribute `origin_floor`; nullable, always NULL for a state mirror, so the
    regenerated migration is additive and needs no data capture). Later reconnect
    origins are resume facts: a slot CREATED this session arriving at a log that
    already claims a floor halts `:append_origin_gap`, and an appended event
    above the durable checkpoint halts `:append_frontier_divergent`.
    Replicant append sinks do not idle-advance over filtered WAL; a reused origin
    above the durable checkpoint therefore halts as an out-of-band gap. Quiet
    append publications use a normal published heartbeat to release retained WAL.
  - New closed error reasons: `:append_origin_gap`, `:append_origin_invalid`,
    `:append_frontier_divergent`. New AshOnetime invocation label `:append`.
    The public Replicant floor is now 1.2.3, whose append callback lifecycle
    retains filtered WAL until an actual append delivery or heartbeat advances
    the durable checkpoint.
- **Sink-owned incremental snapshots are restartable and physically
  effect-once** (ADR-0017, roadmap S03). Generated sinks now expose
  `snapshot_progress/0`; activation accepts Replicant 1.2.2 incremental mode
  only when every mapped resource declares `snapshot_provenance true`.
  - `snapshot_progress/0` locks the source-bound checkpoint and durably arms a
    random attempt before Replicant can start its reader and stream. Before the
    first chunk it returns `:backfill_pending`, so a crash after slot creation
    resumes the reader instead of abandoning the backfill. Owner or transport
    restart returns the exact previously committed opaque token and reuses the
    attempt.
  - Each bounded chunk commits its host effects, row fingerprint/membership,
    exact progress token, and durable operation-key ordinal cursor in one
    destination transaction. A failed chunk advances none of them.
  - Streamed inserts and updates during an armed/active backfill run the normal
    host action and stamp the active marker before advancing the stream
    watermark; deletes remove/close normally. Sink-owned transaction batches
    apply the same rule under their one trailing watermark write.
  - An SCD2 stream version committed before its table's snapshot window remains
    the current comparison target even when it opened above the snapshot floor.
    A matching current-read snapshot row coalesces through provenance instead
    of attempting a second open version.
  - Incremental completion is Replicant's empty at-least-once
    `handle_snapshot/2` call. It retires unseen rows per destination tenant
    scope, stores the exact token plus its SHA-256 replay fence, and never
    regresses the stream watermark. Matching redelivery no-ops before any scan.
  - In-flight progress is hash-bound inside the authenticated state envelope,
    so a valid replacement token cannot skip work. State/progress tamper,
    impossible pairing, incomplete-attempt contract drift, and missing key
    versions fail closed. A completed fence survives later admitted contract
    drift so deployment cannot brick streaming. A durable rewrite rotates the
    envelope to the active retained key; after completion the old key can be
    removed.
  - Black-box gates over the fetched Replicant artifact pin current-read
    collision filtering (insert/update/delete/key change), keyed three-attempt
    contention exhaustion, keyless redo signaling, reconnect accounting, and
    pending-chunk backpressure.

- **Whole-table (V1) snapshot retry is now physically effect-once** (ADR-0017,
  roadmap S02). A retry no longer repeats a committed host business effect for
  a row that did not change. Converging to the same final state was never proof
  of this: a create, destroy, or SCD2 close can carry an append-only local
  effect even when a later upsert converges to identical bytes.
  - **One checkpoint-owned attempt.** The checkpoint row carries a versioned,
    HMAC-authenticated, strictly decoded `AshReplicant.Snapshot.State` envelope:
    mode, status (armed/active/complete), a cryptographically random 256-bit
    attempt id, the V1 delivery-run id, the bound contract digest, the
    provenance key version, and the completion replay fence. It is read and
    written under the checkpoint row lock, which serializes chunks, completion
    and retirement against each other across nodes. Undecodable, tampered,
    impossible, or contract-drifted state fails CLOSED
    (`:snapshot_state_invalid`) — never a silently fresh attempt.
  - **One delivery run per activation.** `AshReplicant.PipelineOwner` activation
    mints a 256-bit `delivery_run`. The first actual `handle_snapshot/2`
    callback of a run binds it to a fresh attempt; later callbacks in that run
    reuse it; an operator-authorized re-export under a LATER owner rotates the
    attempt even when PostgreSQL returns the same consistent point.
    `first_for_table?` carries no attempt identity.
  - **Fingerprint-gated row effects.** For a `snapshot_provenance true`
    resource, each row resolves its tenant and current open target, recomputes
    the canonical fingerprint, and — on a match — invokes ONLY the private mark
    action. A changed or absent row goes through the normal host business action
    and is then stamped. An UNKNOWN comparison answer (dropped key, unknown
    encoding version, non-deterministic value) halts
    (`:snapshot_provenance_unavailable`) rather than degrading to "changed".
    Key rotation re-stamps unchanged rows under the active version.
  - **Fenced completion and tenant-scoped retirement.** Completion locks the
    checkpoint, checks the permanent V1 replay fence BEFORE any row scan (same
    delivery run and LSN → no-op, so a redelivered completion cannot retire a
    later stream write), then enumerates every destination tenant scope and
    retires only managed open rows whose marker differs, through the host's own
    retire action with `tenant:` set. Attribute multitenancy enumerates the
    verifier-approved discriminator with `SELECT DISTINCT` through the admitted
    Repo; global and non-multitenant resources take one scoped pass. SCD2
    retirement closes the open version and never touches closed history.
  - **`snapshot_tenant_scope_action`** (new DSL option) is REQUIRED for a
    non-global `strategy :context` multitenant resource with
    `snapshot_provenance true`: a private generic action returning the array of
    retained tenant contexts. Context multitenancy has no discriminator column,
    so the host is the only authority on which scopes exist — including one
    wholly absent from the source attempt. A missing, raising, or malformed
    enumeration fails CLOSED (`:snapshot_scope_incomplete`).
  - The snapshot mark, retire, and tenant-scope actions are now admitted
    manifest roots, walked for participants and tied out like every other mapped
    action. Two new invocation labels (`:mark_seen`, `:retire_unseen`) give them
    their own operation identity.
  - Three new reasons join the frozen taxonomy (additive per ADR-0011):
    `:snapshot_state_invalid`, `:snapshot_provenance_unavailable`,
    `:snapshot_scope_incomplete`.
  - Incremental mode reuses this envelope and row contract; its progress,
    stream-membership, ordinal cursor, and token-hash fence are now live.

### Changed

- **No snapshot callback clears a resource any more** (ADR-0017). Pre-S02,
  `handle_snapshot/2` issued a whole-resource `DELETE` on `first_for_table?` for
  redo-safety. That repeated every committed host business effect on a retry and
  could erase a stream-applied row, so it is gone — `first_for_table?`
  authorizes no deletion.
  - For a resource with `snapshot_provenance true`, stale rows are retired at
    fenced completion instead, per tenant scope, through the host retire action.
  - **A snapshot-backed resource that does NOT opt into `snapshot_provenance`
    now keeps rows the source has dropped.** There is no membership marker to
    retire them by. Nothing is deleted that was not deleted before — the change
    is strictly less destructive — but a host relying on the old wipe for
    redo-safety must declare `snapshot_provenance true` (plus the two protected
    attributes and the private mark/retire actions) to get retirement back. See
    `usage-rules.md`.
- **Checkpoint schema: `snapshot_generation` is replaced by `snapshot_state`.**
  Nothing ever wrote `snapshot_generation` (it was reserved and inert), so the
  regenerated migration drops an always-NULL column and adds an always-NULL one.
  Hosts run `mix ash.codegen` and migrate; no data capture is required.
  `snapshot_progress` is now written atomically by incremental chunks and
  completion.

- **Snapshot provenance and retirement contract** (ADR-0017, roadmap S01). A
  mirror resource can opt in with `snapshot_provenance true`, declaring two
  protected internal attributes — `replica_fingerprint` and
  `replica_seen_attempt` — plus a private mark action and a private retirement
  action. A snapshot retry can then tell an unchanged row from a changed one
  and skip repeating the host's append-only business effects.
  - `AshReplicant.Snapshot.Provenance` computes the fingerprint: an
    HMAC-SHA-256 over a canonical, type-tagged, length-prefixed encoding of the
    mapped action inputs plus the resolved tenant and resource identity, tagged
    with both the encoding version and the key version. Keys come from
    `:ash_replicant, :snapshot_provenance_keys` (same validated shape as
    `:message_digest_keys`). Rotation retains old versions; a missing key,
    unknown encoding version, or non-deterministic value fails CLOSED rather
    than reporting the row as changed.
  - `AshReplicant.Snapshot.MarkSeen` is the only write path to the two
    attributes, stamping them from the sink-supplied changeset context via
    `Ash.Changeset.force_change_attribute/3`. A missing or malformed context
    fails the changeset closed.
  - `AshReplicant.Resource.Verifiers.ValidateSnapshotProvenance` moves the whole
    contract to build time: attribute shape, and the guarantee that NO action
    accepts either attribute or declares an argument named for one. It also
    rejects `MarkSeen` in the global `changes` block or on any action other than
    the configured private mark action, leaving one provenance-write owner.
    `ValidateActionMultitenancy` now also rejects `multitenancy :bypass` /
    `:bypass_all` on the two provenance actions.
  - Activation preflights the key configuration whenever a mapped resource opts
    in, and refuses to start without it.
  - `snapshot_provenance` defaults to `false`: an existing resource compiles and
    behaves exactly as before. V1 uses the contract for effect-once retry and
    incremental mode requires it for activation.

### Documented

- Record the approved 1.0 release design as ADRs 0017-0021 and pending hardening
  amendments to ADR-0010/0015. ADR-0017's snapshot restart protocol is now live;
  the later append-log, continuous assurance, install/doctor, expanded support,
  and publication records remain proposed release gates.

### Breaking

- A notifier attached to a mirrored resource whose load statement is
  non-empty must now route it through the new `AshReplicant.Notifier`
  wrapper in addition to declaring `AshReplicant.DestinationParticipant`.
  Replace `load/2` with `preload/2` and add `use AshReplicant.Notifier`
  after `use Ash.Notifier`; the wrapper defines `load/2`. Admission proves the
  live callback actually enters that wrapper on both stability probes — a
  retained behaviour marker cannot hide an overridden `load/2`. It rejects
  an unwrapped one with
  `{:destination_notifier_unwrapped, resource, action, notifier}`, and a
  statement or declaration that will not reproduce itself between two
  consecutive calls with
  `{:destination_notifier_unstable, resource, action, notifier}`. Notifiers
  with no load statement are unchanged and need nothing. Ash re-derives the
  statement at delivery, so the declaration alone bound nothing: only the
  wrapper sits in that call path (ADR-0010's 1.0 amendment, now landed).
- The generated checkpoint resource is now **default-deny** (roadmap B7 /
  ADR-0014): `use AshReplicant.Checkpoint` generates `Ash.Policy.Authorizer`
  with an empty policy set, forbidding every external actor on every action.
  The sink and operator paths run `authorize?: false` (unchanged,
  effect-once is unaffected). Hosts that read or write the checkpoint from
  their own code without an authorize bypass must now declare a `policies
  do` block granting that access, or pass `authorizers: []` to reproduce
  the earlier unguarded shape.
- `AshReplicant.start_link/1` now returns the `AshReplicant.PipelineOwner`
  pid (previously the Replicant pipeline pid); both are opaque handles and
  `stop_supervised/1` is unchanged. The owner is not linked to the caller
  (a caller finishing never takes a live pipeline down), but a
  host-supervision-tree shutdown now also stops the pipelines owned by
  that tree.

### Added

- **Bound notifier load statements (ADR-0010 1.0 amendment).** The
  destination manifest now carries, for every admitted action, each
  notifier's load-statement digest and declared action-closure digest
  (`Manifest.notifier_loads`, inside `Manifest.digest`). `AshReplicant.Notifier`
  compares both before handing Ash the statement; admission and delivery also
  verify the live `load/2` still routes through that comparison, and
  `AshReplicant.Apply.Context.verify_notifier_loads!/4` re-checks immediately
  before every sink-driven host action — mirror upsert and destroy, SCD2
  close and open, snapshot `bulk_create`, and message routes — for what the
  wrapper cannot see. Three additive reasons join the frozen taxonomy
  (ADR-0011) under the existing destination tuple:
  `{:invalid_destination_config, :notifier_load_drift}`,
  `{:invalid_destination_config, :notifier_load_unadmitted}`, and
  `{:invalid_destination_config, :notifier_load_probe_failed}`. All are
  value-free and survive the sink's scrub, so operators can branch on them.

- Require fetched Replicant `>= 1.2.3 and < 2.0.0-0` and pin the release lock to
  public Hex 1.2.3. The dependency contract now proves slot-origin rejection,
  typed telemetry value-shape enforcement without value leakage, and bounded
  keyed-snapshot contention plus pre-first-chunk pending recovery; CI's exact
  floor and rollback guidance use 1.2.3.

- **Atomic sink-owned batch delivery (roadmap C2 / ADR-0016).** The generated
  sink now implements `handle_batch/1` unconditionally, and
  `AshReplicant.start_link/1` accepts and forwards `:batch_delivery`
  (`[max_transactions: n, max_delay_ms: ms]`; a malformed value fails closed
  `{:error, :config_invalid}` at start — previously the option was silently
  withheld and batching was unreachable). With `batch_delivery` set, delivery
  routes through one `handle_batch/1` call per flushed batch: the ascending
  transactions and their transactional messages apply through the same
  single-pass core as `handle_transaction/1` (lazy spilled streams are never
  materialized), the checkpoint advances to the batch's highest LSN in the
  SAME destination transaction after all effects, and any frontier at/below
  the watermark skips — effect-once (dup = 0) holds across a mid-batch
  teardown. New telemetry: `[:ash_replicant, :sink, :batch_applied]` (one
  event per flush) and the typed `txn_count` metadata key; the per-transaction
  `:applied` event does not fire in batch mode.
- **Logical-message actions (roadmap C1 / ADR-0015).** `use AshReplicant.Sink`
  accepts `message_routes` (`{"prefix", Resource, :action}` triples routing
  `pg_logical_emit_message` output to host create actions) and
  `ignored_message_prefixes`. A sink declaring either exposes
  `handle_message/2` and the pipeline starts with `messages: true`
  automatically. Every routed action must carry the closed AshOnetime message
  profile (idempotency claim keyed on source+slot+LSN with a versioned
  host-keyed content digest as the fingerprint — configure
  `:ash_replicant, :message_digest_keys`; an optional `external_effect` module
  rides AshOnetime's three-state recovery). Transactional messages ride their
  transaction interleaved with the row changes by ordinal; standalone messages
  apply effect+claim+watermark atomically (local) or finalize-then-watermark
  (external). An unknown prefix halts fail-closed
  (`:message_prefix_unmapped`, a new closed reason); `byte_size` joins the
  typed telemetry measurement set for `[:ash_replicant, :message, :applied]`
  and `transactional` joins the typed metadata keys.
- `AshReplicant.PipelineOwner` (roadmap B7 / ADR-0014): one owner per live
  resolver generation. It runs the full activation chain (same validation,
  preflights, lock, and synchronous error shapes), records itself as the
  generation's owner, and monitors the Replicant pipeline — when the
  pipeline exits (fail-closed halt, crash, external stop, host-tree
  shutdown) it erases only its own generation and clears the snapshot
  ordinals, so a halted slot is immediately re-activatable instead of
  wedged on `:slot_already_active`. `child_spec/1` starts it as a
  `:temporary` child (id `{AshReplicant.PipelineOwner, slot_name}`, so a
  duplicate slot in one tree fails at supervisor start). A generation
  whose owner has died fails closed at callback entry (the pipeline halts
  itself) and is replaced — reaping any orphan pipeline — by the next
  activation or offline operator function; offline adopt/reset/acknowledge
  no longer wedge on a stale entry. Replicant retains transport ownership
  throughout.
- ADR-0014 (`docs/adr/0014-internal-trust-and-lifecycle-ownership.md`)
  governs the internal-trust and lifecycle-ownership frame (and retires
  the gap-list row "Tenant-blind layering and pipeline ownership").
- `AshReplicant.DestinationParticipant.operation_key/2` now requires an
  `:invocation` label in the operation context (the sink mints it; manual
  minters — tests, replay probes — must carry the mint-site label). Closes the
  intra-change AshOnetime key collision where one change's two SCD2 closes
  shared a key and the second close replayed the first's stored response
  (ADR-0010). Upgrade note: sink-side claims live and die in the SAME
  transaction as their effects and the checkpoint (atomic), so no sink-side
  durable claim can survive across the upgrade — but any HOST-side store
  holding manually-minted keys under the old 6-component encoding must be
  drained before upgrading; admission already rejects independent-commit
  claims, so this only affects out-of-band host tooling.
- A notifier whose `load/2` returns a non-empty statement must implement
  `AshReplicant.DestinationParticipant` (`:notifier` kind): its dependency
  pre-load read executes inside the admitted transaction regardless of notify
  gates (ADR-0010).
### Added

- Completed value-free boundary: `catch :throw`/`:exit` at all six sink bodies;
  the schema-change fault path fires the sink's own `:halted` with the
  structural reason (previously mislabeled `:decode_failure` by the framework
  wrapper) (ADR-0009).
- Typed telemetry: per-key metadata types, a closed measurement-key set
  (`byte_size` reserved for C1), count-only off-allowlist raises, and a
  conformance integration gate over every emitted event name.
- `AshReplicant.Sql`: the one identifier quoting home (PG-canonical doubling,
  control-character rejection) — admission-time identifier validation in the
  manifest walk; all raw-SQL sites routed through it (ADR-0009).
- The action-contract freeze table (live-reflection source-pin test), the
  reason-space enumeration, and the Ash-bump grep procedure (CONTRIBUTING).
- Release-contract absence gates: `apply_ledger` (exactly the two allowlisted
  fail-closed lines) and a secret-literal scan over `lib/`.
- `AshReplicant.Apply.Context.invocation_labels/0` and
  `AshReplicant.DestinationParticipant.operation_components/0` (the single
  component-list home).
- Activation source-catalog preflight (roadmap B3): missing expected tables,
  unignored publication tables, unmapped columns, missing declared columns,
  stale skips, invalid source types, and wrong replica identity halt before
  any checkpoint advance; the check re-runs at every reconnect; an
  unreachable source defers the verdict. `ignored_sources` declares
  intentional partial publications. ADR-0008.
- Tenant reassignment is fail-closed (roadmap B4): both tenants resolve
  before any write; an absent/blank/false/raising old side — or a missing
  `old_record` — halts value-free; SCD1 relocates, SCD2 terminally closes
  under the old tenant. ADR-0001 amended.
- `AshReplicant.adopt_checkpoint/3`, `AshReplicant.reset_checkpoint/2`, and
  `AshReplicant.acknowledge_checkpoint_timeline/3` operator recovery surfaces,
  plus `AshReplicant.Checkpoint.Identity.refuse_ambiguous_legacy_rows!/1` /
  `legacy_checkpoint_row_count/1` for the slot-only upgrade path.
- ADR-0007 records the source-bound, serialized checkpoint decision.
- Adopt Replicant `>= 1.0.0 and < 2.0.0-0` from Hex, with current 1.1.0 and
  exact-floor 1.0.0 compatibility gates. Generated sinks now require and compare
  the actual replication-session system/database identity before checkpoint lookup.
- ADR-0011 pins the closed error-reason set and the telemetry event-name
  inventory as public contract (additive growth only; removal/rename is
  breaking with migration notes), and ADR-0012 governs the snapshot
  run-scoped ordinal space — the axis the per-invocation operation keys
  depend on. Both record shipped, freeze-tested decisions and assign the
  roadmap ownership the gap list was missing.
- Add live Replicant 1.1.0 proofs for actual-session ordering, v1 snapshot-to-stream
  convergence, post-handoff restart, and operator-reset retry after an incomplete snapshot.
- Add AshOnetime 0.6.0 as the governed idempotency dependency for the logical-message
  actions planned for 1.0.0 and for admitted local auxiliary actions that need a
  WAL replay guard. The permanent commit-LSN checkpoint remains the transaction
  replay and resume authority.
- Add a deterministic recursive destination manifest covering checkpoint, mapped,
  framework-reached, SCD2, and declared auxiliary actions. It rejects foreign or
  dynamic Repos, non-Postgres resources, missing/opaque/cyclic participants, and
  `touches_resources` mismatches before delivery, then pins one effective Repo and
  generation through commit or rollback.
- Add `AshReplicant.DestinationParticipant` and a WAL-safe AshOnetime admission
  profile for local auxiliary actions: exact source/database/slot/LSN/ordinal/
  participant identity, private operation key, same-transaction fail-closed store,
  and explicit rejection of nonce, independent, external, and opaque profiles.
- Add independent CI paths for no-database tests, exact-floor/current-lock/latest-Ash
  live PostgreSQL integration, migration drift, Dialyzer, warnings-as-errors docs,
  and selector-free Hex package inspection. Checked-in assertions reject missing,
  skipped, invalid, excluded-without-authorization, or failing test evidence.
- Pin third-party CI actions to immutable commits, assert the executing
  Elixir/OTP identity, capture raw test failures without publishing values, and
  mutation-test the release-evidence, workflow, documentation, and migration
  checkers against masking and constant-accept regressions.
### Changed

- **Breaking:** an unmapped publication table now HALTS
  (`:source_table_unmapped`) instead of the silent partial-publication
  skip — declare `ignored_sources` for intentional partial coverage. An
  unaccounted delivered column halts (`:source_column_unmapped`).
  `:replica_identity_changed` and `:type_changed` schema changes always
  halt regardless of `on_schema_change :ignore`.
- **Removed:** `Resolver.writable_target/2` (dead code) and
  `Resolver.tenant_changed?/2` (its fail-open caveat is the class B4
  closed).
- **Breaking:** the generated checkpoint resource is source-bound — the
  composite primary key is `(source_system_id, source_database, slot_name)`
  from the actual replication session, with `source_timeline`,
  `publication_contract`/`publication_fingerprint`, nullable-until-first-commit
  `commit_lsn`, reserved snapshot-frontier columns, timestamps, the
  `:source_slot` identity, and a named `:operator_reset` destroy action. The
  slot-only `:unique_slot` identity is gone and the shape change requires a
  migration; use `mix ash_replicant.upgrade 0.4.0 1.0.0` and follow the
  rollback boundary in `usage-rules.md`.
- The sink binds the checkpoint row inside `handle_session_identity/2` (now a
  mutating, lease-held callback) on every connect: a foreign same-slot
  identity, a changed timeline, a watermark ahead of the session's WAL flush
  position, or an incompatible contract transition halts fail-closed with
  value-free reasons and a `[:ash_replicant, :checkpoint, :conflict]` event.
- Admission takes the checkpoint row `FOR UPDATE` inside the destination
  transaction; lower/equal LSNs never regress or reapply and concurrent
  callers produce one effect. An absent row at admission is a permanent
  `:checkpoint_unbound` halt (restart re-binds). The v1 snapshot handoff no
  longer regresses the watermark on a re-delivered consistent point.
- Serialize resolver activation per slot, generation-check rejected-start cleanup,
  and forward Replicant's safe `streaming`, `max_inflight_lag`,
  `max_command_retries`, and `failover` transport options. Incremental snapshots,
  batch delivery, and logical messages are now live under their owning contracts.
- Extend the physical effect-once guarantee from committed streaming transactions
  and atomic snapshot batches to V1 and incremental snapshot retry through the
  checkpoint-owned provenance protocol and permanent completion fences.
- Require Elixir 1.20.3/OTP 29 and the AshPostgres 2.11 dependency family for the
  1.0.0 release line.
### Security

- Raise the 1.0.0 dependency floor to audit-clean Ash 3.31.3 and exclude Ash 4
  prereleases; resolve Postgrex 0.22.4 and ymlr 5.1.6 so `mix hex.audit` and
  `mix deps.audit` report no known advisories.
- Make generated delivery callbacks invoke the admitted sink implementation
  directly; remove the overridable effect hook that could acknowledge WAL without
  applying rows/checkpointing. Reject data-layer `SetContext` redirection and
  behavior-conforming external AshOnetime caches at destination admission.
- Give v1 snapshots ONE continuing operation-ordinal space per run (keyed by the
  exported consistent point). A per-table space minted identical operation keys
  for table A row i and table B row i whenever two mapped resources shared one
  participant atom, and AshOnetime replayed A's stored response for B — silently
  suppressing B's declared auxiliary effect. Proven live by a two-table
  same-participant snapshot marquee.
- Reject unknown or removed `use AshReplicant.Sink` options at compile time
  (including the removed `apply_ledger`) instead of silently dropping them — a
  host upgrading across the removal now gets a compile failure, not a
  silently-gone ledger.
- Admit the dynamic (MFA) `set_context` form only when the module behind the MFA
  declares its effects through `AshReplicant.DestinationParticipant`; static-map
  contexts still may not replace `:data_layer`. The core-code fingerprint now
  covers every delivery-reachable module including the value-free telemetry
  allowlist enforcer.
- Close four cross-vendor-admission bypasses found by the peer review: a
  `set_context` may no longer touch `:shared` (Ash promotes it over the whole
  context, so a nested `shared.data_layer` redirected the destination) or the
  sink-owned `:ash_replicant_operation` identity (a forged operation context
  would mint one replay key for every row); `prepare build(context: ...)` is
  rejected (Ash.Query.build's context option redirects `data_layer`); and every
  admitted action — including declared auxiliary participants — must keep its
  tenant scoping (`multitenancy :bypass`/`:bypass_all` is rejected, closing
  cross-tenant auxiliary effects). Streaming transactions carry an explicit
  120s timeout (the per-change generation guards can exceed DBConnection's 15s
  default at scale, deterministically wedging replication), and a sink callback
  defined BEFORE `use AshReplicant.Sink` now also fails compilation (it would
  win dispatch and skip the generation guard, activation lock, and repo pin).
- Completed the cross-vendor value-free closure over every error-shaped input:
  `Error.scrub`/`Error.scrub_caught` trust no field of an incoming error
  struct — a forged `:reason` or `:shape`, via raise, throw, or the rollback
  verb, survives only as the closed typed reason — and the reason space is
  pinned to the library's finite set. The telemetry `span/3` is hand-rolled
  so an exception event carries the class only and no malformed-result path
  renders a value. `:bulk_create` joins the sink-owned context keys (a host
  `SetContext` over the framework's per-row snapshot index would alias a
  whole batch onto ONE operation key — the replay-suppression class), the
  generation code-fingerprint covers `AshReplicant.Sql`, and the legacy-row
  count probe routes through the quoting home. Gate-integrity pins: live
  mint-site label equality, a bidirectional mint-site ↔ frozen-label
  inventory, strict-walk cycle detection on the destination manifest, and a
  load-realistic await for the concurrent-start race.

### Added

- ADR-0013 governs the sensitive type-shape classification (AshCloak cloak
  attribute ∪ binary-storage attribute ∪ `skip`, verified by type shape at
  compile — never ciphertext; the tenant discriminator is never sensitive).
  The ADR gap list had retired this row by mis-attribution to ADR-0009
  (which governs the value-free boundary); the retirement paragraph now
  points at ADR-0013 and the corpus entry is registered.
- The public `@type reason` is pinned to `@closed_reasons` by a source-level
  test — the type had lagged ADR-0011's frozen set by 8 atoms
  (Dialyzer-silent) and narrowed the destination tuple variant to one atom;
  both fixed, and the next added reason must update type and set together
  or the pin goes red.
- Published-docs alignment sweep: the four doubled-path ADR links (README ×2,
  usage-rules ×2 — `docs/adr/docs/adr/…` → 404s) repaired; the checkpoint
  intro in `usage-rules.md` now states the source-bound triple (was the
  pre-0.4.0 slot-only shape); `docs/ROADMAP.md` is explicitly status-free
  (status of record = commit history + this changelog's `[Unreleased]`; the
  dead host-pinned derivation command removed); the frozen 2026-07-09
  closeout handoff carries a banner noting its commit IDs predate the
  history rewrite and do not resolve; `AGENTS.md`'s docs policy names the
  tracked notebook and all gitignored tool-state directories; `CLAUDE.md`
  names `../replicant` as the only sibling (ash_postgres is a Hex dep);
  the charter's Task-15 proof and ADR-0002's lock list are marked as
  point-in-time snapshots with derive-don't-state notes; the substrate
  version and battery URL in README/CONTRIBUTING are examples to derive
  from, not current-state claims; `AshReplicant.Sql`'s sanctioned-site
  enumeration includes the checkpoint legacy-probe count.

### Fixed

- The batteries' intermittent reds were fixed-budget flakes, closed by
  making the affected waits load-proportional (no product change — the
  pipeline behaved correctly in every observed red; only test budgets were
  miscalibrated to an idle host). Three instances: the v1-snapshot restart
  marquee's re-snapshot wait (a row-proportional phase: ~8-12s idle, 55s
  observed under concurrent host load against a ~24s poll budget — the
  postgres log's slot/stream timestamps pin the divergence; reproduced red
  under synthetic CPU load and green under the same load after the fix), the
  destination-lease test's 1s callback-entry assert (entry re-validates the
  admitted generation — a manifest walk plus a bytecode fingerprint whose
  file reads go through the serialized code server; ~4ms warm, observed >1s
  once under battery IO load coincident with a substrate checkpoint), and
  the concurrent-start race test's awaits (its own documented 5s flake of
  2026-08-15 re-appeared once at 15s in the no-DB battery; the ceiling now
  only bounds waiting — the start-gate asserts fire on the tasks' return
  values). The negative lease window (the 50ms `Task.yield`) is unchanged —
  load only makes a held lease more likely to hold.
- The value-free battery receipt now locates the failing ASSERTION: the
  structural formatter's `FAILED:` line appends the first stack frame from
  the repo's own code (`file:line`, identified by module namespace —
  dependency sources also live under `lib/`-shaped paths). Test name alone
  could not say which assert of a multi-assert marquee tripped; this
  investigation's third red stayed undiagnosable past the name exactly
  because of that gap. Structural only — authored names and file:line,
  never row values (ADR-0009).
- CI's from-clean `MIX_ENV=test` compile-WAE is green again (warm local
  builds had masked three fixture-warning classes shipped in the unpushed
  span): the marquee's auxiliary-carrying `close_version` declares
  `require_atomic? false` (its effect-recording change is non-atomic by
  design), the destination-walk loop fixtures are registered in their own
  domain, and `RaisingMfaOrder` moved to test support so a clean compile
  can verify the domain that references it.
- Admit the census preflight connection BEFORE starting a pool: a
  postgrex-UNRESOLVABLE `:connection` database (absent key with no
  `PGDATABASE`, or an explicit nil — postgrex discovers the missing
  `:database` key only inside the pool's async connect) now defers as the
  unreachable class immediately, instead of starting a pool that can never
  connect, logging `[error] missing the :database key` on every backoff
  retry while burning the checkout queue-timeout on every bind. The gate
  mirrors postgrex's own resolution (`Utils.default_opts/1` — the same
  resolution the replication stream applies), so a `PGDATABASE`-configured
  source is censused, never deferred, and the census and the stream cannot
  disagree. This is what made the live structural battery fail its own
  no-error gate with every test passing; a host misconfiguring the
  connection keyword hit the same doomed-pool burn at runtime. Sync-start
  failures return the structural `{:error, :unreachable}` (callers defer
  through their census-fault branch and never query or stop a placeholder
  connection), and the dead-for-pools `sync_connect: true` merge is dropped
  (only the replication connection reads that option).
- The forced-reconnect marquee captures the replication connection's
  expected `[error]` reconnect line (the `start_link_test` precedent), which
  otherwise order-dependently trips the same battery gate.
- Dialyzer green again: `legacy_checkpoint_row_count/2`'s spec now admits
  the `{:error, :checkpoint_probe_failed}` probe-failure leg its body
  already returns (the caller handled it), and the census preflight's
  catch-all scrub — unreachable once admission returns error-tagged
  connections — is removed (the closed-case shape `reconnect_check/5`
  already uses).
- The structural-test gate prints the offending lines on an
  uncontrolled-error trip (its raw capture is otherwise trap-deleted,
  leaving an intermittent trip undiagnosable when it does not
  re-reproduce).
- Reconcile public policy, snapshot, tenancy, notifier, and release-history
  documentation with live code. Host policies are not re-gated, the current
  adapter supports v1 snapshots only, and tenant reassignment requires the old
  tenant record shape.
- Split checkpoint policy introspection from its six live enforcement cases so
  `mix test --exclude integration` runs successfully without starting TestRepo.
- Cover SCD2 resources in migration drift and observe TestRepo start attempts in
  the same VM as the database-free suite.
- Decode release workflows as YAML, require independently executable gate steps,
  bind compatibility selection to its exact unlock/assert block, and validate
  visible non-contradictory runtime documentation. Independent mutations now
  cover every protected release-evidence decision.
- Reconciled the published docs with shipped code: the tenant-reassignment
  old-side fail-closed guard is SHIPPED (`:tenant_required` `side=old` /
  `:tenant_resolution_failed`, fail-closed before any write), not open
  roadmap work (README, usage-rules, CHARTER now say so); the live
  integration gate's PostgreSQL statement records the actual split (CI pins
  16, the local substrate is 18, the support matrix is PG15–18); relative
  ADR links normalize to the canonical GitHub form; and the cloak-upsert
  spike's PG16 note reads as the historical proof it is.
  `AshReplicant.Sql`, `AshReplicant.Apply.Context`, and
  `AshReplicant.Checkpoint.Identity` carry real moduledocs (their
  comment-docs, promoted) so the reference-checked docs gate is green over
  the surfaces the docs already advertised.

## [0.4.0] - 2026-08-03

### Added

- **`use AshReplicant.Checkpoint` accepts an `authorizers:` option**, so the generated
  checkpoint resource can carry `Ash.Policy.Authorizer` and enforce host-declared
  `policies do` blocks. The checkpoint is an internal watermark; a host that exposes its
  domain on a wire surface (JSON:API, MCP) previously had no way to lock the checkpoint
  down, because the macro emitted a resource with no authorizer and `policies` is not a
  declarable section without one. The sink still reads/upserts with `authorize?: false`
  on both paths (`Sink.Impl.read_checkpoint/1`, `upsert_checkpoint/2`), so effect-once is
  unaffected by whatever policies the host declares — including none, which fail-closes
  the resource to every actor except the sink. `authorizers:` defaults to `[]`, identical
  to the option Ash already defaults to, so existing hosts get the byte-for-byte prior
  resource (no behaviour change). Verified against live logical-replication Postgres:
  `checkpoint_policy_test.exs` proves the authorizer + policies are present, a non-system
  actor is denied (hard `Forbidden`), a system actor is allowed, and the sink's
  `authorize?: false` path bypasses both.

## [0.3.3] - 2026-08-02

> **Release provenance:** 0.3.3 was published to
> [Hex](https://hex.pm/packages/ash_replicant/0.3.3). Every packaged
> source/document byte matches commit
> [`3b61d3a`](https://github.com/baselabs/ash_replicant/commit/3b61d3a9ae553fb96ff26e9fcf581416af723843).
> The publishing checkout itself is not independently recorded. No `v0.3.3` Git
> tag or GitHub Release was created; current documentation does not invent one.

### Fixed

- **Tenant reassignment on the SCD2 path no longer leaves a double-current version.** The
  0.3.2 relocate fix covered only the SCD1 (upsert) path. On the SCD2 (validity-windowed)
  path a tenant reassignment (same business key, new tenant) left the OLD-tenant version
  OPEN forever while opening a fresh current version under the NEW tenant — the entity read
  as "current" under BOTH tenants (a silent double-current split; a per-tenant open-uniq
  index permits it, so no error surfaced). `Apply.Scd2` now terminally closes the old-tenant
  version on a resolved-tenant change (in addition to a business-key change), relocating the
  row. Regression test: `scd2_apply_test.exs` "tenant-reassigning update terminally closes
  the OLD-tenant version and opens under the NEW tenant".
- **Value-free preserved on the tenant-change check.** The reassignment predicate was
  promoted to `Resolver.tenant_changed?/2` and made scrub-safe: a raising `tenant_mfa`
  resolver is caught inside the check and reported as "not changed" (never propagating an
  unscrubbed row value out of the pre-apply tenant comparison, which sits outside the
  per-op scrub boundary). Both apply paths share the one helper.

### Notes

- Tenant-scoped mirrors REQUIRE `REPLICA IDENTITY FULL` on the source for reassignment
  detection: the check needs the old row's tenant, which is key-only under the default
  replica identity. Without RIF a genuine reassignment falls through to the pre-0.3.2
  behavior (SCD1: the colliding upsert; SCD2: the double-current) — the same `old_record`
  dependency already documented for tenant-scoped deletes/PK-changes.
- Reassignment detection also depends on a NON-RAISING tenant resolver. `Resolver.tenant_changed?/2`
  treats a raising `tenant_mfa` as "not changed" (value-free), so an MFA that raises on
  `old_record` makes a reassignment invisible and the caller keeps its non-relocating path.
  `tenant_attribute` resolvers never raise; this affects only `tenant_mfa` and is not a
  regression (no path handled reassignment before 0.3.2/0.3.3).

## [0.3.2] - 2026-08-02

### Fixed

- **Tenant reassignment no longer halts the mirror stream.** When a source row's tenant
  attribute changed (same PK, new `tenant_attribute` value), a resource declaring a
  tenant-scoped upsert identity (`identity :source_pk, [pk]` under attribute multitenancy →
  a `(tenant, pk)` unique index) would fall through to an INSERT under the new tenant that
  collided with the row's GLOBAL primary key (the still-present old-tenant row). The upsert
  raised, the sink transaction rolled back, and the checkpoint froze — a fail-closed poison
  pill that stalled delivery for ALL tenants and retained source WAL indefinitely. `Apply`
  now treats a resolved-tenant change like a PK change: destroy the old-tenant row (resolved
  from `old_record`) then upsert under the new tenant, relocating the mirror row. Triggers
  only when both tenants resolve and differ, so non-multitenant resources and key-only
  `old_record` updates (no REPLICA IDENTITY FULL) are unchanged. Regression test:
  `apply_test.exs` "tenant-reassigning UPDATE … MOVES the row to the new tenant".

## [0.3.1] - 2026-08-02

### Changed

- Widen the `replicant` requirement from `~> 0.1.0` to `~> 0.3` so consumers can adopt the
  current replicant line (0.3.x) without a resolver conflict. ash_replicant calls only
  replicant's stable core (`Replicant.{Change, SchemaChange, Sink, Transaction, lsn}`,
  `Replicant.start_link/1`, `Replicant.stop/1`); verified compatible against replicant 0.3.1:
  `mix compile --warnings-as-errors` clean and `mix test` 90 passed / 0 failed (unit suite;
  the `:integration` gate — 52 tests needing a live `wal_level=logical` DB via
  `ASH_REPLICANT_TEST_URL` — is owed in CI before publish). No API or behavior change.

## [0.3.0] - 2026-07-14

### Added

- **SCD2 history mirroring** — a per-resource opt-in (`history_strategy :scd2`) that
  mirrors a source table into a host-defined validity-windowed version table
  (close-current + insert-version) instead of overwriting current state. Effect-once,
  fail-closed multitenancy, value-free boundaries, and Critical Rule 1 preserved; new
  `ValidateHistory` compile verifier; `on_truncate :close`. Audit-log needs remain
  served by AshPaperTrail on an SCD1 mirror.

### Security

- **Multitenancy fail-closed at compile time — both tenant sources.**
  `ValidateMultitenancy` now requires an Ash `multitenancy` block whenever a
  `tenant_attribute` **or** a `tenant_mfa` is declared. Without a block Ash silently
  ignores the `tenant:` option the sink passes, so every tenant's rows mirror **unscoped**
  into one table — a proven fail-open with no runtime error. The `tenant_attribute` arm
  shipped 2026-07-10; the symmetric `tenant_mfa` arm closes the parallel hole (2026-07-14).
  Any strategy (`:attribute` or `:context`), including a `global?` block, satisfies the gate.
  See [ADR-0001](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0001-fail-closed-multitenancy.md).
- **A `false`-resolved tenant now fails closed.** `Resolver.resolve_tenant/2` rejected only
  `nil`/blank-string tenants; a `tenant_attribute` column holding boolean `false` or a
  `tenant_mfa` returning `false` resolved to `{:ok, false}`. Ash treats a falsy tenant as
  **no scoping** (neither force-set nor required), so the mirror write landed **unscoped**
  across tenants. `false` now returns `:tenant_required` like `nil` (2026-07-14).
- **Sink-selected actions can no longer bypass tenancy.** A new
  `ValidateActionMultitenancy` compile verifier rejects `multitenancy :bypass` / `:bypass_all`
  on the host's primary **read**, create, destroy, and the SCD2 close action of a multitenant
  resource — Ash would otherwise ignore the tenant the sink passes and mirror every tenant
  **unscoped** (and a `:bypass` read would let a `bulk_update`/`bulk_destroy` match and mutate
  another tenant's rows), despite a valid multitenancy block. `:enforce` and `:allow_global`
  remain permitted (2026-07-14).
- **The multitenancy discriminator column is now shape-checked.** Under `strategy :attribute`,
  `ValidateMultitenancy` rejects a `sensitive`-classified or binary-storage-typed multitenancy
  `attribute` — Ash force-sets it to the plaintext tenant and filters reads on it, so an
  encrypted/binary column would store/compare a mismatched value and **silently mis-scope**
  (reads return empty). AshCloak-encrypted attributes are already rejected by Ash's own verifier
  (2026-07-14).

## [0.2.0] - 2026-07-09

### Added

- **`ValidateTenantSource` compile-time verifier** — a resource declaring
  non-global Ash multitenancy must declare a `replicant` tenant source
  (`tenant_attribute` or `tenant_mfa`). Without one, every mirror write is
  attempted with `tenant: nil` and halts fail-closed (`:tenant_required`) at
  runtime; this gate moves that failure to build time. It is the converse of
  `ValidateMultitenancy` (which checks the shape of a declared discriminator).

### Fixed (closeout review, 2026-07-08 — `/review-autopilot --fix`)

- **Snapshot fails closed on an empty resolver index** — `handle_snapshot/3` and
  `handle_snapshot_complete/2` now share the `handle_transaction/2` fail-closed guard
  (a degenerate/misloaded index no longer silently drops a backfill while advancing
  the checkpoint).
- **`on_truncate :mirror` clears tenant-blind** — was a `TenantRequired` dead-end for
  non-global attribute-multitenant resources; now a quoted raw `DELETE` on the mirror
  table (matching the snapshot redo-safety clear).
- **Full telemetry contract** — the `[:ash_replicant, :snapshot, :batch]` /
  `[:snapshot, :complete]` events (previously never emitted), `:sink,:halted`
  `error_class`, and `:sink,:applied` `change_count` + `duration` measurements are now
  emitted (`change_count` counted single-pass).
- **`transaction?: false`** on the per-record upsert (the sink owns the outer
  transaction the action joins).

### Documented (closeout review)

- **Tenant-scoped source tables must be `REPLICA IDENTITY FULL`** — a tenant-scoped
  delete / PK-changing update resolves the tenant from `old_record`, which is key-only
  under the default replica identity (else the sink halts fail-closed
  `:tenant_required`). Documented in AGENTS Critical Rule 2, the `tenant_attribute`
  DSL doc, README, and usage-rules; locked by a key-only-`old_record` red-gate.

### Optimized (post-closeout, 2026-07-09)

- **Snapshot bulk path computes its reflection once per batch** — the non-tenant
  bulk upsert derives the `{skip, cloak, attribute-name}` reflection a single time
  (`Resolver.upsert_reflection/1` + `Resolver.upsert_input/2`) instead of re-deriving
  it per row; `attrs_for_upsert/2` is retained for single-record callers. Behavior
  unchanged (F13).
- **Delete path is a single atomic `bulk_destroy`** — `Apply.destroy_by_pk/3` issues
  one `DELETE ... WHERE pk` (`strategy: [:atomic, :stream]`, `transaction: false`)
  instead of read-then-destroy, falling back to per-record streaming when a host
  destroy action carries non-atomic changes. The nil-PK fail-closed guard, per-row
  tenant scoping, and idempotent-on-absent-row semantics are preserved (F14).

## [0.1.0] - 2026-07-08

First release: the complete Ash `Replicant.Sink` adapter with effect-once
semantics, fail-closed multitenancy, AshCloak integration, and compile-time
sensitive-column verification.

### Added

- **Ash resource extension** (`AshReplicant.Resource`) — a `replicant do ... end`
  DSL section for marking AshPostgres resources as CDC mirror targets. Options:
  `source_table`, `source_schema`, `tenant_attribute`, `tenant_mfa`, `sensitive`,
  `skip`, `on_truncate`, `on_schema_change`, `upsert_identity`.

- **Checkpoint macro** (`AshReplicant.Checkpoint`) — generates an AshPostgres
  resource backing the `ash_replicant_checkpoints` table (one row per slot,
  tracking the durable `commit_lsn` watermark). Bound to the host's repo and
  domain at compile time.

- **Sink-config macro** (`AshReplicant.Sink`) — generates a `Replicant.Sink`
  implementation with repo, domains, checkpoint resource, and `slot_name` baked in.
  The `slot_name` is the single source of truth for the replication slot (not a
  `start_link` option) and keys the resolver index.

- **Resource resolver** (`AshReplicant.Resolver`) — maps `{schema, table}` pairs
  to resources, built from the sink's domains. The index is cached in
  `:persistent_term` and accessed by the sink's transaction handler.

- **Sink action applier** (`AshReplicant.Apply`) — applies changes to mirror
  resources: upsert by PK, destroy, truncate per policy. Actions are the host's
  own resource actions; the sink invokes them with `authorize?: false` at the
  boundary (the host's Ash policies still guard those actions for application
  callers; the flag exempts only the sink's in-transaction mirror writes from
  re-gating). Tenant is passed per-row.

- **Compile-time verifiers** — enforce critical rules:
  - `ValidateSensitive`: each sensitive column maps to an AshCloak-encrypted
    attribute, a binary-storage attribute, or is skipped.
  - `ValidateMultitenancy`: a multitenant resource with a `tenant_attribute` has
    a plaintext, declared discriminator; the tenant is never classified or skipped.

- **Value-free error & telemetry boundaries** — sink failures and halt paths carry
  structure (error reason, table name, LSN) only. No row values, PKs, tenant names,
  or raw data appear in logs, errors, or telemetry. Column names are strings, never
  atoms.

- **Effect-once transaction model** — each `Replicant.Transaction` applies in one
  `Repo.transaction`: skip by commit-LSN watermark, apply rows, upsert checkpoint
  atomically. Failure rolls back; on resume, un-acked WAL re-streams and dedups
  against the durable checkpoint. Proven by crash-injection tests (loss = 0,
  effect-dup = 0).

- **Documentation** — `CLAUDE.md`, `AGENTS.md`, `README.md`, `CHANGELOG.md`,
  `usage-rules.md`, `CONTRIBUTING.md`, `LICENSE`, `NOTICE`; tracked charter at
  `docs/CHARTER.md` (only `/docs/superpowers/` lifecycle artifacts are local-only).

[Unreleased]: https://github.com/baselabs/ash_replicant/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/baselabs/ash_replicant/tree/v0.4.0
[0.3.3]: https://github.com/baselabs/ash_replicant/commit/3b61d3a9ae553fb96ff26e9fcf581416af723843
[0.3.2]: https://github.com/baselabs/ash_replicant/tree/v0.3.2
[0.3.1]: https://github.com/baselabs/ash_replicant/tree/v0.3.1
[0.3.0]: https://github.com/baselabs/ash_replicant/tree/v0.3.0
[0.2.0]: https://github.com/baselabs/ash_replicant/tree/v0.2.0
[0.1.0]: https://github.com/baselabs/ash_replicant/tree/v0.1.0
