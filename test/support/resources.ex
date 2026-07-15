defmodule AshReplicant.Test.Vault do
  @moduledoc false
  use Cloak.Vault, otp_app: :ash_replicant

  @impl GenServer
  def init(config) do
    key = :crypto.hash(:sha256, "ash_replicant-test-fixed-key")
    ciphers = [default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key, iv_length: 12}]
    {:ok, Keyword.put(config, :ciphers, ciphers)}
  end
end

defmodule AshReplicant.Test.Order do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("orders")
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true
    attribute :body, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.Account do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "accounts"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("accounts")
    tenant_attribute(:org_id)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.TenantOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "tenant_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("tenant_orders")
    tenant_attribute(:org_id)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id

    # NOTE: no `global? true`, so this is a NON-global tenant resource; every op requires a tenant.
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.Secret do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource, AshCloak]

  postgres do
    table "secret_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("secret_orders")
    sensitive([:pan])
  end

  cloak do
    vault AshReplicant.Test.Vault
    attributes [:pan]
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :pan, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.TenantMfa do
  @moduledoc """
  Helper for `AshReplicant.Test.MfaOrder`'s `tenant_mfa`. `resolve/2` receives
  the row (prepended by the resolver) plus one EXTRA arg (the tenant column
  key), proving `apply(m, f, [record | a])` threads the args-list correctly.
  """
  def resolve(record, key) when is_map(record), do: Map.get(record, key)
end

defmodule AshReplicant.Test.MfaDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.MfaOrder
  end
end

defmodule AshReplicant.Test.MfaOrder do
  @moduledoc """
  Ets-backed replicant resource exercising `tenant_mfa {m, f, [extra_arg]}`.
  Locks that the explicit `{:tuple, [:atom, :atom, {:list, :any}]}` DSL type
  still VALIDATES an `{Mod, :fun, [extra]}` value and that `resolve_tenant/2`
  applies it as `apply(m, f, [record | extra_args])`.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.MfaDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshReplicant.Resource]

  replicant do
    source_table("mfa_orders")
    tenant_mfa({AshReplicant.Test.TenantMfa, :resolve, ["tenant_key"]})
  end

  # A tenant_mfa resource requires an Ash multitenancy block (ValidateMultitenancy) — the
  # sink's `tenant:` is honored only under declared multitenancy. `:context` is the typical
  # mfa pairing (the tenant is a computed function result, not a stored attribute).
  multitenancy do
    strategy :context
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshReplicant.Test.OrderVersion do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.HistoryDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "order_versions"
    repo AshReplicant.TestRepo

    custom_indexes do
      index [:order_id],
        unique: true,
        where: "valid_to_lsn IS NULL",
        name: "order_versions_open_uniq"
    end
  end

  replicant do
    source_table("orders")
    history_strategy(:scd2)
    history_business_key([:order_id])
    upsert_identity(:order_version)
    history_close_action(:close_version)
    history_current_attribute(:is_current)
    history_valid_from_timestamp_attribute(:valid_from_ts)
    history_valid_to_timestamp_attribute(:valid_to_ts)
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :string, allow_nil?: false, public?: true
    attribute :amount, :string, public?: true
    attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
    attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
    attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :valid_to_ts, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
  end

  identities do
    identity :order_version, [:order_id, :valid_from_lsn]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :close_version do
      accept [:valid_to_lsn, :valid_to_ts, :is_current]
    end
  end
end

defmodule AshReplicant.Test.OrderVersionCloseTruncate do
  @moduledoc """
  SCD2 fixture identical to `OrderVersion` but with `on_truncate(:close)`, exercising
  Task 7's tenant-blind window-only close of every open version on an upstream TRUNCATE.
  Its own `order_versions_ct` table (and open-uniq index) avoids colliding with
  `OrderVersion`; `source_table("orders")` collides with the SCD1 `Order` under
  `build_index`'s duplicate-source guard, so it lives in `HistoryDomain`, never
  passed to `build_index([Test.Domain])`.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.HistoryDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "order_versions_ct"
    repo AshReplicant.TestRepo

    custom_indexes do
      index [:order_id],
        unique: true,
        where: "valid_to_lsn IS NULL",
        name: "order_versions_ct_open_uniq"
    end
  end

  replicant do
    source_table("orders")
    on_truncate(:close)
    history_strategy(:scd2)
    history_business_key([:order_id])
    upsert_identity(:order_version)
    history_close_action(:close_version)
    history_current_attribute(:is_current)
    history_valid_from_timestamp_attribute(:valid_from_ts)
    history_valid_to_timestamp_attribute(:valid_to_ts)
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :string, allow_nil?: false, public?: true
    attribute :amount, :string, public?: true
    attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
    attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
    attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :valid_to_ts, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
  end

  identities do
    identity :order_version, [:order_id, :valid_from_lsn]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :close_version do
      accept [:valid_to_lsn, :valid_to_ts, :is_current]
    end
  end
end

defmodule AshReplicant.Test.OrderVersionMirror do
  @moduledoc """
  SCD2 fixture with `on_truncate(:mirror)`, exercising Task 7's `mirror_wipe` (raw
  DELETE of the whole version table). Its own `order_versions_m` table avoids
  colliding with the other SCD2 fixtures; `source_table("orders")` collides with the
  SCD1 `Order` under `build_index`'s duplicate-source guard, so it lives in
  `HistoryDomain`.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.HistoryDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "order_versions_m"
    repo AshReplicant.TestRepo

    custom_indexes do
      index [:order_id],
        unique: true,
        where: "valid_to_lsn IS NULL",
        name: "order_versions_m_open_uniq"
    end
  end

  replicant do
    source_table("orders")
    on_truncate(:mirror)
    history_strategy(:scd2)
    history_business_key([:order_id])
    upsert_identity(:order_version)
    history_close_action(:close_version)
    history_current_attribute(:is_current)
    history_valid_from_timestamp_attribute(:valid_from_ts)
    history_valid_to_timestamp_attribute(:valid_to_ts)
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :string, allow_nil?: false, public?: true
    attribute :amount, :string, public?: true
    attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
    attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
    attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :valid_to_ts, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
  end

  identities do
    identity :order_version, [:order_id, :valid_from_lsn]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :close_version do
      accept [:valid_to_lsn, :valid_to_ts, :is_current]
    end
  end
end

defmodule AshReplicant.Test.OrderVersionTenant do
  @moduledoc """
  MULTITENANT SCD2 fixture (non-global attribute multitenancy on `org_id`) with
  `on_truncate(:close)`, proving `close_all` is TENANT-BLIND: its raw UPDATE closes
  every open version across ALL tenants with no tenant filter. A tenant-scoped
  `bulk_update` would raise `TenantRequired` on a non-global multitenant resource
  (no single tenant to scope by) — the reason close uses raw SQL. Its own
  `order_versions_t` table; lives in `HistoryDomain` (duplicate `source_table`).
  """
  use Ash.Resource,
    domain: AshReplicant.Test.HistoryDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "order_versions_t"
    repo AshReplicant.TestRepo

    custom_indexes do
      index [:order_id],
        unique: true,
        where: "valid_to_lsn IS NULL",
        name: "order_versions_t_open_uniq"
    end
  end

  replicant do
    source_table("orders")
    tenant_attribute(:org_id)
    on_truncate(:close)
    history_strategy(:scd2)
    history_business_key([:order_id])
    upsert_identity(:order_version)
    history_close_action(:close_version)
    history_current_attribute(:is_current)
    history_valid_from_timestamp_attribute(:valid_from_ts)
    history_valid_to_timestamp_attribute(:valid_to_ts)
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :string, allow_nil?: false, public?: true
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :amount, :string, public?: true
    attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
    attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
    attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :valid_to_ts, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  identities do
    identity :order_version, [:order_id, :valid_from_lsn]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :close_version do
      accept [:valid_to_lsn, :valid_to_ts, :is_current]
    end
  end
end

defmodule AshReplicant.Test.OrderVersionOrgScoped do
  @moduledoc """
  Multitenant SCD2 fixture with a PER-TENANT open-uniq index
  (`UNIQUE (org_id, order_id) WHERE valid_to_lsn IS NULL`) — the correct shape for a
  multitenant version table: it allows the SAME business key to be open in DIFFERENT
  tenants (the global `order_versions_t` index cannot). Used to prove the SCD2 per-change
  close is tenant-scoped — closing one tenant's version must NOT retire another tenant's
  identically-keyed open version. Its own `order_versions_pt` table; lives in `HistoryDomain`.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.HistoryDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "order_versions_pt"
    repo AshReplicant.TestRepo

    custom_indexes do
      index [:org_id, :order_id],
        unique: true,
        where: "valid_to_lsn IS NULL",
        name: "order_versions_pt_open_uniq"
    end
  end

  replicant do
    source_table("orders")
    tenant_attribute(:org_id)
    history_strategy(:scd2)
    history_business_key([:order_id])
    upsert_identity(:order_version)
    history_close_action(:close_version)
    history_current_attribute(:is_current)
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :string, allow_nil?: false, public?: true
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :amount, :string, public?: true
    attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
    attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
    attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  identities do
    identity :order_version, [:order_id, :valid_from_lsn]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :close_version do
      accept [:valid_to_lsn, :is_current]
    end
  end
end

defmodule AshReplicant.Test.DuplicateDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.DupA
    resource AshReplicant.Test.DupB
  end
end

defmodule AshReplicant.Test.DupA do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.DuplicateDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "dup_a"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("dup_orders")
    source_schema("public")
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshReplicant.Test.DupB do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.DuplicateDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "dup_b"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("dup_orders")
    source_schema("public")
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshReplicant.Test.NoSourceDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.NoSource
  end
end

defmodule AshReplicant.Test.NoSource do
  @moduledoc """
  Ets-backed replicant resource with NO `source_table` and no reflectable
  AshPostgres table: `AshReplicant.Resource.Info.source_table/1` returns `nil`.
  Locks `Resolver.build_index/1`'s MANDATE-1 nil-source-table fail-closed guard.
  """
  use Ash.Resource,
    domain: AshReplicant.Test.NoSourceDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshReplicant.Resource]

  replicant do
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end
