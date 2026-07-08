defmodule AshReplicant.Sink do
  @moduledoc """
  Generates a `Replicant.Sink` implementation bound to a host's config.

      defmodule MyApp.ReplicantSink do
        use AshReplicant.Sink,
          repo: MyApp.Repo,
          domains: [MyApp.Shop],
          checkpoint_resource: MyApp.ReplicantCheckpoint,
          slot_name: "shop_orders"
      end

  `Replicant.Sink` callbacks carry no pipeline context, so config is baked into
  the generated module. The resolver index is built by `AshReplicant.start_link/1`
  and read from `:persistent_term`.
  """

  alias AshReplicant.Sink.Impl

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domains = Keyword.fetch!(opts, :domains)
    checkpoint_resource = Keyword.fetch!(opts, :checkpoint_resource)
    slot_name = Keyword.fetch!(opts, :slot_name)

    quote do
      @behaviour Replicant.Sink

      @doc false
      def __ash_replicant_config__ do
        %{
          repo: unquote(repo),
          domains: unquote(domains),
          checkpoint_resource: unquote(checkpoint_resource),
          slot_name: unquote(slot_name)
        }
      end

      defp __config__ do
        base = __ash_replicant_config__()
        index = :persistent_term.get({AshReplicant, unquote(slot_name)}, %{})
        Map.merge(base, %{resolver_index: index, authorize?: false})
      end

      @impl Replicant.Sink
      def checkpoint, do: Impl.checkpoint(__config__())

      @impl Replicant.Sink
      def handle_transaction(txn),
        do: Impl.handle_transaction(__config__(), txn)

      @impl Replicant.Sink
      def sink_kind, do: :state_mirror

      @impl Replicant.Sink
      def handle_schema_change(sc, ctx), do: Impl.handle_schema_change(__config__(), sc, ctx)

      defoverridable checkpoint: 0,
                     handle_transaction: 1,
                     sink_kind: 0,
                     handle_schema_change: 2
    end
  end
end
