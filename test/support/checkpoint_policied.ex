defmodule AshReplicant.Test.CheckpointPolicied do
  @moduledoc """
  A checkpoint that opts into the policy authorizer and locks reads/writes to a
  `system: true` actor. Proves the `authorizers:` opt makes the generated resource
  policy-capable AND that the sink's `authorize?: false` path bypasses those policies
  (effect-once is unaffected).

  Shares the `ash_replicant_checkpoints` table with `AshReplicant.Test.Checkpoint` — two
  resources over one table is fine; this one just carries an authorizer the other does
  not, which is the whole point of the comparison.
  """
  use AshReplicant.Checkpoint,
    repo: AshReplicant.TestRepo,
    domain: AshReplicant.Test.Domain,
    authorizers: [Ash.Policy.Authorizer]

  policies do
    default_access_type :strict

    # Reads are visible only to a system actor; every other actor (and nil) is filtered
    # out. The sink never reaches here — it reads with `authorize?: false`.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:system, true)
    end

    # A non-sink create is denied outright (a filter check resolves to :unknown on a
    # create → forbid under :strict). The sink's upsert runs with `authorize?: false`,
    # so this never gates the effect-once path.
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:system, true)
    end
  end
end
