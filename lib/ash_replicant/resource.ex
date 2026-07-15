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
  (`ValidateActionMultitenancy`); and that an SCD2 resource's version-table shape is
  valid (`ValidateHistory`).
  """

  @replicant %Spark.Dsl.Section{
    name: :replicant,
    describe:
      "Marks a host resource as a CDC mirror target and declares its source " <>
        "mapping, tenant resolution, classification, and per-resource policies.",
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
            "The source table must be `REPLICA IDENTITY FULL` so a delete's / PK-changing update's `old_record` " <>
            "carries the tenant column (key-only under the default identity → fail-closed `:tenant_required`)."
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
            "`apply(m, f, [record | a])` yielding the tenant for a row."
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
        type: {:one_of, [:halt, :mirror, :close]},
        default: :halt,
        doc:
          "Policy for an upstream TRUNCATE: `:halt` (fail-closed), `:mirror` " <>
            "(raw-delete the mirror rows in-txn), or `:close` (SCD2 only — close " <>
            "every open version tenant-blind, retiring the whole window)."
      ],
      on_schema_change: [
        type: {:one_of, [:halt_destructive, :ignore]},
        default: :halt_destructive,
        doc:
          "Policy for an upstream schema change: `:halt_destructive` (halt on destructive DDL) or `:ignore`."
      ],
      upsert_identity: [
        type: :atom,
        doc: "Identity name used for the upsert-by-PK mirror write."
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
      AshReplicant.Resource.Verifiers.ValidateHistory
    ]
end
