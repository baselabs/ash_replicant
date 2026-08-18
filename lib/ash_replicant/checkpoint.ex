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

  ## Default-deny trust posture (B7 / ADR-0014)

  The checkpoint is an internal watermark, not tenant data: nothing outside
  the sink should read or write it. By default the generated resource carries
  `Ash.Policy.Authorizer` with NO policies — an empty policy set authorizes
  nothing, so EVERY external actor is denied every action (fail-closed), even
  on a wire surface the host adds later.

  The sink always reads and upserts the checkpoint with `authorize?: false`
  on both paths (its internal read and upsert helpers), so it bypasses policy
  — effect-once is unaffected by the authorizer. The operator functions
  (`AshReplicant.adopt_checkpoint/3`, `reset_checkpoint/2`,
  `acknowledge_checkpoint_timeline/3`) and the `:operator_reset` destroy they
  route through run on the same bypass.

  To grant specific access, declare your own policies in the module body:

      use AshReplicant.Checkpoint,
        repo: MyApp.Repo,
        domain: MyApp.Domain

      policies do
        default_access_type :strict

        policy always() do
          authorize_if MyApp.Checks.SystemActor
        end
      end

  Hosts that already front the resource with their own authorization can
  reproduce the pre-B7 unguarded shape with `authorizers: []`.

  The generated `:operator_reset` destroy action exists for the operator
  escape hatch (`AshReplicant.reset_checkpoint/2`) — the sink never destroys
  mid-flight. It is a NAMED action (not a primary `:destroy`) so code
  interfaces and route generators do not auto-discover it.
  """

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :domain)
    # DEFAULT-DENY (B7/ADR-0014): the policy authorizer with an empty policy
    # set denies every external actor; the sink's authorize?: false paths are
    # untouched. `authorizers: []` opts out to the pre-B7 unguarded shape.
    authorizers = Keyword.get(opts, :authorizers, [Ash.Policy.Authorizer])

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
        # and route generators auto-discover; the named one stays off that surface,
        # and the default-deny authorizer guards any other caller.
        destroy :operator_reset
      end
    end
  end
end
