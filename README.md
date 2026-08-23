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
- Replicant `>= 1.2.3 and < 2.0.0-0` (current release-candidate lock 1.2.3) and
  AshOnetime 0.6.x;
- PostgreSQL with `wal_level=logical` for the live integration gate: CI pins
  PostgreSQL 16, the local gate runs whatever instance `ASH_REPLICANT_TEST_URL`
  points at (derive the live version with `SELECT version();` — never assume it
  from this doc), and the support matrix is PG15–18.

The Ash lower bound excludes known-vulnerable patches, and the upper bound
excludes Ash 4 prereleases. AshOnetime protects admitted local auxiliary actions
that need a WAL replay guard and is also the dedup mechanism for logical
messages (C1 / [ADR-0015](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0015-logical-message-effects.md)):
a standalone `pg_logical_emit_message` routes by prefix to a protected create
action whose claim is keyed on source+slot+LSN with a versioned host-keyed
content digest as the fingerprint. It does not replace the durable commit-LSN
checkpoint used for transaction replay and resume.

See [ADR-0002](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0002-supported-runtime-and-dependencies.md)
for the dependency decision and
[ADR-0003](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0003-verification-and-release-evidence.md)
for the release-evidence contract. [ADR-0005](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0005-replicant-coordination.md)
records the Replicant 1.x compatibility and release-order contract.

### Install with Igniter

```bash
mix igniter.install ash_replicant
```

That adds the dependency and runs `mix ash_replicant.install`, which generates the
domain, checkpoint, sink, and pipeline supervisor; registers the domain; supervises
the pipeline; imports AshReplicant's formatter metadata; and queues
`mix ash.codegen install_ash_replicant` for the checkpoint migration. In an app
that already has `ash_replicant` as a dependency, run the installer directly:

```bash
mix ash_replicant.install --repo MyApp.Repo --slot shop_orders
```

`--repo` selects among several discovered AshPostgres repos; when none exists,
generate one with `mix ash_postgres.install` first. `--slot` defaults to
`<otp_app>_replicant`. `--domain`, `--checkpoint`, `--sink`, and `--pipeline`
rename individual artifacts.

**It writes no connection, publication, source identity, or key material.** Those
are operator facts, and a plausible-looking placeholder is worse than an absent
one — so the generated pipeline supervises *nothing* until you configure it, and a
fresh install compiles and boots as a no-op. Re-running the installer over an
installed project changes nothing.

**It stops rather than guess.** Malformed module names; an illegal slot name; a
missing, ambiguous, unknown, or non-AshPostgres repo; incomplete project facts; a
module it did not generate at a target name; an unreadable existing binding; or a
checkpoint, sink, or pipeline bound to a different identity each stop the install —
writing nothing — with a structural message naming the resolving flag. Re-keying a
live sink onto a different slot would abandon its durable checkpoint row and
re-deliver from the new slot's position; that is exactly the kind of quiet,
expensive wrongness the installer refuses to perform silently.

Igniter is an **optional** dependency. Without it, `mix ash_replicant.install` prints
the instruction to add it, and the manual path below reaches the identical contract.

### Manual installation

Everything the installer writes, by hand. These four modules are the whole generated
surface — no hidden state, no package-owned code:

<!-- ash-replicant-manual-install-modules:start -->
```elixir
# lib/my_app/replicant.ex
defmodule MyApp.Replicant do
  use Ash.Domain,
    otp_app: :my_app

  resources do
    resource MyApp.Replicant.Checkpoint
  end
end

# lib/my_app/replicant/checkpoint.ex
defmodule MyApp.Replicant.Checkpoint do
  use AshReplicant.Checkpoint,
    repo: MyApp.Repo,
    domain: MyApp.Replicant
end

# lib/my_app/replicant/sink.ex
defmodule MyApp.Replicant.Sink do
  use AshReplicant.Sink,
    repo: MyApp.Repo,
    domains: [],
    checkpoint_resource: MyApp.Replicant.Checkpoint,
    slot_name: "my_app_replicant"
end

# lib/my_app/replicant/pipeline.ex
defmodule MyApp.Replicant.Pipeline do
  use AshReplicant.Pipeline,
    otp_app: :my_app,
    sink: MyApp.Replicant.Sink
end
```
<!-- ash-replicant-manual-install-modules:end -->

Then add `:ash_replicant` to the formatter's existing `import_deps`, preserving
every existing formatter entry; register and supervise the generated modules;
and generate the checkpoint migration:

```elixir
# .formatter.exs — merge into the existing list; keep every other key
[
  import_deps: [:ash, :ash_postgres, :ash_replicant],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

```elixir
# config/config.exs — register the domain
config :my_app, ash_domains: [MyApp.Replicant]
```

```elixir
# lib/my_app/application.ex — supervise the pipeline
children = [
  MyApp.Repo,
  MyApp.Replicant.Pipeline
]
```

```bash
mix ash.codegen install_ash_replicant
mix ecto.migrate
```

The checkpoint migration comes from your own resource snapshots, so it stays in
step with the generated resource instead of drifting from a shipped template.

That is the complete equivalent; a test ties this block to the installer's actual
output, so the two cannot drift.

### After either path

Four steps remain, and each needs a fact only the operator has:

1. **Configure the pipeline.** Until this exists, `MyApp.Replicant.Pipeline`
   supervises nothing (see `AshReplicant.Pipeline`):

   ```elixir
   config :my_app, MyApp.Replicant.Pipeline,
     connection: [hostname: "standby.example.com", database: "source_db"],
     publication: "shop_orders_pub",
     source_identity: [system_identifier: "7378697629483820647", database: "source_db"],
     go_forward_only: true
   ```

   A configuration that is present but missing `:connection`, `:publication`, or
   `:source_identity` **raises** rather than supervising nothing — supervising
   nothing would be a silent outage.
2. **Mark the resources you mirror** with the `AshReplicant.Resource` extension and
   list their domains in the sink's `domains` (see Quick Start step 3). Every
   published table must be mapped or explicitly ignored, or the pipeline refuses to
   start.
3. **Set `ALTER TABLE <table> REPLICA IDENTITY FULL`** on the SOURCE database for
   every tenant-scoped, SCD2-with-non-PK-business-key, or append-log source table.
4. **Add the optional key material** only if you use the features that need it:
   `:message_digest_keys` for logical-message routing (C1) and
   `:snapshot_provenance_keys` for snapshot provenance (S02).

## Quick Start

The concepts behind what the installer generates, plus the parts only you can write.
Steps 1, 2, and 4's supervision are what `mix ash_replicant.install` produces; step 3
is the modelling decision it deliberately leaves to you.

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

**Upgrading 0.4.0's slot-only shape to 1.0.0:** use the guarded package task,
`mix ash_replicant.upgrade 0.4.0 1.0.0`. It requires one explicit source-identity
binding per configured sink, classifies the live destination read-only before it
writes host source, and generates the atomic checkpoint bridge plus its exact
resource snapshot. It never infers ownership from a slot-only row. Follow the
[upgrade and rollback procedure](usage-rules.md#upgrading-from-the-slot-only-checkpoint);
do not use the former capture/delete/adopt sequence.

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

The sink also carries the optional logical-message routing surface (C1 /
[ADR-0015](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0015-logical-message-effects.md)):

```elixir
use AshReplicant.Sink,
  repo: MyApp.Repo,
  domains: [MyApp.Shop, MyApp.Messaging],
  checkpoint_resource: MyApp.ReplicantCheckpoint,
  slot_name: "shop_orders",
  message_routes: [{"mail", MyApp.MailOutbox, :record}],
  ignored_message_prefixes: ["telemetry_noise"]
```

A routed action is a create action protected by the closed AshOnetime message
profile (its claim dedups standalone re-delivery; a transactional message rides
its transaction and interleaves with the row changes by ordinal). The pipeline
starts with `messages: true` automatically; an unknown prefix halts fail-closed.
Set `Application.put_env(:ash_replicant, :message_digest_keys, [{1, "<32-byte secret>"}])`
(host-keyed content digests; retain old versions when rotating).

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
- **`snapshot_provenance`** — opt the resource into the snapshot provenance and
  retirement contract (ADR-0017). Default `false`. See "Snapshot provenance" below.
- **`snapshot_mark_action`** / **`snapshot_retire_action`** — names of the private
  actions that contract requires. Default `:replicant_mark_seen` /
  `:replicant_retire_unseen`.

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

**Snapshot provenance.** A snapshot retry must not repeat a host business effect for
a row that did not change — converging to the same final state is not enough when a
create, destroy, or SCD2 close carries an append-only effect. Opt a resource in with
`snapshot_provenance true` and it stores a keyed fingerprint of the values its host
action was given, plus a marker for the attempt that last saw it:

```elixir
replicant do
  source_table "orders"
  snapshot_provenance true
end

attributes do
  attribute :replica_fingerprint, :binary, public?: false, writable?: false
  attribute :replica_seen_attempt, :binary, public?: false, writable?: false
end

actions do
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

A compile-time verifier rejects any action that accepts either attribute or declares
an argument named for one, and rejects `MarkSeen` globally or on any action other
than the configured private mark action, so provenance cannot be forged;
fingerprint keys come from
`:ash_replicant, :snapshot_provenance_keys` and are preflighted at activation.

On a **whole-table (V1) retry** the adapter binds one random attempt to the pipeline
owner's delivery run. In **incremental mode**, `snapshot_progress/0` arms the durable
attempt before Replicant can start the reader and stream, returning
`:backfill_pending` until the first chunk token commits; every chunk commits its exact
opaque progress, authenticated progress hash, destination effects, membership markers,
and ordinal cursor together. Streaming inserts/updates during the backfill carry the same
marker. Both modes mark unchanged rows instead of re-running the host action and retire
only managed open rows the attempt never saw. Incremental completion stores matching
progress/completion token hashes as a permanent replay fence before returning, so
redelivery after a later stream write or an admitted-contract deployment cannot scan,
retire, or brick streaming.

> **No snapshot callback clears a resource.** The pre-1.0 whole-resource `DELETE` on
> `first_for_table?` is gone: it repeated every committed host business effect on a
> retry. A snapshot-backed resource that does not opt into `snapshot_provenance` now
> keeps rows the source has dropped — opting in is what restores retirement.

Under `strategy :context` multitenancy the resource must also declare
`snapshot_tenant_scope_action`, a private generic action returning the retained tenant
contexts — there is no discriminator column to enumerate, and a partial enumeration
would silently under-retire. See
[`usage-rules.md`](usage-rules.md) (“Snapshot provenance and retirement”) for the
full contract, how a V1 retry behaves, key rotation, and the migration path.

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
- The owner continuously re-runs destination-generation, live contract,
  durable checkpoint, and full source-coverage checks. `census:` accepts the
  closed keys `enabled?`, `interval_ms`, `jitter_ratio`, `timeout_ms`, and
  `max_consecutive_faults`. Drift halts immediately; a checker fault or timeout
  is never a pass and halts after the configured consecutive budget. The next
  jittered run is scheduled only after the current bounded run settles, so one
  owner never overlaps census work (ADR-0019).
- `snapshot: false`, Replicant's v1 snapshot (`snapshot: true`), and sink-owned
  incremental snapshots (`snapshot: [mode: :incremental, chunk_rows: n,
  max_pending_chunks: n]`) are supported. Incremental activation requires every
  mapped resource to declare `snapshot_provenance true`; otherwise start fails
  closed with `:snapshot_unsupported`.

## Operator diagnosis — preflight and doctor

Two commands answer *may this start?* and *what is the state of this deployment?*
without touching anything:

```bash
# Before the first activation — no checkpoint is read, so this is correct on a
# fresh install.
mix ash_replicant.preflight --pipeline MyApp.Replicant.Pipeline

# Once deployed — everything above, plus checkpoint state, contract drift, and
# runtime readiness.
mix ash_replicant.doctor --pipeline MyApp.Replicant.Pipeline

# The same report as JSON, for a monitoring caller.
mix ash_replicant.doctor --pipeline MyApp.Replicant.Pipeline --format json
```

Both resolve the generated pipeline's **own** admitted start options, so you
never restate configuration the application already carries. The same diagnosis
is available in-process as `AshReplicant.preflight/1` and
`AshReplicant.doctor/1`, which take the option list `AshReplicant.start_link/1`
takes and return an `AshReplicant.Doctor.Report`. The Mix tasks verify the
generated-pipeline marker from the BEAM export table before loading the named
module, so an arbitrary `--pipeline` module cannot run `@on_load` or
`start_options/0` through a read-only command.

### It performs no writes

Three independent legs, none of which trusts the other:

1. Every source statement passes a fail-closed read-only admission — leading
   `SELECT` only, no statement separator, no write verb, no row lock, and no
   session-escaping function (`set_config`, `dblink*`).
2. The probe connection is opened with `default_transaction_read_only=on`, so
   PostgreSQL itself refuses a write the admission missed. The live integration
   gate asserts exactly that, with the server's own `read_only_sql_transaction`
   SQLSTATE.
3. The destination checkpoint is read through its `:read` action with
   `authorize?: false` and **no lock** — `lock: :for_update` is write intent and
   is never passed.

The commands never start a repo, a pipeline, or a service.

### What the report distinguishes

Machine and operator output are both total functions of one canonical result, so
they cannot disagree. Every class carries its own reason atom rather than a
single "failed" bucket:

| Class | Reasons |
|---|---|
| Missing privileges | `privilege_replication_missing`, `privilege_select_missing`, `privilege_probe_missing` |
| Unknown checkpoint state | `checkpoint_state_unknown`, `checkpoint_state_key_unknown` |
| Replica identity | `source_replica_identity`, judged independently of the rest of coverage |
| Retention horizon | `retention_extended` → `retention_at_risk` → `retention_lost` |
| Contract drift | `contract_drift` reports the classifier's own reason (`publication`, `relation_removed`, `stored_contract_invalid`, …) |
| Version mismatch | `dependency_version_mismatch`, `dependency_missing`, `source_release_unsupported`, `source_release_untested` |

Reasons come from a closed vocabulary, and no connection option, publication
name, source identity, slot name, watermark, or row value ever appears. A leg
that could not be judged — an unreachable source, a repo that is not running —
is reported `skipped` with the reason it could not be judged, never passed.
If a connected server rejects or faults a catalog statement, reachability stays
passed; the affected checks are `source_probe_failed` rather than falsely
reported as unreachable.

Retention is the alert that must fire **before** recovery becomes impossible:
`retention_at_risk` warns while the WAL is still there, `retention_lost` fails
once it is not. A durable watermark whose slot has disappeared is already lost.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every check passed. |
| `1` | At least one check failed. |
| `2` | Warnings only. |
| `3` | The invocation could not be diagnosed — missing, unknown, or unconfigured `--pipeline`, or an unknown flag. |

`3` is separate from `1` so a monitoring caller can tell "this deployment is
unhealthy" from "you invoked me wrong".

> **Runtime readiness is node-local.** The generation index is
> `:persistent_term`, so `mix ash_replicant.doctor` — its own OS process —
> always reports `generation_absent`. Call `AshReplicant.doctor/1` from inside
> the running application (a remote console or a health endpoint) for the real
> answer.

## Runtime status and lifecycle tombstones

`AshReplicant.status/1` answers one question — what state is this sink's
pipeline in? — with a closed five-value contract:

```elixir
AshReplicant.status(MyApp.Replicant.Sink)
#=> :healthy | :catching_up | {:halted, reason} | {:misconfigured, reason} | :not_started
```

The answer is **derived, never stored**: it asks the live `PipelineOwner` for
its own facts (census health, pipeline liveness), falls back to the
node-local generation entry (a dead owner is the fault
`{:halted, :owner_lost}` — mirroring has stopped, never "not started"), then
to the tombstone legs. `AshReplicant.Status.derive/2` exposes the six-state
generation lifecycle underneath (`:activating`, `:ready`, `:degraded`,
`:halted`, `:stopped`, `:superseded`) with its typed, value-free evidence.

Healthy is a strong claim: it requires a live owner and pipeline, an
**enabled census whose last run passed**, and no in-flight snapshot. Owner
liveness alone is insufficient — a pipeline whose census has not run yet (or
is disabled) conservatively reports `:catching_up`, and so does one whose
census is currently faulting below the halt budget.

### Tombstones

When a generation ends, the party that knows the cause records a **terminal
tombstone** — bounded (latest per slot), value-free (a closed reason atom, a
class, a timestamp; never a row value, message prefix, or progress token).
Every error leaving a sink callback records the scrubbed reason (Replicant
halts the pipeline on any non-ok sink return, so that one boundary covers the
halt funnels and the bind/session-identity/slot-origin error paths alike);
the owner's census halt records the census reason; an operator stop records
`:operator_stopped`. The tombstone has two legs: a node-local one (always
writable) and a durable one on the checkpoint row (`terminal_cause`,
`terminal_class`, `terminal_at` — added by `mix ash.codegen` + migrate),
written only when the row already exists. Every admitted checkpoint write
(bind — including the otherwise verify-only steady-state reconnect — and
advance) clears the durable leg, so a stale cause never outlives the
generation that superseded it.

Two documented edges: a halt while the destination is unreachable persists
only the node-local leg (after a node restart the slot reports
`:not_started`; the halt telemetry plus the `:status, :tombstone_write_failed`
event is the durable record — the destination was down at the only moment
the fact existed), and a host-tree shutdown writes no tombstone at all (no
database writes during app teardown; a `:stopped` tombstone would map to the
same public `:not_started` anyway). The halt window itself is closed: a
status call made after any halt decision answers that halt's cause, never
`:healthy` — activation clears the node-local leg before the generation
entry exists, so a node-local tombstone under a live entry can only be that
generation's own halt or stop decision, and it outranks the owner's facts.
Replicant discards halt reasons at teardown, so a pipeline death nothing
else explained records the generic `{:halted, :pipeline_terminated}` —
over-alerting by design.

## Observability and recovery horizons

Telemetry is **value-free by construction**: every event's metadata passes a
typed allowlist (an off-allowlist key or an off-type value raises at the
enforcement point), and the measurement key set is closed
(`count`, `change_count`, `duration`, `byte_size`). `emitted_event_names/0`
lists the whole inventory; `AshReplicant.Telemetry`'s moduledoc ships two
executable examples — a dependency-free metrics reporter and an OpenTelemetry
bridge whose mapping table is test-pinned complete against that inventory.
The data-boundary mutation matrix carries one mutant per typed key, so a
vacuous telemetry gate cannot ship.

Message-routed sinks additionally declare a **recovery horizon** — the
outage/replay window every route's AshOnetime claim retention must cover:

```elixir
use AshReplicant.Sink,
  ...,
  message_routes: [{"mail", MyApp.MailOutbox, :record}],
  recovery_horizon: {24, :hour}
```

Activation refuses `:retention_below_recovery_horizon` when any routed
create's declared retention is shorter than the horizon: an in-window outage
would expire a standalone message's only dedup while its WAL is still
recoverable. The digest-key rotation window is witnessed durably: the
checkpoint's authenticated `digest_key_state` envelope records the
last-observed key set (under the orthogonal
`:ash_replicant, :horizon_provenance_keys` family), and removing a key
version within the retention horizon of the last observation that contained
it halts `:digest_key_horizon_violated` instead of silently blocking future
replays.

### The alert table (what fires, what to do)

| Signal | Meaning | Operator action |
|---|---|---|
| `[:ash_replicant, :retention, :at_risk]` (`kind: :wal_unreserved` or `:wal_exhausted`) | The slot's WAL retention is being consumed while the pipeline runs — recovery is still possible but the window is shrinking | Find the lag (`mix ash_replicant.doctor`), resume or scale the sink before WAL is dropped |
| `{:halted, :source_wal_lost}` (census drift) | The slot no longer retains the WAL the checkpoint needs — recovery through the slot is impossible | Restore the source from backup or re-snapshot; the slot cannot be resumed |
| activation refusal `:retention_horizon_crossed` | The pipeline was down longer than the shortest claim retention while the slot still had the WAL — re-delivery would re-execute standalone messages | Reconcile the affected message routes (inspect for duplicates), then raise retention or restart with a fresh checkpoint decision |
| `{:halted, :digest_key_horizon_violated}` / `:misconfigured, :digest_key_horizon_violated` | A message-digest key version was removed while claims minted under it could still be re-delivered | Restore the removed key version to config, let the pipeline replay, retire it only past the retention horizon |
| `:misconfigured, :retention_below_recovery_horizon` (activation/doctor) | A route's declared retention is shorter than the declared horizon | Raise the route's `retention({count, unit})` or lower `recovery_horizon` |

The at-risk push fires from the census while the pipeline runs; while
**halted**, nothing in the library watches the clock (the supervision
contract owns no idle watcher) — run `mix ash_replicant.doctor` on the
operator's own scheduler (cron, Kubernetes CronJob, or your alerting loop)
as the periodic pull; its `:slot_retention` and `:retention_horizon` checks
carry the same classes with per-check detail. That doctor cadence is the
runbook: at-risk → resume before WAL drops; lost → restore; crossed →
reconcile; violated → restore the key.

Upgrading to this surface: hosts run `mix ash.codegen` (the checkpoint
gains the nullable `digest_key_state` column) and configure
`:ash_replicant, :horizon_provenance_keys` (a `{version, key}` list, keys
of at least 16 bytes) before starting a message-routed sink.

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

The `PipelineOwner` also runs that full coverage census periodically on a quiet
stream. A table added to a publication, a type/RIF change, destination code or
config drift, or a tampered checkpoint contract is therefore detected without
waiting for reconnect or an affected row.

## Effect-Once Semantics

Each transaction is applied in **one** `Repo.transaction`:

1. Skip any change whose `commit_lsn <= checkpoint` (watermark dedup).
2. Apply each row change (upsert-by-PK, destroy, truncate per policy).
3. Upsert the checkpoint (`commit_lsn`) **in the same transaction**.

On failure (schema change, multitenancy error, write fault), the entire transaction
rolls back. The un-acked WAL re-streams on resume and dedups against the checkpoint.

**Result for committed streaming transactions and provenance-backed V1/incremental
snapshot retry:** zero repeated host business effects and zero loss across replay,
restart, and injected rollback faults. Snapshot chunks, provenance, exact incremental
progress, and completion fences commit under the same source-bound checkpoint lock;
unchanged retry rows perform bookkeeping only.

## Append-log mode

A generated sink is exclusively a **state mirror** (the default: rows converge
to the source's current state) or an **append log** (every change is recorded as
an immutable event and nothing is ever modified or removed). The kind is
declared on the sink, because Replicant exposes `sink_kind/0` per sink rather
than per resource; activation rejects a mixed resource set
([ADR-0018](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0018-append-log-delivery.md)).

```elixir
defmodule MyApp.EventSink do
  use AshReplicant.Sink,
    repo: MyApp.Repo,
    domains: [MyApp.Events],
    checkpoint_resource: MyApp.ReplicantCheckpoint,
    slot_name: "shop_events",
    sink_kind: :append_log,
    # The ONE initial-state intent. `:go_forward` starts the log at the slot's
    # origin; `:snapshot` starts it from a full backfill. It must agree with the
    # `snapshot:` start option.
    initial_state: :go_forward,
    message_routes: [{"events", MyApp.Events.OrderEvent, :append}]
end
```

The append target is **yours** — this package generates no event table, no
migration and no raw write path:

```elixir
defmodule MyApp.Events.OrderEvent do
  use Ash.Resource,
    domain: MyApp.Events,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "order_events"
    repo MyApp.Repo
  end

  replicant do
    source_table "orders"
    append_log true
    # `:halt` (default) or `:append` — record the structural truncate event.
    on_truncate :append
  end

  attributes do
    uuid_primary_key :event_id

    # The five append-identity axes, plus the two structural labels and the
    # backfill attempt. Names are configurable (`append_commit_lsn_attribute`
    # and friends); these are the defaults.
    attribute :source_system_id, :string, allow_nil?: false, public?: true
    attribute :source_database, :string, allow_nil?: false, public?: true
    attribute :slot_name, :string, allow_nil?: false, public?: true
    attribute :commit_lsn, :integer, allow_nil?: false, public?: true
    attribute :ordinal, :integer, allow_nil?: false, public?: true
    attribute :operation, :string, allow_nil?: false, public?: true
    attribute :origin, :string, allow_nil?: false, public?: true
    attribute :snapshot_attempt, :binary, public?: true

    # The mapped payload — ordinary source columns, under the same skip,
    # sensitive and tenant rules a state mirror uses.
    attribute :id, :string, public?: true
    attribute :note, :string, public?: true
    # Destination-only logical-message payload. Content is binary-storage.
    attribute :message_prefix, :string, public?: true
    attribute :message_content, :binary, public?: true
  end

  identities do
    identity :append_identity, [
      :source_system_id, :source_database, :slot_name, :commit_lsn, :ordinal
    ]
  end

  actions do
    defaults [:read]

    # The IMMUTABLE create action — the only delivery path. Update, upsert and
    # destroy actions never are. Manual actions and arbitrary action/global
    # create changes are rejected because they can rewrite the identity after
    # input validation.
    create :append do
      accept [
        :source_system_id, :source_database, :slot_name, :commit_lsn, :ordinal,
        :operation, :origin, :snapshot_attempt, :id, :note,
        :message_prefix, :message_content
      ]
    end
  end
end
```

Back that identity with a real unique index (`mix ash.codegen` generates one
from the `identity`) — it is the defensive database constraint behind
append-once. On an **attribute-multitenant** append target the identity must
also declare `all_tenants? true`, or Ash widens the upsert conflict target with
the tenant discriminator; the compile verifier rejects the omission.
All structural attributes except the stream-optional `snapshot_attempt` must be
`allow_nil?: false`; PostgreSQL unique constraints do not collide NULLs.

**Operation shapes.** `operation` is `"insert" | "update" | "delete" |
"truncate" | "message" | "snapshot"`; `origin` is `"stream" | "snapshot"`. A delete appends
the admitted **old** record, so the deleted payload survives in the log. Every
append source table therefore requires `REPLICA IDENTITY FULL`; DEFAULT identity
would supply only primary-key columns and silently truncate the delete event. A
truncate is a structural event with no payload (and, being tenant-blind, is
refused at compile time on a tenant-scoped target — use `on_truncate :halt`).
Backfill rows carry the checkpoint-owned attempt id; they reuse none of the
state-mirror provenance attributes. In append mode, each `message_routes` entry
must target a non-tenant append resource's configured append action. A
transactional message uses the transaction commit LSN and its shared ordinal; a
standalone message uses its WAL LSN and ordinal zero. Prefix/content are written
only to `append_message_prefix_attribute` / `append_message_content_attribute`
(defaults `:message_prefix` / `:message_content`); they are destination-only and
never treated as source-table columns. State-mirror message routes keep the
ADR-0015 AshOnetime contract unchanged.

**Append-once.** The append identity is exactly `(source system, database, slot,
commit LSN, ordinal)`, and delivery upserts against it with an empty
`upsert_fields` — a no-op conflict clause. A lawfully re-delivered WAL position
(a crash redo, a snapshot re-run) appends once and never rewrites the stored
event. Effect-once itself is unchanged: the append and the checkpoint commit in
one locked destination transaction.

**The origin floor.** A `:go_forward` sink records the slot origin it first
started from on the checkpoint's `origin_floor`, once. No completeness claim
covers data below it. Later reconnect origins are resume facts; a slot
*recreated* under an existing floor halts `:append_origin_gap`, and an appended
event above the durable checkpoint halts `:append_frontier_divergent`.
Replicant does not filtered-WAL idle-advance an append sink, so a reused origin
ahead of the durable checkpoint is an unambiguous `:append_origin_gap`. Publish
a normal heartbeat transaction on a quiet append publication to advance the
checkpoint and release retained WAL.

**Boundaries.** An append sink cannot run incremental snapshots (that mode
requires `snapshot_provenance` on every mapped resource, which an append target
may not declare), and a `strategy :context` append target is refused on a
go-forward sink. Separate mirror and append pipelines may use separate slots and
checkpoints; one slot is not claimed to serve both kinds.

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

A Replicant v1 retry and incremental resume are physically effect-once for resources
declaring `snapshot_provenance true`: fingerprints suppress repeated host actions,
and incremental progress commits atomically with each bounded chunk. Message (C1),
sink-owned batch delivery (C2), and incremental progress (C3) are live —
`batch_delivery` opts a pipeline into `handle_batch/1`, one destination transaction
and one watermark write per flushed batch (ADR-0016). Append-log delivery is not
exported yet and must compose with this same boundary. See
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
