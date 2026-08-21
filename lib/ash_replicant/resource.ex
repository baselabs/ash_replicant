defmodule AshReplicant.Resource do
  @moduledoc """
  Spark resource extension marking a host AshPostgres resource as a CDC mirror
  target for `ash_replicant`.

  Add it to a host mirror resource:

      use Ash.Resource,
        domain: MyApp.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshReplicant.Resource]

      replicant do
        source_table "orders"
        tenant_attribute :org_id
        sensitive [:pan]
      end

  `source_table` / `source_schema` default to the resource's own
  `AshPostgres.DataLayer.Info.table/1` / `schema/1` via
  `AshReplicant.Resource.Info.source_table/1` and `source_schema/1`. Every
  option is optional. Compile-time verifiers enforce that `sensitive` columns map
  to encrypted/binary targets (`ValidateSensitive`); that a declared tenant source is
  a plaintext discriminator backed by an Ash `multitenancy` block, and that the block's
  own `:attribute` is plaintext (`ValidateMultitenancy`); that a **non-global
  multitenant** resource declares a tenant source — `tenant_attribute` or `tenant_mfa`
  (`ValidateTenantSource`); that no sink-selected action bypasses tenancy
  (`ValidateActionMultitenancy`); that an SCD2 resource's version-table shape is
  valid (`ValidateHistory`); and that a resource opting into `snapshot_provenance`
  declares the two protected attributes and the private mark/retire actions, with
  NO action able to accept those attributes as input
  (`ValidateSnapshotProvenance`, ADR-0017); and that an `append_log true` resource
  carries the immutable create action, the structural attributes, and the exact
  five-column append identity, and reuses no state-mirror machinery
  (`ValidateAppendLog`, ADR-0018).
  """

  @replicant %Spark.Dsl.Section{
    name: :replicant,
    describe:
      "Marks a host resource as a CDC mirror target and declares its source " <>
        "mapping, tenant resolution, classification, and host action contract.",
    schema: [
      source_table: [
        type: :string,
        doc: "Source table name. Defaults to the resource's own AshPostgres table via reflection."
      ],
      source_schema: [
        type: :string,
        doc:
          "Source schema name. Defaults to the resource's own AshPostgres schema, else \"public\"."
      ],
      tenant_attribute: [
        type: :atom,
        doc:
          "Source column carrying the tenant. Resolved per row and passed as `tenant:` to the mirror action. " <>
            "The source table must be `REPLICA IDENTITY FULL` so deletes, PK changes, and tenant " <>
            "reassignments carry the old tenant (key-only under the default identity)."
      ],
      tenant_mfa: [
        # `{module, function, extra_args_LIST}` — the 3rd element is a list of
        # EXTRA args, not an arity. Spark's built-in `:mfa` validates the same
        # `{m, f, list}` shape at runtime, but its InfoGenerator spec maps `:mfa`
        # to Erlang's `mfa()` (`{module, atom, arity/byte}`), which mis-describes
        # the 3rd element and breaks `apply(m, f, [record | a])`'s type in the
        # resolver. This explicit tuple type generates the accurate
        # `{atom(), atom(), [any()]}` spec while validating the identical value.
        type: {:tuple, [:atom, :atom, {:list, :any}]},
        doc:
          "`{m, f, a}` where `a` is a list of extra args, applied as " <>
            "`apply(m, f, [record | a])` yielding the tenant for a row. The function must resolve " <>
            "deterministically from both new and old record shapes."
      ],
      sensitive: [
        type: {:wrap_list, :atom},
        default: [],
        doc:
          "Source columns classified as sensitive. Verifier-enforced to map to an " <>
            "AshCloak-encrypted / binary-storage attribute, or to be listed in `skip`."
      ],
      skip: [
        type: {:wrap_list, :atom},
        default: [],
        doc: "Source columns excluded from the mirror write."
      ],
      on_truncate: [
        type: {:one_of, [:halt, :mirror, :close, :append]},
        default: :halt,
        doc:
          "Policy for an upstream TRUNCATE: `:halt` (fail-closed), `:mirror` " <>
            "(raw-delete the mirror rows in-txn), `:close` (SCD2 only — close " <>
            "every open version tenant-blind, retiring the whole window), or " <>
            "`:append` (append-log only — record the structural truncate event). " <>
            "`:mirror`/`:close` are state-mirror policies and `:append` is an " <>
            "append-log policy; mixing them is a compile error."
      ],
      on_schema_change: [
        type: {:one_of, [:halt_destructive, :ignore]},
        default: :halt_destructive,
        doc:
          "Policy for an upstream schema change: `:halt_destructive` (halt on destructive DDL) or `:ignore`."
      ],
      upsert_identity: [
        type: :atom,
        doc: "Identity name used for the mirror upsert and its matching SCD1 provenance lookup."
      ],
      history_strategy: [
        type: {:one_of, [:scd1, :scd2]},
        default: :scd1,
        doc:
          "History strategy: `:scd1` (current-state upsert/destroy mirror, default) or " <>
            "`:scd2` (validity-windowed close-current + insert-version against a host version table)."
      ],
      history_business_key: [
        type: {:wrap_list, :atom},
        default: [],
        doc:
          "SCD2 only: the source natural key (composite supported). Should be the source primary " <>
            "key; a non-PK business key requires `REPLICA IDENTITY FULL` on the source table."
      ],
      history_valid_from_lsn_attribute: [
        type: :atom,
        default: :valid_from_lsn,
        doc:
          "SCD2 only: bigint attribute stamped with the change's `commit_lsn` when a version opens."
      ],
      history_valid_to_lsn_attribute: [
        type: :atom,
        default: :valid_to_lsn,
        doc:
          "SCD2 only: nullable bigint attribute stamped with the closing change's `commit_lsn`."
      ],
      history_valid_from_timestamp_attribute: [
        type: :atom,
        doc:
          "SCD2 only (optional): nullable datetime attribute stamped with the source `commit_timestamp` " <>
            "when a version opens. Omit to store LSN windows only."
      ],
      history_valid_to_timestamp_attribute: [
        type: :atom,
        doc:
          "SCD2 only (optional): nullable datetime attribute stamped with the closing `commit_timestamp`."
      ],
      history_current_attribute: [
        type: :atom,
        doc:
          "SCD2 only (optional): boolean attribute maintained `true` on the open version and `false` on close."
      ],
      history_close_action: [
        type: :atom,
        default: :close_version,
        doc:
          "SCD2 only: the host `:update` action that sets the window columns to close a version."
      ],
      append_log: [
        type: :boolean,
        default: false,
        doc:
          "Make this resource an immutable APPEND target rather than a state mirror " <>
            "(ADR-0018). Every mapped resource of one generated sink must agree, and the " <>
            "sink must declare the matching `sink_kind` — activation rejects a mixed set. " <>
            "The resource is host-owned: it declares the structural attributes named below, " <>
            "the immutable create action, and the exact five-column append identity. " <>
            "Update, upsert, and destroy actions are never delivery paths. Every source table " <>
            "for an append resource must use REPLICA IDENTITY FULL so delete events carry the " <>
            "complete old record."
      ],
      append_action: [
        type: :atom,
        default: :append,
        doc:
          "Append-log only: the host's IMMUTABLE `:create` action the sink appends through. " <>
            "It must accept every structural attribute plus the mapped payload, and must not " <>
            "declare its own upsert, be manual, or carry arbitrary action changes; arbitrary " <>
            "global create changes are also rejected (the sink supplies the append identity's " <>
            "conflict target; AshCloak encryption of non-structural payload is admitted)."
      ],
      append_identity: [
        type: :atom,
        default: :append_identity,
        doc:
          "Append-log only: the host `identity` whose keys are EXACTLY the five append-identity " <>
            "columns (source system, source database, slot, commit LSN, ordinal). It is the " <>
            "defensive database constraint behind append-once; effect-once still rests on the " <>
            "append and the checkpoint committing in the same locked destination transaction."
      ],
      append_source_system_attribute: [
        type: :atom,
        default: :source_system_id,
        doc:
          "Append-log only: the string attribute stamped with the replication session's " <>
            "PostgreSQL system identifier."
      ],
      append_source_database_attribute: [
        type: :atom,
        default: :source_database,
        doc: "Append-log only: the string attribute stamped with the source database name."
      ],
      append_slot_attribute: [
        type: :atom,
        default: :slot_name,
        doc: "Append-log only: the string attribute stamped with the replication slot name."
      ],
      append_commit_lsn_attribute: [
        type: :atom,
        default: :commit_lsn,
        doc:
          "Append-log only: the integer (bigint) attribute stamped with the change's commit LSN."
      ],
      append_ordinal_attribute: [
        type: :atom,
        default: :ordinal,
        doc:
          "Append-log only: the integer attribute stamped with the change's ordinal within its " <>
            "commit LSN. One ordinal is one appended event — distinct same-transaction effects " <>
            "never overwrite one another."
      ],
      append_operation_attribute: [
        type: :atom,
        default: :operation,
        doc:
          "Append-log only: the string attribute stamped with the source operation " <>
            ~s|("insert" \| "update" \| "delete" \| "truncate" \| "message" \| "snapshot"). | <>
            "A library-minted structural label, never a row value."
      ],
      append_origin_attribute: [
        type: :atom,
        default: :origin,
        doc:
          "Append-log only: the string attribute stamped with the delivery origin " <>
            ~s|("stream" \| "snapshot"). | <>
            "A library-minted structural label, never a row value."
      ],
      append_attempt_attribute: [
        type: :atom,
        default: :snapshot_attempt,
        doc:
          "Append-log only: the nullable binary attribute stamped with the checkpoint-owned " <>
            "snapshot attempt id on backfill rows (NULL on streamed rows). It is the append " <>
            "target's OWN structural column — the state-mirror row-provenance attributes " <>
            "(`replica_fingerprint` / `replica_seen_attempt`) are never reused here."
      ],
      append_message_prefix_attribute: [
        type: :atom,
        default: :message_prefix,
        doc:
          "Append-log message routes only: the string attribute that receives the logical " <>
            "message prefix. It must be accepted by the immutable append action."
      ],
      append_message_content_attribute: [
        type: :atom,
        default: :message_content,
        doc:
          "Append-log message routes only: the binary-storage attribute that receives the " <>
            "logical message content. It must be accepted by the immutable append action."
      ],
      snapshot_provenance: [
        type: :boolean,
        default: false,
        doc:
          "Opt the resource into the snapshot provenance and retirement contract (ADR-0017). " <>
            "When true the resource must declare the two protected attributes " <>
            "`replica_fingerprint` and `replica_seen_attempt` (binary, non-sensitive, " <>
            "`public?: false`, `writable?: false`, accepted by NO action) plus the private " <>
            "mark and retire actions below. Defaults to `false` so a resource that does not " <>
            "back a snapshot keeps compiling unchanged."
      ],
      snapshot_mark_action: [
        type: :atom,
        default: :replicant_mark_seen,
        doc:
          "The host's PRIVATE (`public? false`) `:update` action that records snapshot-attempt " <>
            "membership. It must carry the `AshReplicant.Snapshot.MarkSeen` change, which " <>
            "force-changes the protected attributes from the sink-supplied changeset context — " <>
            "the attributes are never an action input."
      ],
      snapshot_retire_action: [
        type: :atom,
        default: :replicant_retire_unseen,
        doc:
          "The host's PRIVATE (`public? false`) retirement action for rows unseen by a completed " <>
            "snapshot attempt: a `:destroy` under `history_strategy :scd1`, or the version-closing " <>
            "`:update` under `:scd2`."
      ],
      snapshot_tenant_scope_action: [
        type: :atom,
        doc:
          "REQUIRED for a non-global `strategy :context` multitenant resource with " <>
            "`snapshot_provenance true`: the host's PRIVATE generic action returning the array of " <>
            "retained tenant contexts. Completion retires per scope, and context multitenancy has " <>
            "no discriminator column to take DISTINCT over, so the host is the only authority on " <>
            "which scopes exist — including one wholly absent from the source attempt. Ignored " <>
            "under attribute multitenancy (the discriminator enumerates itself) and for global or " <>
            "non-multitenant resources (one scoped pass)."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@replicant],
    verifiers: [
      AshReplicant.Resource.Verifiers.ValidateSensitive,
      AshReplicant.Resource.Verifiers.ValidateMultitenancy,
      AshReplicant.Resource.Verifiers.ValidateTenantSource,
      AshReplicant.Resource.Verifiers.ValidateActionMultitenancy,
      AshReplicant.Resource.Verifiers.ValidateHistory,
      AshReplicant.Resource.Verifiers.ValidateSnapshotProvenance,
      AshReplicant.Resource.Verifiers.ValidateAppendLog
    ]
end
