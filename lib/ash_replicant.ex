defmodule AshReplicant do
  @moduledoc """
  An Ash-native `Replicant.Sink` adapter. Mirrors a source Postgres database's
  committed CDC changes into AshPostgres resources with effect-once semantics
  (dup = 0, loss = 0), resolving resource, tenant, and classification in the Ash
  layer while keeping `replicant` tenant-blind.

  This is the `ash_postgres`-of-`replicant`: `replicant` is the tenant-blind CDC
  transport; multitenancy and classification live here, one layer up.
  """

  @version Mix.Project.config()[:version]

  @doc "The library version string."
  @spec version() :: String.t()
  def version, do: @version
end
