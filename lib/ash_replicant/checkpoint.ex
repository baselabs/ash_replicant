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
  `publication_fingerprint`, `snapshot_progress`, `snapshot_state`,
  timestamps). Hosts regenerate their migration (`mix ash.codegen`) and — when
  slot-only rows exist — follow the capture/delete/migrate/adopt runbook in
  `usage-rules.md` before migrating: the structural migration itself refuses
  ambiguous legacy rows (the NOT NULL identity columns abort `ecto.migrate` on
  any surviving row).

  ## Upgrading for append-log delivery (ADR-0018)

  One nullable column is ADDED: `origin_floor`, the immutable slot origin a
  go-forward append sink first started from. It is always NULL for a
  state-mirror host, so the regenerated migration adds an always-NULL column
  and requires no data capture: run `mix ash.codegen` and migrate.

  ## Upgrading from `snapshot_generation` (pre-S02)

  The reserved-but-inert `snapshot_generation` column is REPLACED by
  `snapshot_state` (ADR-0017). Nothing ever wrote `snapshot_generation`, so the
  regenerated migration drops an always-NULL column and adds an always-NULL one:
  run `mix ash.codegen` and migrate. No data capture is required.

  ## Upgrading for runtime status tombstones (O02)

  Three nullable columns are ADDED: `terminal_cause`, `terminal_class`, and
  `terminal_at` — the bounded, value-free record of why the slot's last
  generation ended (`AshReplicant.status/1`). They are cleared by every
  admitted checkpoint write, so the regenerated migration adds always-NULL
  columns and requires no data capture: run `mix ash.codegen` and migrate.

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

    # One resource template: the attributes/identities/actions sections are
    # inherently cohesive (a host reads them as one generated file); the
    # O02 tombstone and O03 witness columns pushed it past the line budget.
    # credo:disable-for-lines:165 Credo.Check.Refactor.LongQuoteBlocks
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

        # The exact opaque Replicant incremental progress token, committed with
        # each chunk's destination effects and snapshot-state cursor.
        attribute :snapshot_progress, :binary do
          allow_nil? true
        end

        # The snapshot state envelope (ADR-0017): one versioned, authenticated,
        # strictly decoded `AshReplicant.Snapshot.State` — mode, status, the
        # random attempt id, the V1 delivery run, the bound contract digest,
        # the provenance key version, and the completion replay fence. The sink
        # reads and writes it under the checkpoint row lock, which is what
        # serializes chunks, completion and retirement against each other.
        attribute :snapshot_state, :binary do
          allow_nil? true
        end

        # The append log's IMMUTABLE origin floor (ADR-0018 §5): the slot origin
        # a go-forward append sink first started from. Written ONCE, on the first
        # admitted activation, under the checkpoint row lock; every later
        # reconnect origin is a moving resume fact checked against it and the
        # durable frontier, never a replacement. NULL on a state-mirror sink and
        # on a snapshot-intent append sink (whose floor is the snapshot's own
        # consistent point). No completeness claim covers data below it.
        attribute :origin_floor, :integer do
          allow_nil? true
        end

        # O02 (issue #12 / ADR-0019): the bounded lifecycle tombstone — why the
        # slot's last generation ended, as a CLOSED value-free string (a reason
        # atom name, or "invalid_destination_config/<tag>" for the one structural
        # tuple). `terminal_class` is "halt" | "misconfigured" | "stopped";
        # `terminal_at` is the time the cause was recorded. A tombstone never
        # carries a row value, message prefix, or progress token, and every
        # admitted checkpoint write clears all three (the row is live again).
        attribute :terminal_cause, :string do
          allow_nil? true
        end

        attribute :terminal_class, :string do
          allow_nil? true
        end

        attribute :terminal_at, :utc_datetime_usec do
          allow_nil? true
        end

        # O03 (issue #13 / ADR-0020): the authenticated digest-key-set
        # witness (`AshReplicant.Horizon.KeyState`) — the last-observed
        # message-digest key versions, active version, and observation time,
        # MAC'd under the orthogonal :horizon_provenance_keys family. NULL
        # until the first bind of a claim-routed sink. Like the tombstone it
        # is control-plane state: written at bind and on census-observed key
        # set changes only, value-free (version integers + a timestamp, never
        # key bytes).
        attribute :digest_key_state, Ash.Type.Binary do
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
            :commit_lsn,
            :snapshot_progress,
            :snapshot_state,
            :origin_floor,
            :terminal_cause,
            :terminal_class,
            :terminal_at,
            :digest_key_state
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
