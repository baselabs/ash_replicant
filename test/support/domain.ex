defmodule AshReplicant.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.Checkpoint
    resource AshReplicant.Test.Order
    resource AshReplicant.Test.Account
    resource AshReplicant.Test.TenantOrder
    resource AshReplicant.Test.Secret
  end
end
