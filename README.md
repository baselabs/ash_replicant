# AshReplicant

An [Ash Framework](https://ash-hq.org) adapter for [replicant](https://github.com/baselabs/replicant) — the
framework-agnostic Postgres CDC consumer. Mirrors a source Postgres database's
committed streaming transactions into AshPostgres resources with durable
**effect-once semantics**, resolving resource, tenant, and classification in the Ash
layer while keeping `replicant` tenant-blind.

AshReplicant is the "`ash_postgres` of `replicant`": define Ash resources backed by
a Postgres source's CDC stream, with multitenancy and sensitive-data encryption
verification enforced through host Ash actions. Validations, changes, AshCloak
hooks, and multitenancy run; the sink uses `authorize?: false`, so host policies are
not re-gated. It executes through the
[`replicant`](https://github.com/baselabs/replicant) client (the transport — the
"`postgrex` of CDC").

> **Status: v0.4.0; 1.0.0 hardening in progress.** Full working library with effect-once guarantees, fail-closed
> multitenancy (compile-time verified), SCD2 history mirroring, and AshCloak integration.
> Working rules are in
> [`AGENTS.md`](https://github.com/baselabs/ash_replicant/blob/main/AGENTS.md) — read it
> first. A fuller project charter (architecture, scope, and the resolved effect-once
> model) is **tracked** at
> [`docs/CHARTER.md`](https://github.com/baselabs/ash_replicant/blob/main/docs/CHARTER.md).
> Only the `/docs/superpowers/` lifecycle artifacts (specs, plans, handoffs) are local-only.

## Layering

```
Ash core        multitenancy DSL, policies, the tenant concept
   │
AshReplicant ← HERE   Ash resource extension: tenant routing, sensitive verification,
   │                   resource mapping, mirror actions
   │
replicant       Postgres logical replication (pgoutput), WAL ordering and delivery
   │
Postgres        logical decoding output (pgoutput protocol)
```

Multitenancy lives **here**, not in `replicant` — exactly as `ash_postgres` (not
`postgrex`) owns schema-based tenancy. This split is verified by the separate
`Replicant.Sink` behaviour and the dual library structure.

## Installation

Add `ash_replicant` to your dependencies in `mix.exs`:

```elixir
# mix.exs
{:ash_replicant, "~> 0.4.0"}
```

It pulls in [`replicant`](https://github.com/baselabs/replicant) (the CDC transport)
as a transitive dependency.

### Supported foundation

The current 1.0.0 hardening baseline is built and tested with:

- Elixir 1.20.3 on Erlang/OTP 29;
- Ash `>= 3.31.3 and < 4.0.0-0` and AshPostgres 2.11.x;
- Replicant `>= 1.0.0 and < 2.0.0-0` (current release-candidate lock 1.1.0) and
  AshOnetime 0.6.x;
- PostgreSQL with `wal_level=logical` for the live integration gate: CI pins
  PostgreSQL 16, the local gate runs whatever instance `ASH_REPLICANT_TEST_URL`
  points at (derive the live version with `SELECT version();` — never assume it
  from this doc), and the support matrix is PG15–18.

The Ash lower bound excludes known-vulnerable patches, and the upper bound
excludes Ash 4 prereleases. AshOnetime protects admitted local auxiliary actions
that need a WAL replay guard and is also the governed mechanism for the
logical-message idempotency contract tracked for 1.0.0; no message action is
shipped yet. It does not replace the durable commit-LSN checkpoint used for
transaction replay and resume.

See [ADR-0002](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0002-supported-runtime-and-dependencies.md)
for the dependency decision and
[ADR-0003](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0003-verification-and-release-evidence.md)
for the release-evidence contract. [ADR-0005](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0005-replicant-coordination.md)
records the Replicant 1.x compatibility and release-order contract.

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
table: one row per replication SOURCE and slot, keyed by
`(source_system_id, source_database, slot_name)` from the actual replication
session's identity, carrying the durable commit LSN watermark, the recorded
session timeline, and the canonical contract manifest with its fingerprint
([ADR-0007](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0007-source-bound-checkpoint-effect-once.md)). The sink
binds the row on every connect before any checkpoint read, admits under a
`FOR UPDATE` row lock, and advances the watermark monotonically.

The checkpoint is an internal watermark — nothing outside the sink should read or write
it. The generated resource is **default-deny**: it carries `Ash.Policy.Authorizer` with
an empty policy set, which forbids every external actor on every action — even on a
wire surface (JSON:API, MCP) you add later. To grant specific access, declare your own
policies:

```elixir
defmodule MyApp.ReplicantCheckpoint do
  use AshReplicant.Checkpoint,
    repo: MyApp.Repo,
    domain: MyApp.Domain

  policies do
    default_access_type :strict

    policy always() do
      authorize_if MyApp.Checks.SystemActor
    end
  end
end
```

The sink reads and upserts the checkpoint with `authorize?: false`, so it bypasses
policy — effect-once is unaffected whatever you declare, including nothing (the
default). Hosts that already front the resource with their own authorization can
reproduce the earlier unguarded shape with `authorizers: []`
([ADR-0014](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0014-internal-trust-and-lifecycle-ownership.md)).

**Upgrading from the slot-only shape:** the generated resource changed (see the
[upgrade runbook](usage-rules.md#upgrading-from-the-slot-only-checkpoint)). With
existing slot-only rows, run `AshReplicant.Checkpoint.Identity.refuse_ambiguous_legacy_rows!/1`
before migrating — the migration itself refuses surviving rows — then capture,
delete, migrate, and `AshReplicant.adopt_checkpoint/3` per slot.

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
  passed as `tenant:` to the mirror action. Fail-closed if nil/`false`/blank (Ash treats
  a falsy tenant as unscoped). The source table must be `REPLICA IDENTITY FULL` so
  `old_record` carries the tenant for deletes, PK changes, and same-PK tenant
  reassignment (it is key-only under the default identity).
- **`tenant_mfa`** — alternative tenant source: `{Module, :function, [extra_args]}`
  applied as `apply(Module, :function, [record | extra_args])` yielding the tenant.
  It must resolve deterministically from both new and old record shapes. An absent,
  blank, or `false` old-side resolution halts `:tenant_required` (`side=old`) and a
  raising resolver halts `:tenant_resolution_failed` — both fail-closed before any
  write (ADR-0001's B4 amendment).
- **Compile-time tenancy checks** (fail-closed at build, `ValidateMultitenancy` /
  `ValidateActionMultitenancy` — see
  [ADR-0001](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0001-fail-closed-multitenancy.md)):
  declaring either tenant source **requires an Ash `multitenancy` block** (any strategy —
  `:attribute`/`:context`, incl. `global?`), or Ash silently ignores `tenant:` and every
  tenant mirrors unscoped; under `strategy :attribute` the block's own `attribute` must be
  a plaintext, non-sensitive, non-binary column; and no sink-selected action (primary
  read/create/destroy or the SCD2 close) may declare `multitenancy :bypass`/`:bypass_all`.
- **`sensitive`** — source columns classified as sensitive. Must map to an AshCloak-encrypted
  attribute, a binary-storage attribute, or be listed in `skip`. Never list the
  `tenant_attribute`.
- **`skip`** — source columns excluded from the mirror write.
- **`on_truncate`** — `:halt` (fail-closed) or `:mirror` (direct in-transaction DELETE
  of the mirror table). Default `:halt`.
- **`on_schema_change`** — `:halt_destructive` (halt on destructive DDL) or `:ignore`.
  Default `:halt_destructive`.
- **`upsert_identity`** — identity name used for the upsert mirror write. Defaults to
  primary-key upsert when omitted; set an identity name to upsert by that identity instead.

**History (SCD2).** By default a resource mirrors **current state** (`history_strategy
:scd1` — upsert / destroy). Opt a resource into **validity-windowed SCD2 history**
(close-current + insert-version into a host-defined version table, instead of
overwriting) with `history_strategy :scd2`:

```elixir
replicant do
  source_table "orders"
  history_strategy :scd2
  history_business_key [:order_id]   # source natural key (composite supported)
  upsert_identity :version_key       # identity keys: [:order_id, :valid_from_lsn]
end
```

See [`usage-rules.md`](usage-rules.md) (“SCD2 history mode”) for the full version-table
contract: the surrogate PK, the `valid_from_lsn` / `valid_to_lsn` window columns, the
`:close_version` action, the partial-unique-open index, `on_truncate :close`, and the
`REPLICA IDENTITY FULL` precondition for a non-PK business key.

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

**Key points:**

- The `slot_name` comes from the sink (not a `start_link` option).
- `source_identity` is required. It pins the PostgreSQL system identifier and
  database that the actual replication session must report before checkpoint lookup.
- Resolver activation is serialized per slot and cached as one generation owned by
  an `AshReplicant.PipelineOwner` that monitors the pipeline: a rejected or
  duplicate start cannot replace or erase the active generation, and when the
  pipeline exits (halt, crash, stop) the owner erases it — the slot is
  immediately re-activatable ([ADR-0014](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0014-internal-trust-and-lifecycle-ownership.md)).
  Under your own supervision tree, start it as a `:temporary` child:

  ```elixir
  children = [
    {AshReplicant.PipelineOwner,
     sink: MyApp.ReplicantSink,
     connection: [hostname: "standby.example.com", database: "source_db"],
     publication: "shop_orders_pub",
     source_identity: [system_identifier: "7378697629483820647", database: "source_db"],
     go_forward_only: true}
  ]
  ```
- Rows arrive from the source's CDC stream and are upserted into the mirrors.
- `streaming`, `max_inflight_lag`, `max_command_retries`, and `failover` are passed
  through to Replicant 1.x.
- `snapshot: false` and Replicant's v1 snapshot (`snapshot: true`) are supported.
  Incremental snapshot configuration is rejected until roadmap C3 adds durable
  progress and target provenance.

## Strict source coverage

Every publication table is mapped, explicitly ignored
(`ignored_sources: ["public.audit_events"]`), or the pipeline refuses to
start; every delivered column is mapped or skipped, or delivery halts before
writing. Column types are checked against the target at activation, and
`REPLICA IDENTITY FULL` is enforced on tenant-scoped and non-PK-business-key
SCD2 source tables. The preflight runs at activation (identity-verified,
short-lived source connection) and the table-membership check re-runs at
every reconnect — see
[ADR-0008](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0008-strict-source-coverage.md) and
[usage-rules](usage-rules.md) for the operator rules.

## Effect-Once Semantics

Each transaction is applied in **one** `Repo.transaction`:

1. Skip any change whose `commit_lsn <= checkpoint` (watermark dedup).
2. Apply each row change (upsert-by-PK, destroy, truncate per policy).
3. Upsert the checkpoint (`commit_lsn`) **in the same transaction**.

On failure (schema change, multitenancy error, write fault), the entire transaction
rolls back. The un-acked WAL re-streams on resume and dedups against the checkpoint.

**Result for committed streaming transactions:** zero physical duplicate effects
and zero loss across replay, restart, and injected rollback faults. Replicant v1
snapshot batches are individually atomic, but an incomplete multi-batch snapshot
restart clears and rebuilds the target and can physically repeat already committed
batch effects. Roadmap C3 must eliminate those repeats before the stable release
extends the physical effect-once claim to snapshot restart.

## Destination transaction boundary

Every admitted destination resource uses the sink's literal AshPostgres Repo and
the same effective dynamic Repo. The activation manifest starts from the checkpoint
and mapped read/create/destroy/SCD2-close actions, recursively follows framework
relationships and declared custom actions, and rejects a missing action, foreign or
dynamic Repo, non-Postgres data layer, recursive cycle, or `touches_resources`
mismatch before delivery.

Generated sink callbacks are final and invoke the admitted implementation
directly; hosts cannot override an effect hook to bypass apply/checkpoint. A
`SetContext` change or preparation that replaces `:data_layer` is rejected (a
dynamic/MFA context is admissible only when its module declares
`DestinationParticipant`), as is any AshOnetime cache other than the effect-free
`AshOnetime.Cache.None`.

Arbitrary changes, validations, preparations, manual actions, callbacks, custom
types, and tenant resolvers must implement `AshReplicant.DestinationParticipant`.
Return `:no_database` or literal Ash resource/action references. Declarations are
trusted metadata; they do not prove an arbitrary Elixir body. A declaration cannot
make raw SQL, another Repo, asynchronous work, or an external effect part of the
atomic guarantee.

<!-- ash-replicant-destination-participant-example:start -->
```elixir
defmodule MyApp.ReplicantReceiptParticipant do
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

The containing Ash action's `touches_resources` must exactly match the resources
discovered from its providers. When the declared auxiliary action needs a replay
guard, it may use only local AshOnetime idempotency committed with the action in
the admitted Repo. It must take the private, non-null `operation_key` produced by
`AshReplicant.DestinationParticipant.operation_key/2` and use the exact versioned
participant scope and replay identity shown above. AshOnetime one-time nonces are
rejected for WAL replay. Independent commits and external effects are rejected too.

A Replicant v1 snapshot batch is atomic, but an incomplete multi-batch restart can
physically repeat already committed batch effects. Message, sink-owned batch,
incremental snapshot-progress, and append-log callbacks are not exported yet; their
roadmap rows must compose with this same boundary. See
[ADR-0006](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0006-destination-transaction-boundary.md).

## Multitenancy & Classification

- **Fail-closed:** nil/`false`/blank tenant → error, never a base-tenant fallback.
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
asdf install
scripts/with-release-runtime.sh scripts/assert-runtime-version.sh
scripts/with-release-runtime.sh mix deps.get
env -u ASH_REPLICANT_TEST_URL \
  scripts/with-release-runtime.sh scripts/run-structural-tests.sh \
    --allow-excluded --exclude integration

export ASH_REPLICANT_TEST_URL="postgres://postgres@localhost:5599/postgres" # example — point at YOUR logical-replication Postgres (host/port are machine-local; the database name is forced anyway)
MIX_ENV=test scripts/with-release-runtime.sh mix ecto.create
MIX_ENV=test scripts/with-release-runtime.sh mix ecto.migrate
scripts/with-release-runtime.sh scripts/run-structural-tests.sh --include integration
scripts/with-release-runtime.sh scripts/run-structural-tests.sh \
  test/integration --include integration

scripts/with-release-runtime.sh scripts/test-migration-drift-gate.sh
scripts/with-release-runtime.sh scripts/test-release-checkers.sh
scripts/with-release-runtime.sh scripts/test-release-contract.sh

scripts/with-release-runtime.sh mix format --check-formatted
scripts/with-release-runtime.sh mix compile --warnings-as-errors
scripts/with-release-runtime.sh mix credo --strict
scripts/with-release-runtime.sh mix deps.audit
scripts/with-release-runtime.sh mix dialyzer
scripts/with-release-runtime.sh mix docs --warnings-as-errors
scripts/with-release-runtime.sh mix hex.build
```

All gates pass before commit. Update `CHANGELOG.md` under `[Unreleased]`.

## License

MIT — see [LICENSE](LICENSE).
