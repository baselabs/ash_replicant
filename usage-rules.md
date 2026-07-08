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
  the mirror action.
- **`tenant_mfa`** — alternative: `{Module, :function, [extra_args]}` applied as
  `apply(Module, :function, [record | extra_args])` yielding the tenant.
- **`sensitive`** — source columns classified as sensitive. Each must map to an
  AshCloak-encrypted attribute, a binary-storage attribute, or be listed in `skip`.
  Never list the `tenant_attribute`.
- **`skip`** — source columns excluded from the mirror write.
- **`on_truncate`** — `:halt` (fail-closed, default) or `:mirror` (bulk-destroy in
  transaction).
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

## Non-negotiable rules

- **Route writes through Ash actions.** The mirror writes through the host resource's
  OWN primary `:create` action (as an upsert) and its `:destroy` action — the extension
  generates neither, you define them. The sink calls them with `authorize?: false`, so
  AshCloak encryption and multitenancy scoping still fire (policies are not re-gated).
  Direct Ecto bypasses AshCloak and tenancy — never do it.

- **Fail-closed multitenancy.** A nil/blank tenant on a multitenant resource is an
  error. No silent base-tenant fallback. The mirror action's `tenant:` option
  triggers Ash's multitenancy DSL; if tenant validation fails, the write fails and
  the transaction rolls back.

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
