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
  option is optional. Compile-time verifiers (registered in later slices)
  enforce that `sensitive` columns map to encrypted/binary targets and that a
  `tenant_attribute` is a plaintext, declared, non-classified discriminator.
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
          "Source column carrying the tenant. Resolved per row and passed as `tenant:` to the mirror action."
      ],
      tenant_mfa: [
        type: :mfa,
        doc: "`{m, f, a}` applied as `apply(m, f, [record | a])` yielding the tenant for a row."
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
        type: {:one_of, [:halt, :mirror]},
        default: :halt,
        doc:
          "Policy for an upstream TRUNCATE: `:halt` (fail-closed) or `:mirror` " <>
            "(bulk-destroy the mirror rows in-txn)."
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
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@replicant],
    verifiers: [
      AshReplicant.Resource.Verifiers.ValidateSensitive,
      AshReplicant.Resource.Verifiers.ValidateMultitenancy
    ]
end
