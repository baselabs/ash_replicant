defmodule AshReplicant.Test.Checkpoint do
  @moduledoc false
  use AshReplicant.Checkpoint,
    repo: AshReplicant.TestRepo,
    domain: AshReplicant.Test.Domain
end

defmodule AshReplicant.Test.CheckpointUnguarded do
  @moduledoc """
  The explicit `authorizers: []` opt-out: the pre-B7 unguarded shape, for
  hosts that already front the checkpoint with their own authorization.
  """
  @moduledoc false
  use AshReplicant.Checkpoint,
    repo: AshReplicant.TestRepo,
    domain: AshReplicant.Test.Domain,
    authorizers: []
end
