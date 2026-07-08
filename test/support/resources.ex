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
