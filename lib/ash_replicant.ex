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

  @doc """
  Start a CDC pipeline that mirrors into Ash resources. `opts`:

    * `:sink` — a module built with `use AshReplicant.Sink` (carries repo/domains/checkpoint/slot).
    * `:connection` — Postgrex opts (point at a standby).
    * `:publication` — replication identifier.
    * `:go_forward_only`, `:snapshot` — passed through to `Replicant.start_link/1`.

  The `slot_name` is NOT a `start_link` option — it is baked into the sink via
  `use AshReplicant.Sink, slot_name: ...` and is the single source of truth for
  both the `:persistent_term` index key and the replication slot.

  Builds the `{schema,table}=>resource` index from the sink's domains, **fails
  closed** on a duplicate or missing source table, caches the index in
  `:persistent_term`, then starts the `replicant` pipeline.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    sink = Keyword.fetch!(opts, :sink)
    connection = Keyword.fetch!(opts, :connection)
    publication = Keyword.fetch!(opts, :publication)
    %{domains: domains, slot_name: slot_name} = sink.__ash_replicant_config__()

    with {:ok, index} <- AshReplicant.Resolver.build_index(domains) do
      :persistent_term.put({AshReplicant, slot_name}, index)

      Replicant.start_link(
        connection: connection,
        slot_name: slot_name,
        publication: publication,
        sink: sink,
        go_forward_only: Keyword.get(opts, :go_forward_only, false),
        snapshot: Keyword.get(opts, :snapshot, false)
      )
    end
  end
end
