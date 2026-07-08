defmodule AshReplicant.Test.Checkpoint do
  @moduledoc false
  use AshReplicant.Checkpoint,
    repo: AshReplicant.TestRepo,
    domain: AshReplicant.Test.Domain
end
