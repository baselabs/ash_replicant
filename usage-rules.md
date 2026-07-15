# ash_replicant usage rules

_An Ash adapter for the `replicant` CDC framework — the "`ash_postgres` of
`replicant`."_

## What ash_replicant is (and is not)

- **Is:** an Ash-native CDC mirror / incremental-sync adapter. Resolves resources,
  enforces multitenancy per row, verifies sensitive-column encryption, and applies
  changes to Ash resources with effect-once semantics (dup = 0, loss = 0).
- **Is not:** the CDC transport itself. That is `replicant`'s job. AshReplicant
  consumes a `Replicant.Sink` interface and owns the Ash-layer semantics
  (multitenancy, policies, encryption) above it.
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
  `:delete` / PK-changing `:update` resolves the tenant from `old_record`, which is
  key-only under the default replica identity (the tenant column would be absent →
  fail-closed `:tenant_required`).
- **`tenant_mfa`** — alternative: `{Module, :function, [extra_args]}` applied as
  `apply(Module, :function, [record | extra_args])` yielding the tenant.
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
  go_forward_only: true,
  snapshot: false
)
```

**Options:**

- `:sink` — the sink module (required).
- `:connection` — Postgrex connection options (required). Point at a standby or
  replica to avoid load on the primary.
- `:publication` — Postgres publication name (required).
- `:go_forward_only`, `:snapshot` — passed to `Replicant.start_link/1`. See
  `replicant`'s usage docs for details.

**Key:** the `slot_name` comes from the sink, not `start_link` options. It keys the
resolver index and the replication slot name.

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

**A mutable tenant must be part of the business key.** The per-change close is scoped to
the change record's resolved tenant. Tenant (`tenant_attribute`) is normally an immutable
owner scope; but if a source row can change tenant while keeping the same business key,
include the tenant column in `history_business_key` so the move is treated as a business-key
change (the old-tenant version is then closed). Otherwise keep the partial-unique-open index
**global** on the business key (its shape above): a same-key tenant move then fails closed on
a unique violation rather than silently leaving the old tenant's version open.

**History is retained on delete (soft-close).** A source delete **closes** the current
version (stamps `valid_to_lsn`); it never erases prior versions. SCD2 therefore does
**not** serve a point-erasure / right-to-be-forgotten need — for that, use an SCD1
mirror (which overwrites / destroys) or AshPaperTrail with a pruning policy.

**`on_truncate :close` (SCD2 only).** In place of `:halt` / `:mirror`, an SCD2 resource
may set `on_truncate :close`: an upstream TRUNCATE **closes every open version
tenant-blind** (stamps `valid_to_lsn` on all rows where it is NULL), retiring the whole
window without deleting history. `on_truncate :close` on a non-SCD2 resource is rejected
at compile time.

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

- **Effect-once is one transaction + watermark dedup.** Every transaction applies in
  a single `Repo.transaction`: skip any change whose `commit_lsn <= checkpoint`,
  apply rows, upsert checkpoint atomically. On failure, the txn rolls back; on
  resume, un-acked WAL re-streams and dedups.

## Relationship to `replicant`

`replicant` is the CDC transport layer — tenant-blind, Ash-agnostic. It owns the
Postgres logical replication slot, the `pgoutput` protocol, transaction assembly,
and exactly-once watermark (`commit_lsn` at transaction granularity).

AshReplicant consumes a `Replicant.Sink` interface and layers Ash semantics on top:
resource resolution, tenant routing, sensitive verification, and policies.

Never add multitenancy or classification logic to `replicant`. The split is the
reason they are separate libraries.

## See also

- **`AGENTS.md`** — the working guide with critical rules (binding).
- **`replicant` usage-rules** (`../replicant/usage-rules.md`) — CDC framework contract.
- **`CHANGELOG.md`** — version history.
