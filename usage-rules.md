# ash_replicant usage rules

_An Ash adapter for the `replicant` CDC framework — the "`ash_postgres` of
`replicant`."_

## What ash_replicant is (and is not)

- **Is:** an Ash-native CDC mirror / incremental-sync adapter. Resolves resources,
  enforces multitenancy per row, verifies sensitive-column encryption, and applies
  committed streaming transactions to Ash resources with durable effect-once
  semantics.
- **Is not:** the CDC transport itself. That is `replicant`'s job. AshReplicant
  consumes a `Replicant.Sink` interface and owns the Ash-layer semantics
  (resource resolution, multitenancy, encryption, and trusted system action
  execution) above it. The sink uses `authorize?: false`, so host policies are not
  re-gated.
- **Is:** integrated with AshCloak. Sensitive columns must be encrypted by AshCloak
  or stored as binary (user-managed), verified at compile time.
- **Is not:** tenant-aware in the transport — multitenancy is Ash-aware here.
  `replicant` remains tenant-blind and can be used without Ash.

## Host integration — four steps

### 1. Define the checkpoint resource

```elixir
defmodule MyApp.ReplicantCheckpoint do
  use AshReplicant.Checkpoint,
    repo: MyApp.Repo,
    domain: MyApp.Domain
end
```

This generates an AshPostgres resource backing `ash_replicant_checkpoints` (one row
per replication slot, storing the durable `commit_lsn` watermark).

To lock the checkpoint down when the host exposes its domain on a wire surface, pass
`authorizers: [Ash.Policy.Authorizer]` and declare a `policies do` block on the module.
The sink reads/upserts with `authorize?: false`, so policies never gate effect-once;
with the authorizer and no policies the resource is fail-closed to everyone but the sink.
`authorizers:` defaults to `[]` (no behaviour change when omitted).

### 2. Define the sink module

```elixir
defmodule MyApp.ReplicantSink do
  use AshReplicant.Sink,
    repo: MyApp.Repo,
    domains: [MyApp.Shop, MyApp.Billing],
    checkpoint_resource: MyApp.ReplicantCheckpoint,
    slot_name: "shop_orders"
end
```

The `slot_name` is **baked into the sink** and is the single source of truth. It is
**not** a `start_link` option. Every row's mirror action is called with this slot
name as the index key for tenant/resource resolution.

### 3. Mark mirror resources with the extension

Every resource that mirrors a source table adds the extension and a `replicant do
… end` block:

```elixir
defmodule MyApp.Shop.Order do
  use Ash.Resource,
    domain: MyApp.Shop,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "orders"
    repo MyApp.Repo
  end

  replicant do
    source_table "orders"
    source_schema "public"
    tenant_attribute :org_id
    sensitive [:pan, :cvv]
    on_truncate :mirror
    on_schema_change :halt_destructive
    upsert_identity :unique_pk
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, public?: true
    attribute :org_id, :uuid, public?: true
    attribute :amount, :decimal, public?: true
    attribute :pan, :binary, public?: true  # Sensitive: binary storage; stored as-is (host-managed encryption unless AshCloak is added here)
    attribute :cvv, :binary, public?: true  # Sensitive: binary storage; stored as-is (host-managed)
  end

  actions do
    # The extension generates NO action. The mirror writes through this resource's
    # own primary `:create` action (as an upsert) and its `:destroy` action — define
    # them. `create: :*` gives a primary create accepting all public attributes.
    defaults [:read, :destroy, create: :*, update: :*]
  end

  identities do
    identity :unique_pk, [:id]
  end
end
```

**DSL options:**

- **`source_table` / `source_schema`** — source table/schema (defaults to resource's
  own AshPostgres table/schema).
- **`tenant_attribute`** — source column carrying the tenant. Must be a plaintext,
  declared, non-sensitive attribute. Resolved per row and passed as `tenant:` to
  the mirror action. **The source table must be `REPLICA IDENTITY FULL`** — a
  `:delete`, PK-changing `:update`, or same-PK tenant reassignment needs the tenant
  from `old_record`, which is key-only under the default replica identity.
- **`tenant_mfa`** — alternative: `{Module, :function, [extra_args]}` applied as
  `apply(Module, :function, [record | extra_args])` yielding the tenant. It must be
  deterministic and non-raising for both the new and old record shapes. An
  absent/blank/`false` old-side result halts `:tenant_required` (`side=old`) and a
  raising resolver halts `:tenant_resolution_failed` — fail-closed before any write
  (ADR-0001's B4 amendment).
- **Multitenancy block required for either source.** Declaring `tenant_attribute` or
  `tenant_mfa` requires an Ash `multitenancy` block (any strategy — `:attribute`/`:context`,
  incl. `global?`); `ValidateMultitenancy` fails the build closed otherwise. Without a block
  Ash silently ignores the `tenant:` the sink passes and mirrors every tenant unscoped.
  `:context` is the typical pairing for `tenant_mfa`.
- **Multitenancy `:attribute` must be plaintext.** Under `strategy :attribute`, the block's
  own `attribute` is force-set to the plaintext tenant and filtered on read — `ValidateMultitenancy`
  rejects a `sensitive`-classified or binary-storage-typed one (it would mis-scope). (An
  AshCloak-encrypted attribute is rejected by Ash's own multitenancy verifier.)
- **No sink action may bypass tenancy.** `ValidateActionMultitenancy` rejects
  `multitenancy :bypass`/`:bypass_all` on the sink-selected actions of a multitenant resource —
  primary read/create/destroy and the SCD2 close — since Ash would otherwise ignore the tenant
  on a write, or on the `bulk_update`/`bulk_destroy` read that matches rows to close/delete.
  `:enforce` (default) and `:allow_global` are permitted.
- **`sensitive`** — source columns classified as sensitive. Each must map to an
  AshCloak-encrypted attribute, a binary-storage attribute, or be listed in `skip`.
  Never list the `tenant_attribute`.
- **`skip`** — source columns excluded from the mirror write.
- **`on_truncate`** — `:halt` (fail-closed, default) or `:mirror` (direct in-transaction
  DELETE of the mirror table).
- **`on_schema_change`** — `:halt_destructive` (default, halt on destructive DDL)
  or `:ignore`.
- **`upsert_identity`** — identity for the upsert write (defaults to primary-key upsert
  when omitted; set an identity name to upsert by that identity instead).

### 4. Start the pipeline

```elixir
AshReplicant.start_link(
  sink: MyApp.ReplicantSink,
  connection: [hostname: "standby.example.com", database: "source_db"],
  publication: "shop_orders_pub",
  source_identity: [system_identifier: "7378697629483820647", database: "source_db"],
  go_forward_only: true,
  snapshot: false,
  max_inflight_lag: 64 * 1024 * 1024,
  max_command_retries: 5,
  failover: false
)
```

**Options:**

- `:sink` — the sink module (required).
- `:connection` — Postgrex connection options (required). Point at a standby or
  replica to avoid load on the primary.
- `:publication` — Postgres publication name (required).
- `:source_identity` — expected actual replication-session identity (required),
  containing nonempty `:system_identifier` and `:database` strings. A mismatch
  rejects the session before checkpoint lookup with a value-free structural error.
- `:go_forward_only` — passed to `Replicant.start_link/1`.
- `:snapshot` — `false` disables snapshots and `true` selects Replicant's v1
  snapshot. Incremental snapshot options are not supported by this adapter until
  roadmap C3 adds `snapshot_progress/0` and target provenance.
- `:streaming`, `:max_inflight_lag`, `:max_command_retries`, and `:failover` —
  passed through unchanged to Replicant 1.x.

**Key:** the `slot_name` comes from the sink, not `start_link` options. It keys the
active resolver generation and the replication slot name. Start/stop activation is
serialized per slot so a duplicate cannot overwrite or erase the winner's generation.

### SCD2 history mode (optional)

By default a resource mirrors **current state** (`history_strategy :scd1` — upsert /
destroy, the default). Opt a resource into **validity-windowed SCD2 history** with
`history_strategy :scd2`: instead of overwriting, each change **closes the current open
version** (stamps its `valid_to_lsn`) and **inserts a new version**, so the mirror
becomes an append-only history table with one row per `(business_key, valid_from_lsn)`.

```elixir
replicant do
  source_table "orders"
  history_strategy :scd2
  history_business_key [:order_id]     # source natural key (composite supported)
  upsert_identity :version_key         # identity keys: [:order_id, :valid_from_lsn]
  # window-column attributes default to :valid_from_lsn / :valid_to_lsn
  on_truncate :close                   # optional; SCD2-only
end
```

**DSL options (all `:scd2`-only unless noted):**

- **`history_strategy`** — `:scd1` (default, current-state upsert/destroy) or `:scd2`
  (close-current + insert-version).
- **`history_business_key`** — the source natural key (composite supported). Should be
  the source primary key; a **non-PK** business key requires `REPLICA IDENTITY FULL` on
  the source table (see below).
- **`history_valid_from_lsn_attribute`** — bigint attribute stamped with the change's
  `commit_lsn` when a version opens. Default `:valid_from_lsn`.
- **`history_valid_to_lsn_attribute`** — nullable bigint attribute stamped with the
  closing change's `commit_lsn` (nil while the version is open). Default `:valid_to_lsn`.
- **`history_valid_from_timestamp_attribute`** — optional nullable datetime stamped with
  the source `commit_timestamp` when a version opens. Omit to store LSN windows only.
- **`history_valid_to_timestamp_attribute`** — optional nullable datetime stamped with
  the closing `commit_timestamp`.
- **`history_current_attribute`** — optional boolean kept `true` on the open version and
  set `false` on close.
- **`history_close_action`** — the host `:update` action that sets the window columns to
  close a version. Default `:close_version`.

**Host version-table obligations.** A compile-time verifier (`ValidateHistory`) checks
the DSL-visible shape; the index and action bodies are host obligations covered by
integration tests:

- A **surrogate primary key** disjoint from the business key — no business-key attribute
  may be part of the primary key. A primary key equal to or a subset of the business key
  caps the version table at one row per business key (collapsing SCD2); any other overlap
  couples the version identity to a business-key column, so the verifier requires a fully
  disjoint surrogate.
- Declared **integer** (Postgres bigint) `valid_from_lsn` / `valid_to_lsn` window
  columns; `valid_to_lsn` must be `allow_nil?: true` (an open version has no `valid_to`
  yet). A declared timestamp window column must likewise be `allow_nil?: true`.
- A version identity named by `upsert_identity` whose keys are exactly
  `history_business_key ++ [valid_from_lsn]` (the insert-version upsert target).
- The `history_close_action` (`:close_version`) `:update` action, which sets the
  `valid_to` window columns.
- A **partial-unique index** enforcing one open version per business key —
  `UNIQUE (business_key…) WHERE valid_to_lsn IS NULL` (a host DDL obligation, not
  DSL-checked).

**`REPLICA IDENTITY FULL` for a non-PK business key.** Mirroring a close needs the
business key from the change record; on a `:delete` (and a PK/business-key-changing
`:update`) that key is read from `old_record`, which under the Postgres-default replica
identity carries **only the primary-key columns**. If the SCD2 business key is not the
source primary key, set `ALTER TABLE <src> REPLICA IDENTITY FULL` so `old_record`
carries the business-key columns — the same requirement, and the same fail-closed
reason, as a non-PK `tenant_attribute`.

**Tenant reassignment needs the old tenant.** The SCD2 path closes the old tenant's
open version and opens under the new tenant even when the business key is unchanged;
the tenant does not need to be added to `history_business_key`. The source must expose
the old tenant (`REPLICA IDENTITY FULL` for a non-PK tenant column), and a `tenant_mfa`
must resolve both record shapes. If the old tenant is absent or the MFA raises, the
pipeline halts value-free — `:tenant_required` (`side=old`) / `:tenant_resolution_failed`
— rather than guessing a reassignment (ADR-0001's B4 amendment).

**History is retained on delete (soft-close).** A source delete **closes** the current
version (stamps `valid_to_lsn`); it never erases prior versions. SCD2 therefore does
**not** serve a point-erasure / right-to-be-forgotten need — for that, use an SCD1
mirror (which overwrites / destroys) or AshPaperTrail with a pruning policy.

**`on_truncate :close` (SCD2 only).** In place of `:halt` / `:mirror`, an SCD2 resource
may set `on_truncate :close`: an upstream TRUNCATE **closes every open version
tenant-blind** (stamps `valid_to_lsn` on all rows where it is NULL), retiring the whole
window without deleting history. `on_truncate :close` on a non-SCD2 resource is rejected
at compile time.

## Destination transaction boundary

Every admitted destination resource uses the sink's literal AshPostgres Repo and
the same effective dynamic Repo. Admission recursively walks checkpoint, mapped,
relationship, cascade, SCD2, and declared auxiliary actions. It fails before
delivery on a foreign/dynamic Repo, non-Postgres resource, missing action, recursive
participant cycle, or mismatch between the discovered closure and the containing
action's `touches_resources`.

Generated callbacks call the admitted sink implementation directly and cannot be
overridden through an internal effect hook. Admission rejects `SetContext` values
that replace `:data_layer` (a dynamic/MFA context is admissible only when its
module declares `DestinationParticipant`), and AshOnetime-protected participants
must use `AshOnetime.Cache.None` so cache work cannot escape rollback.

Custom changes, validations, preparations, manual actions, callbacks, types, and
tenant resolvers implement `AshReplicant.DestinationParticipant` and return either
`:no_database` or literal resource/action references:

<!-- ash-replicant-destination-participant-example:start -->
```elixir
defmodule MyApp.UsageRulesReceiptParticipant do
  @behaviour AshReplicant.DestinationParticipant

  alias AshReplicant.DestinationParticipant.{ActionRef, Context, ReplayIdentity}

  @impl AshReplicant.DestinationParticipant
  def destination_participants(_opts, %Context{}) do
    {:ok,
     {:actions,
      [
        %ActionRef{
          resource: MyApp.MirrorReceipt,
          action: :record,
          replay_identity: %ReplayIdentity{
            participant: :mirror_receipt,
            components: [
              :source_system_identifier,
              :source_database,
              :slot_name,
              :commit_lsn,
              :ordinal,
              :participant
            ]
          }
        }
      ]}}
  end
end
```
<!-- ash-replicant-destination-participant-example:end -->

Declarations are trusted metadata; they do not prove an arbitrary Elixir body.
Never conceal raw SQL, another Repo, asynchronous work, or an external effect
behind one. The containing action's `touches_resources` must exactly equal the
resources reached through all providers.

An auxiliary action that needs replay protection may use AshOnetime only as local
idempotency committed with the action in the admitted Repo. It must be
transactional, fail closed on store failure, accept a private non-null string
`operation_key`, use the exact versioned participant scope, and derive its key with
`AshReplicant.DestinationParticipant.operation_key/2` — the context the sink
supplies carries a per-invocation label (`invocation:`) that the derivation
REQUIRES; manual minters (tests, replay probes) must pass the label the sink
mints at that effect site (`:close_prior | :close_current | :open |
:destroy_prior | :upsert`). AshOnetime one-time nonces
are rejected for WAL replay. Independent commits, external effects, opaque stores,
and incomplete replay identities are rejected.

A Replicant v1 snapshot batch is atomic, but an incomplete multi-batch restart can
physically repeat already committed batch effects. The v1 target is cleared and
rebuilt, so final-state convergence is not proof of zero physical repeats. Roadmap
C3 owns zero-repeat v1 and incremental restart. Message, sink-owned batch,
incremental-progress, and append-log callbacks remain absent until C1 through C4.

## Source-bound checkpoints, binding, and operator recovery

The durable checkpoint row is keyed by the ACTUAL replication session's
identity — `(source_system_id, source_database, slot_name)` — with the session
timeline recorded beside it and the canonical contract manifest (what the
adapter maps) plus its fingerprint stored on the row
([ADR-0007](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/docs/adr/0007-source-bound-checkpoint-effect-once.md)).

On every connect, before any checkpoint read, the sink binds the row under the
per-slot lease: a foreign identity under the same slot name, a changed
timeline, a watermark beyond the session's WAL flush position, or an
incompatible contract transition halts the pipeline fail-closed with a
value-free reason and one `[:ash_replicant, :checkpoint, :conflict]` telemetry
event. Every halt is an explicit operator decision — there is no fail-open
path. A halted pipeline does not restart itself (`:temporary`); restart it
after resolving the halt and the identity gate re-binds.

Contract transitions follow a set-monotone rule: ADDING a relation, a
brand-new column, or an ignore advances automatically (the manifest is
replaced atomically, the watermark untouched); changing or removing anything
already recorded — re-targeting a column, changing a type or tenant source,
un-skipping a recorded skip, changing the publication — halts.

Operator recovery surfaces:

- `AshReplicant.adopt_checkpoint(sink, source_identity, commit_lsn)` — adopt a
  preserved legacy watermark into a source-bound row (offline; idempotent;
  refuses when a different identity owns the slot name).
- `AshReplicant.reset_checkpoint(sink, source_identity)` — destroy the bound
  row (incompatible transition or identity rebind; you accept re-delivery or
  re-snapshot). On an SCD2 mirror, pair a reset with a full re-snapshot —
  bare re-delivery re-closes closed versions and halts mid-replay.
- `AshReplicant.acknowledge_checkpoint_timeline(sink, source_identity,
  timeline_id)` — after a `:source_timeline_changed` halt on a same-primary
  crash restart (the new timeline replays the old WAL), re-bind the recorded
  timeline without touching the watermark. After a failover you cannot prove
  continuous, reset instead.

## Upgrading from the slot-only checkpoint

Pre-0.4.0-shaped tables (slot-only primary key) carry no recorded source
identity, so no automatic adoption is possible — the shipped rows are exactly
the ambiguous class:

1. Stop the pipeline. Call
   `AshReplicant.Checkpoint.Identity.legacy_checkpoint_row_count/1` — a
   non-zero count blocks the migration (the migration itself also refuses
   surviving rows).
2. Capture each row's `(slot_name, commit_lsn)`.
3. Delete the legacy rows.
4. Regenerate and run your migration (`mix ash.codegen` + `mix ecto.migrate`).
5. Per slot, `AshReplicant.adopt_checkpoint/3` with the captured watermark and
   the source's ACTUAL identity (`SELECT system_identifier::text,
   current_database() FROM pg_control_system()`). A slot that should
   re-snapshot from zero is simply not adopted.
6. Restart; the first connect fills the contract without touching the adopted
   watermark.

## Source coverage, ignores, and replica identity

Every publication table must be mapped, explicitly ignored, or the pipeline
refuses to start; every delivered column must be mapped or skipped, or the
pipeline halts before writing ([ADR-0008](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/docs/adr/0008-strict-source-coverage.md)).
The preflight runs at activation on a short-lived identity-verified source
connection and re-runs the table-membership check at every reconnect.

- **Partial publications** (tables you do not mirror) must declare them:
      use AshReplicant.Sink,
        ignored_sources: ["public.audit_events"]
  Strictly qualified `schema.table` strings; bare names and duplicates are
  compile errors; an ignore colliding with a mapped resource fails
  activation. Column-level ignoring is the resource-level `skip` list.
  Ignores are standing intent — their hygiene is yours; the doctor surface
  (roadmap D2) will report never-matching entries as a warning.
- **Source columns** must all be mapped or skipped. A source `ADD COLUMN`
  halts the first changed row (`:source_column_unmapped`) until you map or
  skip it. A declared column that vanishes, or a `skip` naming a column that
  does not exist, halts at activation.
- **Column types** are checked against the target attribute at activation
  (`:source_type_invalid`); custom target types are not judged statically —
  the runtime cast stays per-row fail-closed.
- **REPLICA IDENTITY FULL** is enforced at activation on every
  tenant-scoped mapped table and every SCD2 table whose business key is not
  the source primary key (`:source_replica_identity`); a mid-stream identity
  or type change always halts, never ignorable via `on_schema_change
  :ignore`.
- **Boot ordering**: a source unreachable at activation defers the coverage
  verdict (the pipeline starts and paces reconnects); the verdict renders on
  the first reachable connection — before any checkpoint advance.

## Tenant reassignment is fail-closed

On a tenant-scoped mirror, every update and delete resolves BOTH the old and
new tenant before any write. An absent, blank, `false`, or raising old-side
resolution halts (`:tenant_required` / `:tenant_resolution_failed`,
`shape: "side=old"`) — an update whose `old_record` is missing entirely (the
DEFAULT-identity shape) halts too. Same-tenant updates apply normally;
reassignment relocates the row (SCD1) or terminally closes the old-tenant
version and opens the new one (SCD2). This is safe to require precisely
because the preflight enforces FULL identity, so `old_record` carries the
tenant on every update and delete (an unchanged TOASTed discriminator still
halts — do not TOAST your tenant column).

## Non-negotiable rules

- **Route writes through Ash actions.** The mirror writes through the host resource's
  OWN primary `:create` action (as an upsert) and its `:destroy` action — the extension
  generates neither, you define them. The sink calls them with `authorize?: false`, so
  AshCloak encryption and multitenancy scoping still fire (policies are not re-gated).
  Direct Ecto bypasses AshCloak and tenancy — never do it.

- **Fail-closed multitenancy.** A nil/`false`/blank tenant on a multitenant resource is an
  error (`false` too — Ash treats a falsy tenant as unscoped). No silent base-tenant fallback.
  The mirror action's `tenant:` option triggers Ash's multitenancy DSL; if tenant validation
  fails, the write fails and the transaction rolls back. A declared `tenant_attribute` or
  `tenant_mfa` **requires an Ash `multitenancy` block** — `ValidateMultitenancy` rejects a
  source with no block at compile time, since Ash would otherwise silently ignore `tenant:` and
  mirror every tenant unscoped.

- **Sensitive = AshCloak-encrypted or binary or skip.** Every source column listed
  in `sensitive` must map to one of: (1) an Ash attribute with AshCloak encryption
  (the verifier detects it), (2) a binary-storage attribute (user-managed
  encryption), or (3) listed in `skip` (excluded from mirror). The compile-time
  verifier enforces this; a violation is a build error, not a runtime surprise.
  AshCloak is the single encryption source of truth.

- **No row value in error/log/telemetry.** Assume every value is PII or a secret.
  Sink failures and halt paths carry structure (error reason, table name, LSN) only
  — never the column value, PK, tenant name, or offending data. Column names are
  strings, never atoms.

- **Streaming effect-once is one transaction + watermark dedup.** Every committed
  streaming transaction applies in a single `Repo.transaction`: skip any change
  whose `commit_lsn <= checkpoint`, apply rows, upsert checkpoint atomically. On
  failure, the transaction rolls back; on resume, un-acked WAL re-streams and
  dedups. The snapshot restart limitation above remains explicit until C3.

## Relationship to `replicant`

`replicant` is the CDC transport layer — tenant-blind, Ash-agnostic. It owns the
Postgres logical replication slot, the `pgoutput` protocol, transaction assembly,
WAL ordering, and acknowledgement after sink success. AshReplicant owns its durable
commit-LSN checkpoint and persists it with the Ash effects.

AshReplicant consumes a `Replicant.Sink` interface and layers Ash semantics on top:
resource resolution, tenant routing, sensitive verification, host actions, and the
atomic checkpoint. Host policies are not re-gated.

Never add multitenancy or classification logic to `replicant`. The split is the
reason they are separate libraries.

## See also

- **`AGENTS.md`** — the working guide with critical rules (binding).
- **`replicant` usage-rules** (`../replicant/usage-rules.md`) — CDC framework contract.
- **`CHANGELOG.md`** — version history.
