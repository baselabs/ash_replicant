# 17. Snapshot provenance and restart form one atomic protocol

Date: 2026-08-20

## Status

Accepted for implementation in the 1.0.0 release line (roadmap C3).

## Context

Snapshot retries must not repeat host business effects, resurrect a streamed
delete, skip rows, or retire rows outside the managed resource and tenant scope.
Final-state convergence is insufficient: a host create, destroy, or SCD2 close
action may have an append-only local effect even when an upsert later converges
to the same row.

Replicant's actual callbacks do not expose a universal snapshot-attempt id:

- `first_for_table?` identifies the first batch for one table, not the start of
  a whole snapshot attempt, and can be false for the first callback observed
  after incremental resume;
- a V1 `snapshot_lsn` is a PostgreSQL consistent point, not a uniqueness
  guarantee;
- an AshReplicant owner generation is node-local and does not survive the
  restart it would need to classify; and
- incremental stream delivery may commit before the first snapshot chunk.

Incremental completion is an at-least-once empty snapshot callback carrying a
durable progress token. Re-running its retirement scan after a later stream
write would misclassify that newer row as unseen. The completion result therefore
needs a durable replay fence, not only an idempotent final state.

Replicant 1.2.1 is the accepted transport floor for this protocol. It bounds
both PK-less and keyed drop-cap contention at three discarded table attempts and
halts `:snapshot_table_contended`; AshReplicant must prove that fetched behavior
as a black box rather than infer it from module or function presence.

## Decision

### One checkpoint-owned state machine

The source-bound checkpoint row remains the serialization authority for
snapshot chunks, stream transactions, completion, progress, and retirement. It
stores the exact opaque Replicant `snapshot_progress` plus one versioned,
strictly decoded `snapshot_state` envelope with these logical fields:

- mode: V1 or incremental;
- status: armed, active, or complete;
- a cryptographically random 256-bit attempt id;
- a V1-only delivery-run id minted for each `PipelineOwner` activation;
- the source and destination contract digest, including the admitted action
  graph and code identity;
- the provenance HMAC key id; and
- the completed progress-token hash for incremental mode or completed LSN for
  V1 mode.

Attempt ids, delivery-run ids, progress, token hashes, and tenant values are
data-plane values. They never enter errors, logs, or telemetry metadata.

Incremental `snapshot_progress/0` runs a short destination transaction and locks
the checkpoint before Replicant can start the reader and stream:

- absent progress, checkpoint, and state creates an armed attempt and returns
  `nil`;
- a matching armed or active attempt returns its exact durable progress and is
  reused across transport or owner restart;
- a matching complete attempt returns its exact complete progress without
  reactivating membership;
- absent progress with a committed stream checkpoint is a bootstrapped-elsewhere
  path and does not arm a snapshot; and
- an undecodable, impossible, or contract-mismatched pairing fails closed.

The first committed snapshot or stream effect promotes an armed attempt to
active. An empty source may move directly from armed to complete.

For V1, the first actual `handle_snapshot/2` callback binds the current owner's
private delivery-run id to a fresh durable attempt. Later callbacks in that run
reuse it. A newly exported, operator-authorized retry under a later owner rotates
the attempt even when PostgreSQL returns the same consistent point.
`first_for_table?` has no attempt-identity role.

### Two protected row attributes

Every snapshot-capable state resource declares exactly two internal attributes:

- `replica_fingerprint`: a tagged `{key_id, digest}` over the canonical host
  action input; and
- `replica_seen_attempt`: the current attempt id.

Both are binary, non-sensitive metadata with `public?: false` and
`writable?: false`. Compile-time verification rejects any public or explicit
action input path that can accept them. Package-owned private actions stamp them
with internally built changesets and `Ash.Changeset.force_change_attribute/3`.
A host caller cannot forge provenance through `accept :*` or an explicit accept
list.

There is no row-level origin or logical-generation attribute. Membership is the
current attempt marker, while stream-versus-snapshot collision ordering remains
Replicant's responsibility.

The canonical fingerprint is a versioned deterministic encoding of exactly the
mapped values supplied to the host action, plus resolved tenant and resource
identity. Attribute order, type, nil, and container boundaries are explicit;
skipped source columns are excluded. The digest is HMAC-SHA-256 under the
host-managed `:ash_replicant, :snapshot_provenance_keys` map and carries its key
id. Old keys remain available while any open row or incomplete attempt names
them. Missing keys fail closed rather than treating every row as changed and
repeating business effects.

### Snapshot and stream effects

Each kept snapshot row is resolved and applied inside the checkpoint-locked
destination transaction:

1. resolve the tenant and current open target through the admitted action graph;
2. calculate the canonical fingerprint;
3. if the stored fingerprint matches, invoke only the private mark action;
4. otherwise invoke the normal host business action and stamp fingerprint plus
   membership internally; and
5. persist the exact incremental progress token with the row effects.

No snapshot callback clears a whole resource. `first_for_table?` never
authorizes deletion or starts membership.

Every incremental stream insert or update committed while state is armed or
active invokes the normal host action, stamps a fresh fingerprint, and stamps
the current attempt marker in the same transaction. This includes a stream write
before the first snapshot chunk and one committed during a chunk window. A
stream delete destroys or closes normally and leaves nothing to mark. The stream
checkpoint advances atomically with those effects.

### Completion and retirement

Completion locks the checkpoint and first checks its permanent replay fence:

- incremental completion already recorded with the same progress-token hash is
  a no-op before any row scan; and
- V1 completion already recorded for the same delivery run and LSN is likewise
  a no-op.

Otherwise completion requires the matching armed or active attempt and contract,
enumerates every retained destination tenant scope, retires only managed open
rows whose marker differs from the attempt, stores the exact completion progress
or LSN, and commits complete state in the same transaction.

Attribute multitenancy enumerates distinct values of the verifier-approved
plaintext, non-sensitive destination discriminator through the admitted Repo.
Context multitenancy requires an admitted authoritative host read action that
enumerates all retained contexts, including a tenant wholly absent from the
source attempt. Every retirement write invokes the host destroy or close action
with `tenant:` set. Global resources execute one scoped retirement. Missing or
partial enumeration fails closed; no completion write is tenant-blind.

Replicant serializes accepted stream commits and completion at the assembler,
and the checkpoint lock extends that order across nodes. A stream write committed
after completion does not carry the completed marker, but completion redelivery
returns at the replay fence and cannot retire it.

For SCD2, provenance lives on each version. Fingerprint lookup targets the open
version by tenant and business key. An unchanged row is marked without
close/open; a changed row closes through the declared host close action and
opens the new version. Completion closes only unseen open versions and never
changes closed history.

### Drift and operator repair

An incomplete attempt is bound to the source contract, destination manifest,
admitted code identity, provenance-key contract, and Replicant artifact
contract. Resume under drift fails closed. Explicit operator abandonment,
migration, or reset is required; reconnection never guesses that an incompatible
attempt is safe.

The supported completion size must be measured. If one transaction cannot meet
the declared bound, the replacement is a durable retirement cursor whose
effects remain idempotent and whose complete fence is written only after every
scope finishes. The implementation must not silently split the transaction or
claim an unmeasured bound.

## Consequences

- Unchanged V1 and incremental retry rows perform bookkeeping only; append-only
  host business effects are not repeated.
- New and changed rows continue through the host's authoritative Ash actions,
  preserving encryption, tenancy, validations, and declared local participants.
- Snapshot rows, stream rows, provenance, progress, retirement, and checkpoints
  remain inside one admitted Repo transaction.
- Hosts enabling snapshots add two protected attributes and package-owned
  private mark/retire actions; context tenants also provide an authoritative
  retained-scope reader.
- Bookkeeping writes are reported honestly as internal effects and are not
  counted as repeated host business effects.
- V1 failure still requires explicit slot/checkpoint repair before Replicant can
  export a new snapshot. AshReplicant preserves provenance so that authorized
  retry can skip unchanged business actions.

## Required proof before acceptance

- A compile-time guard goes red when either protected attribute becomes
  writable or acceptable through `accept :*` or an explicit action list.
- Incremental tests cover stream-before-first-chunk, stream-during-window,
  insert/update/delete/key change, owner restart, and a never-started resumed
  table.
- Completion commit followed by lost reply, a later stream write, and forced
  completion redelivery preserves the later row without rescanning.
- V1 crash and operator-authorized retry cover same-LSN, unchanged, changed, and
  missing rows with an append-only business-action observer.
- SCD1 and SCD2 prove unchanged rows do not repeat business effects and closed
  SCD2 history remains immutable.
- Attribute and context tenancy include a source-absent tenant and tampered or
  incomplete scope enumeration.
- Progress/state tamper, token mismatch, code/manifest drift, key loss and
  rotation, and operator abandonment fail closed or follow the explicit repair
  path.
- Cross-node checkpoint-lock races and post-completion stream ordering are
  exercised.
- A fetched Replicant 1.2.1 black box proves collision ordering and keyed
  contention exhaustion.
- Mutation tests remove fingerprint comparison, stream marker stamping,
  checkpoint locking, completion replay fencing, tenant scoping, and protected
  input enforcement and observe the named tests go red.
