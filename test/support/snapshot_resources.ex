defmodule AshReplicant.Test.SnapshotDomain do
  @moduledoc """
  S02 fixtures (ADR-0017): the snapshot-provenance mirror targets.

  These live in their OWN domain rather than `AshReplicant.Test.Domain` so
  every pre-existing sink's resolver index, destination manifest and manifest
  digest are unchanged by their arrival.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.SnapOrder
    resource AshReplicant.Test.SnapTenantOrder
    resource AshReplicant.Test.SnapVersion
  end
end

defmodule AshReplicant.Test.SnapOrder do
  @moduledoc """
  SCD1, non-tenant, `snapshot_provenance true`. The baseline retry fixture:
  unchanged rows must be marked without repeating the host `:create` effect.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.SnapshotDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "snap_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("snap_orders")
    snapshot_provenance(true)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true

    attribute :replica_fingerprint, :binary, public?: false, writable?: false
    attribute :replica_seen_attempt, :binary, public?: false, writable?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

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
end

defmodule AshReplicant.Test.SnapTenantOrder do
  @moduledoc """
  SCD1 under NON-GLOBAL attribute multitenancy on `org_id`. Completion has to
  enumerate the distinct destination discriminator values and retire under each
  one, so a tenant present only in the DESTINATION (absent from the source
  attempt) is still swept — and never swept tenant-blind.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.SnapshotDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "snap_tenant_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("snap_tenant_orders")
    tenant_attribute(:org_id)
    snapshot_provenance(true)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :note, :string, public?: true

    attribute :replica_fingerprint, :binary, public?: false, writable?: false
    attribute :replica_seen_attempt, :binary, public?: false, writable?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

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
end

defmodule AshReplicant.Test.SnapVersion do
  @moduledoc """
  SCD2 with provenance. Retirement CLOSES an unseen open version through the
  private version-closing update — closed history is immutable, so it must
  never be reopened, rewritten, or destroyed.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.SnapshotDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "snap_versions"
    repo AshReplicant.TestRepo

    custom_indexes do
      index [:order_id],
        unique: true,
        where: "valid_to_lsn IS NULL",
        name: "snap_versions_open_uniq"
    end
  end

  replicant do
    source_table("snap_versions")
    history_strategy(:scd2)
    history_business_key([:order_id])
    upsert_identity(:snap_version)
    history_close_action(:close_version)
    history_current_attribute(:is_current)
    snapshot_provenance(true)
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :string, allow_nil?: false, public?: true
    attribute :amount, :string, public?: true
    attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
    attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
    attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true

    attribute :replica_fingerprint, :binary, public?: false, writable?: false
    attribute :replica_seen_attempt, :binary, public?: false, writable?: false
  end

  identities do
    identity :snap_version, [:order_id, :valid_from_lsn]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :close_version do
      accept [:valid_to_lsn, :is_current]
    end

    update :replicant_mark_seen do
      public? false
      accept []
      require_atomic? false
      change AshReplicant.Snapshot.MarkSeen
    end

    update :replicant_retire_unseen do
      public? false
      accept [:valid_to_lsn, :is_current]
    end
  end
end

defmodule AshReplicant.Test.SnapshotContextDomain do
  @moduledoc """
  The CONTEXT-multitenant snapshot fixture, deliberately OUTSIDE the configured
  `ash_domains` list: its tables live in per-tenant Postgres schemas created by
  a hand-authored migration, which is not something `mix ash.codegen` should be
  asked to reproduce.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.SnapCtxOrder
  end
end

defmodule AshReplicant.Test.SnapCtxTenants do
  @moduledoc """
  The host's authoritative retained-scope enumerator for
  `AshReplicant.Test.SnapCtxOrder`, behind a swappable process-local override
  so a test can make it return a partial, empty, or malformed list and prove
  completion fails CLOSED rather than under-retiring.
  """
  use Ash.Resource.Actions.Implementation
  @behaviour AshReplicant.DestinationParticipant

  @override {__MODULE__, :override}
  @default ["ctx_org_a", "ctx_org_b"]

  # The enumerator reaches no database at all in this fixture (a real host
  # would declare the tenant-registry read it performs).
  @impl AshReplicant.DestinationParticipant
  def destination_participants(_opts, _context), do: {:ok, :no_database}

  @doc "The scopes the enumerator reports by default."
  def default_scopes, do: @default

  @doc "Override the enumeration for the current process (and its Ash call)."
  def put_override(value), do: Process.put(@override, value)

  @doc "Drop the override, restoring the default enumeration."
  def clear_override, do: Process.delete(@override)

  @impl Ash.Resource.Actions.Implementation
  def run(_input, _opts, _context) do
    case Process.get(@override, :none) do
      :none -> {:ok, @default}
      {:raise, message} -> raise message
      value -> {:ok, value}
    end
  end
end

defmodule AshReplicant.Test.SnapCtxOrder do
  @moduledoc """
  Context (schema-per-tenant) multitenancy with provenance. There is no tenant
  DISCRIMINATOR column to take DISTINCT over, so completion has to enumerate
  the retained scopes through the declared authoritative host action.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.SnapshotContextDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "snap_ctx_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("snap_ctx_orders")
    # The source carries the tenant's schema name in a column the DESTINATION
    # does not mirror (context multitenancy has no discriminator attribute), so
    # it is skipped rather than mapped.
    skip([:org_schema])
    tenant_mfa({AshReplicant.Test.SnapCtxTenant, :resolve, []})
    snapshot_provenance(true)
    snapshot_tenant_scope_action(:replicant_retained_scopes)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true

    attribute :replica_fingerprint, :binary, public?: false, writable?: false
    attribute :replica_seen_attempt, :binary, public?: false, writable?: false
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    action :replicant_retained_scopes, {:array, :string} do
      public? false
      run AshReplicant.Test.SnapCtxTenants
    end

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
end

defmodule AshReplicant.Test.SnapCtxTenant do
  @moduledoc "Resolves the per-row tenant for `AshReplicant.Test.SnapCtxOrder`."
  @behaviour AshReplicant.DestinationParticipant

  @impl AshReplicant.DestinationParticipant
  def destination_participants(_opts, _context), do: {:ok, :no_database}

  @doc false
  def resolve(record), do: Map.get(record, "org_schema")
end
