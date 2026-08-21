defmodule AshReplicant.Test.AppendDomain do
  @moduledoc """
  The append-log (ADR-0018) fixture domain.

  Kept SEPARATE from `AshReplicant.Test.Domain` on purpose: a generated sink is
  exclusively `:state_mirror` or `:append_log`, and activation rejects a mixed
  resource set. Two domains is what lets the suite drive both a conforming
  append sink and the mixed-kind rejection.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.OrderEvent
    resource AshReplicant.Test.TenantOrderEvent
    resource AshReplicant.Test.SecretEvent
  end
end

defmodule AshReplicant.Test.OrderEvent do
  @moduledoc """
  The canonical append target: a HOST-owned immutable event resource mapped to
  the `orders` source table. Nothing here is package-generated — ADR-0018 §2 is
  precisely that the host owns the table, the create action, and the identity.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.AppendDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "order_events"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("orders")
    append_log(true)
    on_truncate(:append)
  end

  attributes do
    uuid_primary_key :event_id

    # The five append-identity axes (ADR-0018 §3), plus the two structural
    # labels and the backfill attempt.
    attribute :source_system_id, :string, allow_nil?: false, public?: true
    attribute :source_database, :string, allow_nil?: false, public?: true
    attribute :slot_name, :string, allow_nil?: false, public?: true
    attribute :commit_lsn, :integer, allow_nil?: false, public?: true
    attribute :ordinal, :integer, allow_nil?: false, public?: true
    attribute :operation, :string, allow_nil?: false, public?: true
    attribute :origin, :string, allow_nil?: false, public?: true
    attribute :snapshot_attempt, :binary, public?: true

    # The mapped payload: the same source columns the state mirror maps, under
    # the same classification rules.
    attribute :id, :string, public?: true
    attribute :note, :string, public?: true
    attribute :body, :string, public?: true
    attribute :message_prefix, :string, public?: true
    attribute :message_content, :binary, public?: true
  end

  identities do
    identity :append_identity, [
      :source_system_id,
      :source_database,
      :slot_name,
      :commit_lsn,
      :ordinal
    ]
  end

  actions do
    defaults [:read]

    create :append do
      accept [
        :source_system_id,
        :source_database,
        :slot_name,
        :commit_lsn,
        :ordinal,
        :operation,
        :origin,
        :snapshot_attempt,
        :id,
        :note,
        :body,
        :message_prefix,
        :message_content
      ]
    end
  end
end

defmodule AshReplicant.Test.TenantOrderEvent do
  @moduledoc """
  A tenant-scoped append target: every appended event is written under the
  per-row resolved tenant, exactly as a tenant-scoped mirror row is. Its
  `on_truncate` stays `:halt` — a TRUNCATE is tenant-blind and the verifier
  refuses to append one from a tenant-scoped target.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.AppendDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "tenant_order_events"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("tenant_orders")
    append_log(true)
    tenant_attribute(:org_id)
  end

  attributes do
    uuid_primary_key :event_id

    attribute :source_system_id, :string, allow_nil?: false, public?: true
    attribute :source_database, :string, allow_nil?: false, public?: true
    attribute :slot_name, :string, allow_nil?: false, public?: true
    attribute :commit_lsn, :integer, allow_nil?: false, public?: true
    attribute :ordinal, :integer, allow_nil?: false, public?: true
    attribute :operation, :string, allow_nil?: false, public?: true
    attribute :origin, :string, allow_nil?: false, public?: true
    attribute :snapshot_attempt, :binary, public?: true

    attribute :id, :string, public?: true
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  identities do
    # `all_tenants? true` is LOAD-BEARING: without it Ash prepends the tenant
    # discriminator to the upsert conflict target, which both widens the append
    # identity past ADR-0018 §3's five axes and stops matching the host's
    # five-column unique index.
    identity :append_identity,
             [:source_system_id, :source_database, :slot_name, :commit_lsn, :ordinal],
             all_tenants?: true
  end

  actions do
    defaults [:read]

    create :append do
      accept [
        :source_system_id,
        :source_database,
        :slot_name,
        :commit_lsn,
        :ordinal,
        :operation,
        :origin,
        :snapshot_attempt,
        :id,
        :org_id,
        :note
      ]
    end
  end
end

defmodule AshReplicant.Test.SecretEvent do
  @moduledoc """
  A classified append target: the `pan` payload column is `sensitive`, so it
  travels the SAME AshCloak path a sensitive mirror column does (ADR-0018 §6 —
  "append payloads use the same tenant and sensitive-type rules as state
  mirrors"). The structural axes are never classified.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.AppendDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource, AshCloak]

  postgres do
    table "secret_order_events"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("secret_orders")
    append_log(true)
    sensitive([:pan])
  end

  cloak do
    vault AshReplicant.Test.CloakVault
    attributes [:pan]
    # NO `decrypt_by_default`: it injects an `Ash.Resource.Change.Load` into the
    # append action, which the destination manifest rejects as an undeclared
    # participant. The plaintext is read as AshCloak's `:pan` calculation
    # instead, which proves the same round trip without widening the admitted
    # action graph.
  end

  attributes do
    uuid_primary_key :event_id

    attribute :source_system_id, :string, allow_nil?: false, public?: true
    attribute :source_database, :string, allow_nil?: false, public?: true
    attribute :slot_name, :string, allow_nil?: false, public?: true
    attribute :commit_lsn, :integer, allow_nil?: false, public?: true
    attribute :ordinal, :integer, allow_nil?: false, public?: true
    attribute :operation, :string, allow_nil?: false, public?: true
    attribute :origin, :string, allow_nil?: false, public?: true
    attribute :snapshot_attempt, :binary, public?: true

    attribute :id, :string, public?: true
    attribute :pan, :string, public?: true
  end

  identities do
    identity :append_identity, [
      :source_system_id,
      :source_database,
      :slot_name,
      :commit_lsn,
      :ordinal
    ]
  end

  actions do
    defaults [:read]

    create :append do
      accept [
        :source_system_id,
        :source_database,
        :slot_name,
        :commit_lsn,
        :ordinal,
        :operation,
        :origin,
        :snapshot_attempt,
        :id,
        :pan
      ]
    end
  end
end

defmodule AshReplicant.Test.AppendSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.AppendDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "append_slot",
    sink_kind: :append_log,
    initial_state: :go_forward,
    message_routes: [{"events", AshReplicant.Test.OrderEvent, :append}]
end
