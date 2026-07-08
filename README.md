# AshReplicant

An [Ash Framework](https://ash-hq.org) adapter for [replicant](../replicant) — the
framework-agnostic Postgres CDC consumer. Mirrors a source Postgres database's
committed changes into AshPostgres resources with **effect-once semantics** (dup = 0,
loss = 0), resolving resource, tenant, and classification in the Ash layer while
keeping `replicant` tenant-blind.

AshReplicant is the "`ash_postgres` of `replicant`": define Ash resources backed by
a Postgres source's CDC stream, with multitenancy, sensitive-data encryption
verification, and policies **enforced Ash-natively**. It executes through the
[`replicant`](https://github.com/baselabs/replicant) client (the transport — the
"`postgrex` of CDC").

> **Status: v0.1.0.** Full working library with effect-once guarantees, fail-closed
> multitenancy, and AshCloak integration. Working rules are in [`AGENTS.md`](AGENTS.md) —
> read it first. A fuller project charter (architecture, scope, and the resolved
> effect-once model) is **tracked** at [`docs/CHARTER.md`](docs/CHARTER.md). Only the
> `/docs/superpowers/` lifecycle artifacts (specs, plans, handoffs) are local-only.

## Layering

```
Ash core        multitenancy DSL, policies, the tenant concept
   │
AshReplicant ← HERE   Ash resource extension: tenant routing, sensitive verification,
   │                   resource mapping, mirror actions
   │
replicant       Postgres logical replication (pgoutput), exactly-once watermark
   │
Postgres        logical decoding output (pgoutput protocol)
```

Multitenancy lives **here**, not in `replicant` — exactly as `ash_postgres` (not
`postgrex`) owns schema-based tenancy. This split is verified by the separate
`Replicant.Sink` behaviour and the dual library structure.

## Installation

Not yet published. During co-development it path-depends on `replicant`:

```elixir
# mix.exs
{:ash_replicant, path: "../ash_replicant"},
{:replicant, path: "../replicant"}
```

## Quick Start

### 1. Define the checkpoint resource

```elixir
defmodule MyApp.ReplicantCheckpoint do
  use AshReplicant.Checkpoint,
    repo: MyApp.Repo,
    domain: MyApp.Domain
end
```

This generates an AshPostgres resource backed by the `ash_replicant_checkpoints`
table (one row per replication slot, tracking the durable commit LSN watermark).

### 2. Define the sink

```elixir
defmodule MyApp.ReplicantSink do
  use AshReplicant.Sink,
    repo: MyApp.Repo,
    domains: [MyApp.Shop, MyApp.Billing],
    checkpoint_resource: MyApp.ReplicantCheckpoint,
    slot_name: "shop_orders"
end
```

**Key:** `slot_name` is **baked into the sink** — it is the single source of truth
for the replication slot name and is used to key the resolved index. It is **NOT** a
`start_link` option.

### 3. Mark source resources with the extension

```elixir
defmodule MyApp.Shop.Order do
  use Ash.Resource,
    domain: MyApp.Shop,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]  # ← HERE

  postgres do
    table "orders"
    repo MyApp.Repo
  end

  replicant do
    source_table "orders"
    source_schema "public"
    tenant_attribute :org_id
    sensitive [:pan, :cvv]
    skip [:internal_field]
    on_truncate :mirror
    on_schema_change :halt_destructive
    upsert_identity :unique_pk
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, public?: true
    attribute :org_id, :uuid, public?: true  # Tenant column; resolved per row and passed as tenant:
    attribute :amount, :decimal, public?: true
    attribute :pan, :binary, public?: true    # Sensitive: binary storage; stored as-is (host-managed encryption unless this resource also uses AshCloak)
    attribute :cvv, :binary, public?: true    # Sensitive: binary storage; stored as-is (host-managed)
    attribute :internal_field, :string, public?: true  # Skipped; not mirrored from source
  end

  actions do
    # The extension generates NO action. The mirror writes through THIS resource's
    # own primary `:create` action (as an upsert) and its `:destroy` action, so you
    # must define them. `create: :*` gives a primary create accepting all public
    # attributes — the upsert target; `:destroy` handles mirrored deletes/truncate.
    defaults [:read, :destroy, create: :*, update: :*]
  end

  identities do
    identity :unique_pk, [:id]
  end
end
```

**About the DSL:**

- **`source_table` / `source_schema`** — defaults to the resource's own AshPostgres
  table/schema via reflection. Optionally override to map a different source.
- **`tenant_attribute`** — source column carrying the tenant. Resolved per row and
  passed as `tenant:` to the mirror action. Fail-closed if nil/blank. The source
  table must be `REPLICA IDENTITY FULL` so a delete's / PK-changing update's
  `old_record` carries the tenant column (key-only under the default identity).
- **`sensitive`** — source columns classified as sensitive. Must map to an AshCloak-encrypted
  attribute, a binary-storage attribute, or be listed in `skip`. Never list the
  `tenant_attribute`.
- **`skip`** — source columns excluded from the mirror write.
- **`on_truncate`** — `:halt` (fail-closed) or `:mirror` (bulk-destroy in-transaction).
  Default `:halt`.
- **`on_schema_change`** — `:halt_destructive` (halt on destructive DDL) or `:ignore`.
  Default `:halt_destructive`.
- **`upsert_identity`** — identity name used for the upsert mirror write. Defaults to
  primary-key upsert when omitted; set an identity name to upsert by that identity instead.

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

**Key points:**

- The `slot_name` comes from the sink (not a `start_link` option).
- The resolver index is built and cached in `:persistent_term` keyed by `slot_name`.
- Rows arrive from the source's CDC stream and are upserted into the mirrors.

## Effect-Once Semantics

Each transaction is applied in **one** `Repo.transaction`:

1. Skip any change whose `commit_lsn <= checkpoint` (watermark dedup).
2. Apply each row change (upsert-by-PK, destroy, truncate per policy).
3. Upsert the checkpoint (`commit_lsn`) **in the same transaction**.

On failure (schema change, multitenancy error, write fault), the entire transaction
rolls back. The un-acked WAL re-streams on resume and dedups against the checkpoint.

**Result:** dup = 0, loss = 0 across restarts and crashes (proven by crash-injection
tests against real PG16).

## Multitenancy & Classification

- **Fail-closed:** nil/blank tenant → error, never a base-tenant fallback.
- **Per-row:** each source row's tenant is resolved via `tenant_attribute` or `tenant_mfa`,
  then passed as `tenant:` to the mirror action. Ash's multitenancy DSL validates it.
- **One layer up:** multitenancy logic stays here; `replicant` is tenant-blind.

## Sensitive Data

Sensitive source columns must map to one of:

1. **AshCloak-encrypted** — the `before_action` hook fires on upsert.
2. **Binary storage** — user-managed encryption (store and load encrypted values).
3. **Skipped** — excluded from the mirror (listed in `skip`).

The verifier runs at compile time and rejects a resource if a `sensitive` column
violates one of these rules.

## Development

```bash
mix deps.get
mix test
mix quality   # format --check-formatted + credo --strict + dialyzer
```

All gates pass before commit. Update `CHANGELOG.md` under `[Unreleased]`.

## License

MIT — see [LICENSE](LICENSE).
