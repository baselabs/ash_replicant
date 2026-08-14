defmodule AshReplicant.Checkpoint do
  @moduledoc """
  `use AshReplicant.Checkpoint, repo: MyApp.Repo, domain: MyApp.Domain` generates the
  bundled AshPostgres checkpoint resource (table `ash_replicant_checkpoints`) bound to
  the host's repo and domain.

  One row per replication source and slot: the primary key is the composite
  `(source_system_id, source_database, slot_name)` taken from the actual
  replication session's `IDENTIFY_SYSTEM` identity, with the session timeline
  recorded beside it. The durable `commit_lsn` watermark, the canonical
  publication/resolver contract manifest, and its fingerprint live on the same
  row. The sink upserts the watermark in the same transaction as the mirrored
  changes, which is what gives effect-once (dup = 0) semantics.

  A macro is required because an AshPostgres resource needs its host `repo` at compile
  time; `ash_replicant` cannot hardcode it.

  ## Upgrading from the slot-only shape (pre-B2)

  The generated shape CHANGED: the slot-only primary key became the source-bound
  triple, and new attributes landed (`source_timeline`, `publication_contract`,
  `publication_fingerprint`, `snapshot_progress`, `snapshot_generation`,
  timestamps). Hosts regenerate their migration (`mix ash.codegen`) and — when
  slot-only rows exist — follow the capture/delete/migrate/adopt runbook in
  `usage-rules.md` before migrating: the structural migration itself refuses
  ambiguous legacy rows (the NOT NULL identity columns abort `ecto.migrate` on
  any surviving row).

  ## Locking the checkpoint down with policies

  The checkpoint is an internal watermark, not tenant data: nothing outside the sink
  should read or write it. By default the generated resource carries no authorizer (so
  `policies do` is not even a declarable section), which means a host that exposes it on
  a wire surface — a JSON:API route, an MCP tool — has no way to enforce that. Pass the
  policy authorizer to close that:

      use AshReplicant.Checkpoint,
        repo: MyApp.Repo,
        domain: MyApp.Domain,
        authorizers: [Ash.Policy.Authorizer]

      # ...then declare your own policies in the module body, e.g. system-only:
      policies do
        default_access_type :strict

        policy always() do
          authorize_if MyApp.Checks.SystemActor
        end
      end

  The sink always reads and upserts the checkpoint with `authorize?: false` on both
  paths (its internal read and upsert helpers), so it bypasses
  policy — effect-once is unaffected by whatever policies the host
  declares, including none. With the authorizer present and no policies declared, the
  resource is fail-closed to every actor except the sink's `authorize?: false` path,
  which is the safe default for a watermark.

  The generated `:operator_reset` destroy action exists for the operator escape
  hatch (`AshReplicant.reset_checkpoint/2`) — the sink never destroys mid-flight.
  """

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :domain)
    # Opt-in, default []. The consumer passes [Ash.Policy.Authorizer] to make the
    # generated resource policy-capable and then declares its own `policies do` block;
    # `authorizers: []` is identical to the option Ash already defaults to.
    authorizers = Keyword.get(opts, :authorizers, [])

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: unquote(authorizers)

      postgres do
        table "ash_replicant_checkpoints"
        repo unquote(repo)

        # The shipped unique slot index is KEPT (0.4 created it as the old identity):
        # one bound row per slot name is the substrate enforcement of the
        # same-slot-single-source invariant — a racing bind of a different source
        # triple under the same slot fails here instead of wedging pipelines on
        # classified sibling halts.
        custom_indexes do
          index [:slot_name],
            unique: true,
            name: "ash_replicant_checkpoints_unique_slot_index"
        end
      end

      attributes do
        # Composite primary key = the unique source-bound identity: the actual
        # replication session's system identifier + database + the slot.
        attribute :source_system_id, :string do
          primary_key? true
          allow_nil? false
        end

        attribute :source_database, :string do
          primary_key? true
          allow_nil? false
        end

        attribute :slot_name, :string do
          primary_key? true
          allow_nil? false
        end

        # The session timeline at bind. NOT part of the unique identity — a timeline
        # change on the same source is an operator continuity decision, never a new row.
        attribute :source_timeline, :integer do
          allow_nil? true
        end

        # Canonical value-free publication/resolver contract (deterministic term) and
        # its sha256 fingerprint. NULL until the first bind fills them.
        attribute :publication_contract, :binary do
          allow_nil? true
        end

        attribute :publication_fingerprint, :binary do
          allow_nil? true
        end

        # Ash `:integer` maps to Postgres `bigint` under AshPostgres — LSNs exceed int4.
        # Nullable: the row exists from bind on; "non-null after the first commit" is a
        # lock-enforced admission invariant, not a column constraint.
        attribute :commit_lsn, :integer do
          allow_nil? true
        end

        # Incremental-snapshot frontier columns (roadmap C3); inert until then.
        attribute :snapshot_progress, :binary do
          allow_nil? true
        end

        attribute :snapshot_generation, :binary do
          allow_nil? true
        end

        timestamps()
      end

      identities do
        identity :source_slot, [:source_system_id, :source_database, :slot_name]
      end

      actions do
        defaults [:read]

        create :upsert do
          upsert? true
          upsert_identity :source_slot

          accept [
            :source_system_id,
            :source_database,
            :slot_name,
            :source_timeline,
            :publication_contract,
            :publication_fingerprint,
            :commit_lsn
          ]
        end

        # NAMED destroy (not `defaults [:destroy]`): callable only by
        # AshReplicant.reset_checkpoint/2 — a primary destroy is what code interfaces
        # and route generators auto-discover, and the resource is unguarded until
        # default-deny policies land (roadmap B7).
        destroy :operator_reset
      end
    end
  end
end
