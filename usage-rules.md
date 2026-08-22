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

## Installing

`mix igniter.install ash_replicant` (or, when the dependency is already present,
`mix ash_replicant.install`) generates the domain, checkpoint, sink, and pipeline
supervisor, registers the domain in `:ash_domains`, supervises the pipeline,
imports AshReplicant's formatter metadata, and queues
`mix ash.codegen install_ash_replicant`. Igniter is an **optional** dependency;
the manual equivalent is in the README under "Manual installation" and is tied
to the installer's real output by a test.

Two properties matter when reasoning about a generated project:

- **The installer writes no connection, publication, source identity, or key
  material.** The generated `MyApp.Replicant.Pipeline` therefore supervises
  NOTHING until `config :my_app, MyApp.Replicant.Pipeline` supplies the operator's
  facts — a fresh install compiles and boots as a no-op. A configuration that is
  present but missing `:connection`, `:publication`, or `:source_identity` RAISES,
  naming the missing keys and never their values; supervising nothing would be a
  silent outage.
- **The installer refuses rather than guesses.** Malformed module names; an
  illegal slot; a missing, ambiguous, unknown, or non-AshPostgres repo;
  incomplete project facts; a foreign target module; an unreadable existing
  binding; or a checkpoint, sink, or pipeline bound to another identity each
  stop the install having written nothing. Never route around a refusal by
  deleting the existing module: a sink's slot name keys its durable checkpoint
  identity, and re-keying it abandons the watermark.

Re-running the installer over an installed project changes nothing.

## Host integration — four steps

### 1. Define the checkpoint resource

```elixir
defmodule MyApp.ReplicantCheckpoint do
  use AshReplicant.Checkpoint,
    repo: MyApp.Repo,
    domain: MyApp.Domain
end
```

This generates an AshPostgres resource backing `ash_replicant_checkpoints`: one
row per replication SOURCE and slot — keyed by `(source_system_id,
source_database, slot_name)` from the actual replication session's identity —
carrying the durable `commit_lsn` watermark (see
[ADR-0007](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0007-source-bound-checkpoint-effect-once.md)).

The generated resource is **default-deny** (ADR-0014): it carries
`Ash.Policy.Authorizer` with an empty policy set, forbidding every external actor on
every action. The sink reads/upserts with `authorize?: false`, so policies never gate
effect-once. To grant access, declare a `policies do` block on the module; to
reproduce the earlier unguarded shape, pass `authorizers: []`.

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

### Logical-message routing (optional, C1)

`pg_logical_emit_message` output routes by prefix to host create actions
([ADR-0015](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0015-logical-message-effects.md)):

```elixir
use AshReplicant.Sink,
  repo: MyApp.Repo,
  domains: [MyApp.Shop, MyApp.Messaging],
  checkpoint_resource: MyApp.ReplicantCheckpoint,
  slot_name: "shop_orders",
  message_routes: [{"mail", MyApp.MailOutbox, :record}],
  ignored_message_prefixes: ["telemetry_noise"]
```

Rules that are enforced, not advisory:

- Every routed action is a `:create` action carrying the closed AshOnetime
  message profile: `strategy :idempotency`, `fail_closed` store, the private
  `operation_key` / `content_digest` arguments, an accepted `content` string
  attribute, `fingerprint(arguments: [:content_digest])`, and a declared
  positive `retention`. An optional `external_effect` module (three-state
  recovery) is admitted on message routes ONLY. A nonce is rejected — it must
  never gate WAL re-delivery.
- Set `:ash_replicant, :message_digest_keys` (list of `{version, key}` with
  unique positive versions and keys ≥ 16 bytes). The active version (highest)
  mints new digests; RETAIN the old versions through the claim/recovery
  lifetime — re-delivery replays through them after rotation.
- A **transactional** message rides its transaction, interleaved with the row
  changes by ordinal. A **standalone** message applies effect + claim +
  watermark in one destination transaction (local route) or through recovery
  with the watermark advancing only after finalized/replayed success (external
  route). An unknown prefix halts the pipeline fail-closed
  (`:message_prefix_unmapped`); an ignored prefix acknowledges with no effect.

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
  census: [interval_ms: 60_000, jitter_ratio: 0.1, timeout_ms: 10_000],
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
- `:snapshot` — `false` disables snapshots, `true` selects Replicant's v1
  snapshot, and `[mode: :incremental, chunk_rows: n, max_pending_chunks: n]`
  selects sink-owned incremental backfill. Both modes are physically effect-once
  for resources declaring `snapshot_provenance true` (ADR-0017); incremental
  activation requires every mapped resource to opt in.
- `:streaming`, `:max_inflight_lag`, `:max_command_retries`, and `:failover` —
  passed through unchanged to Replicant 1.x.
- `:census` — continuous invariant checks owned by the `PipelineOwner`. Closed
  keys: `enabled?` (default `true`), `interval_ms` (default `60_000`),
  `jitter_ratio` (default `0.1`), `timeout_ms` (default `10_000`), and
  `max_consecutive_faults` (default `3`). Unknown keys/types and out-of-range
  bounds reject activation with `:census_options_invalid`. Exact bounds are
  `interval_ms: 50..86_400_000`, `jitter_ratio: 0.0..0.5`,
  `timeout_ms: 1..60_000`, and `max_consecutive_faults: 1..1_000`.

**Key:** the `slot_name` comes from the sink, not `start_link` options. It keys the
active resolver generation and the replication slot name. Start/stop activation is
serialized per slot so a duplicate cannot overwrite or erase the winner's generation.

### Continuous invariant census

The owner schedules one jittered census only after the previous run has
finished or timed out. A run enters through the same admitted callback guard as
delivery, including owner-liveness checks and dynamic-Repo pinning, then checks
the live destination generation, rebuilt source contract, durable bound
checkpoint/contract fingerprint, and full source publication/column/type/RIF
coverage. There is no second poller or Replicant callback.

Any drift halts the temporary pipeline immediately and freezes checkpoint
advance. Source/Repo faults and checker timeouts are typed non-pass results; a
healthy run resets the counter, while the exact configured consecutive fault
halts with `:census_unverifiable`. Census telemetry carries only `slot_name`,
the structural check `kind`, and a frozen reason atom. It never carries contract
bytes, source identity values, row values, tenants, message prefixes, or client
exception text.

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

### Notifiers with a dependency pre-load

The sink suppresses notification DISPATCH for mirrored changes, but not the
dependency pre-load: Ash runs a notifier's load statement after every
successful create/destroy regardless. A non-empty statement therefore executes
host reads *inside* the sink's delivery transaction.

Ash re-derives that statement by calling `load/2` again at delivery, so an
admission-time probe binds nothing on its own — a `load/2` that reads
application config, process state, or the clock can be empty when the manifest
is built and non-empty when the sink delivers. A notifier attached to a
mirrored resource whose statement is non-empty must therefore do BOTH:

1. declare `AshReplicant.DestinationParticipant` (the `:notifier` kind), and
2. route its statement through `AshReplicant.Notifier` — replace `load/2` with
   `preload/2` and let the wrapper define `load/2`:

<!-- ash-replicant-notifier-wrapper-example:start -->
```elixir
defmodule MyApp.UsageRulesOrderNotifier do
  use Ash.Notifier
  use AshReplicant.Notifier

  @behaviour AshReplicant.DestinationParticipant

  alias AshReplicant.DestinationParticipant.{ActionRef, Context}

  @impl Ash.Notifier
  def notify(_notification), do: :ok

  @impl AshReplicant.Notifier
  def preload(_resource, _action), do: [:total]

  @impl AshReplicant.DestinationParticipant
  def destination_participants(_opts, %Context{resource: resource, action: action})
      when action != :read do
    {:ok, {:actions, [%ActionRef{resource: resource, action: :read}]}}
  end

  def destination_participants(_opts, _context), do: {:ok, :no_database}
end
```
<!-- ash-replicant-notifier-wrapper-example:end -->

`use Ash.Notifier` must come first. Inside a sink delivery the generated
`load/2` compares the statement — and the participant declaration's action
closure — against what the live generation admitted, and only then hands that
exact statement to Ash; drift halts before the dependency query runs. On the
host's own writes it is an ordinary Ash notifier. Admission verifies the live
callback entered that wrapper on both stability probes; do not make the
generated `load/2` overridable, because a replacement is rejected even if the
module still carries the wrapper behaviour marker.

Admission rejects the ways this can be wrong, naming resource, action, and
notifier: `:destination_notifier_required` (no declaration),
`:destination_notifier_unwrapped` (declared, but raw `load/2`), and
`:destination_notifier_unstable` (a statement or declaration that will not
reproduce itself between two consecutive calls). At delivery the sink's own
check adds `{:invalid_destination_config, :notifier_load_drift |
:notifier_load_unadmitted | :notifier_load_probe_failed}` for what the wrapper
cannot see — chiefly a notifier whose statement was empty at admission and is
not any more.

A notifier with no load statement needs none of this and is unchanged.

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
:destroy_prior | :upsert | :message | :mark_seen | :retire_unseen`). AshOnetime one-time nonces
are rejected for WAL replay. Independent commits, external effects, opaque stores,
and incomplete replay identities are rejected.

V1 retry and incremental resume are physically effect-once for opted-in resources:
the keyed fingerprint suppresses repeated host actions, while incremental chunks
commit the exact progress token, row effects, membership, and durable ordinal cursor
in one checkpoint-locked destination transaction. Message (C1), sink-owned batch
delivery (C2 — `batch_delivery` routes flushes through `handle_batch/1`, one
destination transaction and one trailing watermark write per batch),
incremental snapshot progress (C3), and append-log delivery (C4 — `sink_kind/0`
plus `handle_slot_origin/2`) are live.

## Append-log mode (the event contract)

A generated sink is EXCLUSIVELY a state mirror or an append log; Replicant
exposes `sink_kind/0` per SINK, not per resource, so a mixed resource set cannot
be represented by the transport callback and activation rejects it
(`:sink_kind_mixed`).

```elixir
use AshReplicant.Sink,
  repo: MyApp.Repo,
  domains: [MyApp.Events],
  checkpoint_resource: MyApp.ReplicantCheckpoint,
  slot_name: "shop_events",
  sink_kind: :append_log,
  initial_state: :go_forward   # or :snapshot — REQUIRED for an append sink
```

`initial_state` is the sink's ONE declared initial-state intent and must agree
with the `snapshot:` start option, or activation fails
`:initial_state_mismatch`. `:go_forward` is what generates
`handle_slot_origin/2`.

### The host-owned append target

This package generates NO event table, migration, or raw write path. Declare on
your own AshPostgres resource:

```elixir
replicant do
  source_table "orders"
  append_log true
  on_truncate :append          # `:halt` (default) or `:append`
end
```

and provide, under the configured names (defaults shown):

| Option | Default | Storage | Role |
|---|---|---|---|
| `append_source_system_attribute` | `:source_system_id` | `:string` | identity axis |
| `append_source_database_attribute` | `:source_database` | `:string` | identity axis |
| `append_slot_attribute` | `:slot_name` | `:string` | identity axis |
| `append_commit_lsn_attribute` | `:commit_lsn` | `:integer` (bigint) | identity axis |
| `append_ordinal_attribute` | `:ordinal` | `:integer` | identity axis |
| `append_operation_attribute` | `:operation` | `:string` | source operation |
| `append_origin_attribute` | `:origin` | `:string` | delivery origin |
| `append_attempt_attribute` | `:snapshot_attempt` | binary | backfill attempt |
| `append_message_prefix_attribute` | `:message_prefix` | `:string` | routed message prefix |
| `append_message_content_attribute` | `:message_content` | binary | routed message content |
| `append_action` | `:append` | — | the IMMUTABLE `:create` delivery action |
| `append_identity` | `:append_identity` | — | identity over the five axes |

Plus the mapped payload attributes — ordinary source columns under the same
`skip`, `sensitive` and tenant rules a state mirror uses.

### What the compile-time verifier enforces

`ValidateAppendLog` rejects, at build time:

- a missing structural attribute, one whose storage is wrong for its role, one
  marked `sensitive?: true`, one listed in `sensitive`, or a structural attribute
  other than `snapshot_attempt` that is nullable;
- a missing append action, an append action that is not a `:create`, one that
  declares its OWN upsert (that would replace the sink's conflict target and let
  a duplicate delivery mutate a stored event), or one that fails to accept a
  structural attribute; manual actions and arbitrary action or global create
  changes are rejected because they can replace the insert or rewrite an identity
  axis after validation (AshCloak encryption of non-structural payload is the sole
  admitted change);
- an append identity that is missing, or whose keys are not EXACTLY the five
  axes — a narrower key makes two distinct same-transaction effects collide, a
  wider one lets a replay append twice;
- an attribute-multitenant target whose append identity omits `all_tenants?
  true` (Ash would otherwise prepend the tenant discriminator to the conflict
  target, so it no longer matches the five-column unique index);
- `history_strategy :scd2`, `snapshot_provenance true`, or `on_truncate
  :mirror` / `:close` on an append target — all of them UPDATE or DELETE rows a
  log must never touch;
- `on_truncate :append` beside a declared tenant source (a TRUNCATE is
  tenant-blind and carries no row to resolve a tenant from), and `on_truncate
  :append` on a state-mirror resource.

One obligation is NOT compile-checkable: a source column sharing a name with a
structural attribute. The verifier does not know the live source columns, so
that collision halts value-free at delivery (`:config_invalid`) before any
append.

### Operation shapes

| change | `operation` | `origin` | payload |
|---|---|---|---|
| insert | `"insert"` | `"stream"` | the new record |
| update | `"update"` | `"stream"` | the new record |
| delete | `"delete"` | `"stream"` | the admitted OLD record |
| truncate | `"truncate"` | `"stream"` | none — structural |
| message | `"message"` | `"stream"` | routed prefix and binary content |
| snapshot | `"snapshot"` | `"snapshot"` | the row, plus the attempt id |

A delete appends the complete old record, so **every append source table requires
`REPLICA IDENTITY FULL`**, tenant-scoped or not. DEFAULT identity carries only
primary-key columns and would silently append an incomplete delete event.

For an append sink, each `message_routes` entry must target the configured
append action on a non-tenant append resource. The action must accept the
configured message prefix/content attributes; content must use binary storage.
Transactional messages use the transaction commit LSN and their shared ordinal;
standalone messages use their WAL LSN and ordinal zero. These two attributes are
destination-only and coverage never expects them on the source table.
State-mirror message routes retain ADR-0015's AshOnetime profile unchanged.

### Append-once, and what it rests on

Delivery runs `upsert?: true` against `append_identity` with an EMPTY
`upsert_fields`, which AshPostgres renders as a no-op conflict clause. A
lawfully re-delivered WAL position appends ONCE and the stored payload is never
overwritten. Back the identity with a real unique index — it is the defensive
database constraint. Effect-once itself is unchanged: the append and the
checkpoint commit in ONE locked destination transaction.

### The origin floor

A `:go_forward` append sink writes the slot origin it first started from to the
checkpoint's `origin_floor`, once, on its first admitted activation. **No
completeness claim covers data before that floor.** Later reconnect origins are
moving resume facts, never replacement floors:

- a slot CREATED this session arriving at a log that already claims a floor
  halts `:append_origin_gap` — the previous slot is gone, so PostgreSQL no
  longer retains the WAL between the log's frontier and the new consistent
  point;
- an appended event above the durable checkpoint halts
  `:append_frontier_divergent` — they commit together, so that can only be a
  torn write.

Replicant does not filtered-WAL idle-advance an `:append_log` sink. The gap check
therefore compares a reused origin directly to the durable watermark: any higher
origin was advanced by another consumer or operator and halts `:append_origin_gap`
before streaming. On a quiet append publication in a busy cluster, publish a
normal heartbeat transaction to advance the checkpoint and release retained WAL.

### Boundaries

- An append sink cannot run INCREMENTAL snapshots: that mode requires
  `snapshot_provenance true` on every mapped resource, which an append target
  may not declare (`:snapshot_unsupported`).
- A `strategy :context` append target is refused on a go-forward sink
  (`:append_frontier_unavailable`): its per-tenant schema leaves no
  statically addressable table to read a tenant-spanning frontier from.
- A `:snapshot`-intent append sink needs `:ash_replicant,
  :snapshot_provenance_keys` configured — the backfill attempt id lives in the
  checkpoint's authenticated state envelope. Activation fails closed without it.
- Separate mirror and append pipelines may use separate slots and checkpoints.
  One slot is not claimed to serve both sink kinds.

## Snapshot provenance and retirement (the row contract)

A snapshot retry must not repeat a host business effect for a row that did not
change. Converging to the same final state is not enough: a create, destroy, or
SCD2 close can carry an append-only local effect even when a later upsert
converges. So a snapshot-managed resource stores a keyed fingerprint of the
values its host action was given, plus a marker for the attempt that last saw
the row ([ADR-0017](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0017-snapshot-provenance-and-restart.md)).

The **V1 and incremental protocols that read this contract are live**. V1 binds
one checkpoint-owned attempt per delivery run. Incremental `snapshot_progress/0`
arms one durable attempt before reader/stream start, persists exact progress and
the operation-key cursor with every chunk, stamps concurrent stream writes, and
uses a completion-token hash as a permanent no-rescan fence.

> **Opting in is what buys you retirement.** No snapshot callback clears a
> resource any more (see the migration note at the end of this section). A
> snapshot-backed resource that does NOT declare `snapshot_provenance true`
> keeps rows the source has dropped, because there is no membership marker to
> retire them by.

### Opting a resource in

```elixir
replicant do
  source_table "orders"
  snapshot_provenance true
end

attributes do
  # ... your mirrored columns ...
  attribute :replica_fingerprint, :binary, public?: false, writable?: false
  attribute :replica_seen_attempt, :binary, public?: false, writable?: false
end

actions do
  defaults [:read, :destroy, create: :*, update: :*]

  update :replicant_mark_seen do
    public? false
    accept []
    require_atomic? false
    change AshReplicant.Snapshot.MarkSeen
  end

  destroy :replicant_retire_unseen do
    public? false
  end
end
```

`snapshot_provenance` defaults to `false`, so a resource that does not back a
snapshot needs no change at all.

Under `history_strategy :scd2` the retirement action is an `:update` (it closes
the open version) rather than a `:destroy` — closed history stays immutable:

```elixir
update :replicant_retire_unseen do
  public? false
  accept [:valid_to_lsn]
end
```

Both action names are configurable via `snapshot_mark_action` and
`snapshot_retire_action`.

Under **`strategy :context` multitenancy** (non-global) you must also declare a
retained-scope enumerator. Completion retires per tenant scope and never
tenant-blind; attribute multitenancy enumerates itself from its discriminator
column, but context multitenancy has none, so your application is the only
authority on which scopes exist — including a tenant wholly absent from the
source snapshot:

```elixir
replicant do
  # ...
  snapshot_provenance true
  snapshot_tenant_scope_action :replicant_retained_scopes
end

actions do
  action :replicant_retained_scopes, {:array, :string} do
    public? false
    run MyApp.RetainedTenants
  end
end
```

It is a private generic action returning `{:array, _}`. Because it is custom
code the adapter cannot inspect, its `run` module declares
`AshReplicant.DestinationParticipant` like any other. A missing, raising, or
malformed enumeration — including one carrying a blank scope, which Ash would
treat as NO tenant — fails completion closed with
`:snapshot_scope_incomplete`.

### What the compile-time verifier enforces

`AshReplicant.Resource.Verifiers.ValidateSnapshotProvenance` fails the build
(a Spark diagnostic, build-blocking under `--warnings-as-errors`) unless:

- both protected attributes exist, are binary-storage, `public?: false`,
  `writable?: false`, and are not classified sensitive (they carry no row
  value — never list them in `sensitive`);
- **no action accepts either one**, and no action declares an argument named
  for either one. Both are input paths, and either would let a host forge
  membership so a changed row looks "already seen";
- the mark action exists, is a private (`public? false`) `:update`, and is the
  **only** owner of `change AshReplicant.Snapshot.MarkSeen`; the verifier rejects
  that change on every other action and in the global `changes` block, because
  either path could stamp ordinary host business updates;
- the retirement action exists, is private, and is a `:destroy` under `:scd1`
  or an `:update` under `:scd2`.

On a multitenant resource, both actions are treated as sink-selected actions by
`ValidateActionMultitenancy`, so neither may declare `multitenancy :bypass` or
`:bypass_all`.

`AshReplicant.Snapshot.MarkSeen` is the only write path to the two attributes.
It reads them from the sink-supplied changeset context and writes through
`Ash.Changeset.force_change_attribute/3`; an absent or malformed context fails
the changeset closed rather than silently marking nothing.

### Provenance keys

The fingerprint is an HMAC-SHA-256 under host-managed keys, tagged with both
the canonical encoding version and the key version:

```elixir
config :ash_replicant,
  snapshot_provenance_keys: [{1, System.fetch_env!("ASH_REPLICANT_PROVENANCE_KEY_V1")}]
```

Same shape as `:message_digest_keys`: a non-empty list of
`{positive_integer_version, binary_key}` with unique versions and keys of at
least 16 bytes. The highest version is ACTIVE; lower versions are RETAINED.

**Rotate by adding, never by replacing.** Keep an old version as long as any
row or incomplete attempt still names it. Dropping a key that rows still name
fails closed — comparison returns an error rather than reporting every row as
changed, because reporting "changed" would re-run every host business action.

If any mapped resource declares `snapshot_provenance true`, activation
preflights this configuration and refuses to start without it.

### How a V1 retry behaves

The checkpoint row carries one versioned, HMAC-authenticated `snapshot_state`
envelope: the attempt id, the delivery run that owns it, the admitted contract
digest, and the completion replay fence. Everything below happens under that
row's `FOR UPDATE` lock, so chunks, completion and retirement serialize against
each other across nodes.

1. **Binding.** Each `AshReplicant.PipelineOwner` activation mints a random
   256-bit delivery run. The first actual `handle_snapshot/2` callback of a run
   binds it to a fresh random attempt; later callbacks reuse it. An
   operator-authorized re-export under a LATER owner rotates the attempt even
   when PostgreSQL hands back the same consistent point — `first_for_table?`
   plays no part in attempt identity, and authorizes no deletion.
2. **Per row.** Resolve the tenant and the current open target, recompute the
   fingerprint, and on a match invoke ONLY the private mark action. A changed or
   new row runs the normal host business action and is then stamped. Marking is
   an internal effect and is reported as one; it is not a host business effect.
3. **Completion.** Check the replay fence first — a completion already recorded
   for this delivery run and LSN returns BEFORE any row scan, so a redelivered
   completion cannot retire a stream write that landed after the original.
   Otherwise enumerate every destination tenant scope, retire the managed open
   rows whose marker differs through your retire action with `tenant:` set,
   advance the watermark, and commit `complete` state — one transaction.

An attempt is bound to the admitted contract (sink config, destination
manifest, code identity, source contract). Resuming under drift fails closed
with `:snapshot_state_invalid`; so does a tampered or undecodable envelope.
Under SCD2, retirement CLOSES the unseen open version and never touches closed
history.

### How incremental resume behaves

Configure Replicant's sink-owned mode only after every mapped resource has the
row contract above:

```elixir
AshReplicant.start_link(
  # sink, connection, publication, source_identity ...
  go_forward_only: false,
  snapshot: [mode: :incremental, chunk_rows: 1_000, max_pending_chunks: 4]
)
```

1. **Prepare.** Replicant calls `snapshot_progress/0` before it can start the
   reader or stream. Under the checkpoint lock, absent state mints an `armed`
   attempt and returns `:backfill_pending`; an armed/active attempt with no first
   chunk token returns the same marker after restart. Otherwise resume authenticates
   and returns the exact token already committed. A complete token returns without
   reactivating membership or re-checking the current admitted contract. Impossible
   progress/state pairings, incomplete-attempt drift, tamper, or a missing retained
   key fail closed.
2. **Chunk.** Each `handle_snapshot/2` chunk reads the active attempt, applies
   fingerprint-gated rows, advances the durable operation-key ordinal cursor,
   and stores the exact opaque `context.progress` plus its authenticated hash in
   the same destination transaction. A fault commits none of those effects.
3. **Concurrent stream.** Every streamed insert/update committed while the
   attempt is armed or active runs the normal host action, then stamps its new
   fingerprint and the same membership marker before the stream watermark
   advances. Deletes remove or close normally. Replicant 1.2.2's collision
   window makes the later stream image win.
4. **Complete.** Replicant sends one empty `handle_snapshot/2` callback with
   `backfill_complete?: true`. Completion retires unseen open rows, stores the
   exact complete token and matching progress/completion hashes, and does not alter
   the stream watermark. Redelivery of that token returns before any scan,
   including after a later stream write or admitted-contract deployment.

The fetched Replicant 1.2.2 contract bounds keyed and keyless contention at
three discarded table attempts, distinguishes reconnect from contention, and
applies pending-chunk backpressure. AshReplicant pins those behaviors with
black-box tests rather than checking only for module/function presence.

### Migration path

The two attributes are ordinary `bytea` columns, so generate migrations the
normal way after adding them:

```bash
mix ash_postgres.generate_migrations --name add_snapshot_provenance
```

Both are nullable by design: existing rows carry `NULL` until an attempt first
stamps them, and a `NULL` fingerprint simply means "no provenance recorded
yet". Nothing backfills them. A row carrying a `NULL` marker is treated as
unseen and IS retired by a completed attempt — that is what makes retirement
total within the managed scope.

The generated checkpoint resource also changed: the reserved-but-inert
`snapshot_generation` column is replaced by `snapshot_state`. Nothing ever wrote
it, so `mix ash.codegen` produces a drop of an always-NULL column and an add of
another; migrate normally, no data capture required.

**If you rely on the old first-chunk clear.** Before this release,
`handle_snapshot/2` deleted every row of a resource on `first_for_table?`. It no
longer does — that wipe repeated every committed host business effect on a retry
and could erase a stream-applied row. Nothing is deleted that was not deleted
before, so the change is strictly less destructive, but a resource that relied
on it for redo-safety now keeps rows the source has dropped. Declare
`snapshot_provenance true` with the two attributes and the private mark/retire
actions to get retirement back, on the fenced completion path described above.

## Diagnosing a pipeline without touching it

```bash
mix ash_replicant.preflight --pipeline MyApp.Replicant.Pipeline
mix ash_replicant.doctor --pipeline MyApp.Replicant.Pipeline --format json
```

`preflight` answers *may this start?* and reads no checkpoint, so it is correct
on a fresh install. `doctor` adds the durable-state classes a deployed pipeline
has: checkpoint state, contract drift, and runtime readiness. Both resolve the
generated pipeline's own admitted start options — never restate configuration
the application already carries. In-process, the same diagnosis is
`AshReplicant.preflight/1` and `AshReplicant.doctor/1`. The Mix task checks the
generated-pipeline marker in the BEAM export table before loading the named
module, so an arbitrary module cannot run `@on_load` or `start_options/0`.

**The commands perform no writes.** Every source statement passes a fail-closed
read-only admission, the probe connection is opened
`default_transaction_read_only=on` (so PostgreSQL refuses a write the admission
missed), and the checkpoint is read through its `:read` action with no lock. The
commands never start a repo, a pipeline, or a service.

Rules for reading a report:

- **Every class has its own reason.** Missing privileges
  (`privilege_replication_missing` / `privilege_select_missing` /
  `privilege_probe_missing`), unknown
  checkpoint state (`checkpoint_state_unknown`), replica identity
  (`source_replica_identity`, judged independently of the rest of coverage),
  the retention horizon, contract drift, and version mismatch are never
  collapsed into one bucket.
- **`skipped` is not `pass`.** An unreachable source or an unavailable
  destination skips what it could not judge and says why; reachability itself
  still fails, so the verdict stays closed. A statement fault after a source
  connection succeeds keeps reachability passed and marks the affected checks
  `source_probe_failed` instead of calling a responding server unreachable.
- **Act on `retention_at_risk` before `retention_lost`.** The first warns while
  the WAL is still there; the second means recovery is already impossible. A
  durable watermark whose slot has disappeared is `retention_lost`.
- **Exit codes:** `0` clean, `1` a failed check, `2` warnings only, `3` the
  invocation could not be diagnosed at all. Branch monitoring on `3` separately
  — it means the command was invoked wrong, not that the deployment is sick.
- **Runtime readiness is node-local.** `:persistent_term` is per-node, so the
  Mix command — its own OS process — always reports `generation_absent`. Call
  `AshReplicant.doctor/1` from inside the running application for the real
  answer.
- Output carries no connection option, publication name, source identity, slot
  name, watermark, or row value, in either format.

## Source-bound checkpoints, binding, and operator recovery

The durable checkpoint row is keyed by the ACTUAL replication session's
identity — `(source_system_id, source_database, slot_name)` — with the session
timeline recorded beside it and the canonical contract manifest (what the
adapter maps) plus its fingerprint stored on the row
([ADR-0007](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0007-source-bound-checkpoint-effect-once.md)).

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

AshReplicant 0.4.0 keyed checkpoints only by `slot_name`. Those rows contain no
machine-derivable source identity, so the 1.0.0 upgrader never infers ownership
or provenance. The supported transition is exactly `0.4.0 -> 1.0.0`; use the
package task, not a hand-written capture/delete/adopt sequence.

Before changing anything, back up the destination database and stop the
AshReplicant pipeline on **every node**. The database lock makes the schema
transition atomic, but it cannot prove an idle old node has been stopped.
Update the dependency to 1.0.0 and add Igniter as a development dependency if
the host does not already have it. Current code accepts 0.4.0's `apply_ledger`
option only as a compile-time upgrade marker and refuses to activate a sink
that still carries it.

Run a redacted dry-run first. Repeat `--binding` once for every configured sink;
each JSON object names the sink, the generated pipeline module, and the source
identity the operator has independently verified:

```bash
mix ash_replicant.upgrade 0.4.0 1.0.0 \
  --repo MyApp.Repo \
  --destination-database destination_db \
  --binding '{"sink":"MyApp.ReplicantSink","pipeline":"MyApp.Replicant.Pipeline","source_system_id":"...","source_database":"..."}' \
  --dry-run
```

The task reads the selected destination, verifies the exact legacy/current
table shape, ties every populated row to exactly one binding, permits dormant
configured sinks with no row, and reports only structural state and counts. It
halts without source changes for missing, shared, ambiguous, foreign, or
partially upgraded checkpoints; unreadable or dynamic legacy supervision; a
non-default effective dynamic Repo; an unsupported version range; or a missing
or foreign resource snapshot. Slot names, identities, watermarks, connection
options, and source diffs are never printed.

Apply the same plan, inspect and commit the generated host migration, current
resource snapshot, pipeline module, supervision change, runtime configuration,
and removed `apply_ledger` marker, then run the migration while the all-node stop
assertion remains true:

```bash
mix ash_replicant.upgrade 0.4.0 1.0.0 \
  --repo MyApp.Repo \
  --destination-database destination_db \
  --binding '{"sink":"MyApp.ReplicantSink","pipeline":"MyApp.Replicant.Pipeline","source_system_id":"...","source_database":"..."}' \
  --yes

ASH_REPLICANT_PIPELINES_STOPPED=1 mix ecto.migrate
```

The required migration invocation is
`ASH_REPLICANT_PIPELINES_STOPPED=1 mix ecto.migrate`; the generated migration
refuses without that explicit assertion.

The migration takes a destination-scoped advisory transaction lock and an
`ACCESS EXCLUSIVE` checkpoint-table lock, records a checksummed private rollback
ledger, binds each legacy row to its declared identity, and converts the schema
in one transaction. An exact already-current database and matching generated
source are idempotent no-ops. After migration, deploy/start the 1.0.0 host and
verify the pipeline binds the expected source before accepting it as healthy.

### Rollback boundary

Stop every pipeline node again and roll the generated database migration back
**before** restoring the 0.4.0 host artifact or dependency:

```bash
ASH_REPLICANT_PIPELINES_STOPPED=1 mix ecto.rollback --step 1
```

Rollback succeeds only when the checkpoint rows still match the migration's
checksummed ledger and no 1.0-only timeline, contract, snapshot, origin, new-row,
removed-row, or advanced-watermark state exists. Timestamp-only migration
metadata does not block it. A missing, malformed, or tampered ledger also
refuses. If 1.0 has written durable state, restore from backup or remain on 1.0;
discarding that state to force a downgrade is unsupported. After a successful
database rollback, restore the exact pre-upgrade host source/artifact and only
then restart the old pipeline.

## Source coverage, ignores, and replica identity

Every publication table must be mapped, explicitly ignored, or the pipeline
refuses to start; every delivered column must be mapped or skipped, or the
pipeline halts before writing ([ADR-0008](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0008-strict-source-coverage.md)).
The preflight runs at activation on a short-lived identity-verified source
connection and re-runs the table-membership check at every reconnect.

- **Partial publications** (tables you do not mirror) must declare them:
      use AshReplicant.Sink,
        ignored_sources: ["public.audit_events"]
  Strictly qualified `schema.table` strings; bare names and duplicates are
  compile errors; an ignore colliding with a mapped resource fails
  activation. Column-level ignoring is the resource-level `skip` list.
  Ignores are standing intent — their hygiene is yours. `mix
  ash_replicant.doctor` reports a never-matching entry as a warning
  (`ignore_never_matches`) so an ignore that protects nothing does not stay
  silent.
- **Source columns** must all be mapped or skipped. A source `ADD COLUMN`
  halts the first changed row (`:source_column_unmapped`) until you map or
  skip it. A declared column that vanishes, or a `skip` naming a column that
  does not exist, halts at activation.
- **Column types** are checked against the target attribute at activation
  (`:source_type_invalid`); custom target types are not judged statically —
  the runtime cast stays per-row fail-closed.
- **REPLICA IDENTITY FULL** is enforced at activation on every append-log
  source, every tenant-scoped mapped table, and every SCD2 table whose business
  key is not the source primary key (`:source_replica_identity`); a mid-stream identity
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
  dedups. Whole-table snapshot RETRY is effect-once by a separate mechanism —
  the checkpoint-owned attempt and the row fingerprint (see "Snapshot provenance
  and retirement"), which is what an LSN watermark cannot give a COPY-based
  snapshot. Incremental chunks use the same row fingerprint plus atomic durable
  progress and stream membership stamping.

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
