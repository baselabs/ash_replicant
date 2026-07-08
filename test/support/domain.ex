defmodule AshReplicant.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.Checkpoint
  end
end
