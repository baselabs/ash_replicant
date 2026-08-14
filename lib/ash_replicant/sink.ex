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

  @final_callbacks [
    handle_session_identity: 2,
    checkpoint: 0,
    handle_transaction: 1,
    sink_kind: 0,
    handle_schema_change: 2,
    handle_snapshot: 2,
    handle_snapshot_complete: 1
  ]

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) when kind in [:def, :defp] do
    arity = length(args || [])

    if {name, arity} in @final_callbacks do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "AshReplicant sink callback #{name}/#{arity} is final"
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domains = Keyword.fetch!(opts, :domains)
    checkpoint_resource = Keyword.fetch!(opts, :checkpoint_resource)
    slot_name = Keyword.fetch!(opts, :slot_name)
    # Optional test-only append-only ledger table (dup=0 proof, Task 15). Defaults
    # to nil so production sinks that omit it make `Impl.maybe_append_ledger` no-op.
    apply_ledger = Keyword.get(opts, :apply_ledger)

    quote do
      @behaviour Replicant.Sink
      @after_compile {AshReplicant.Destination, :__after_compile__}

      @doc false
      def __ash_replicant_config__ do
        %{
          repo: unquote(repo),
          domains: unquote(domains),
          checkpoint_resource: unquote(checkpoint_resource),
          slot_name: unquote(slot_name),
          apply_ledger: unquote(apply_ledger)
        }
      end

      @impl Replicant.Sink
      def handle_session_identity(identity, context) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :read, fn config ->
          __ash_replicant_effect__(:session_identity, [identity, context], config)
        end)
      end

      @impl Replicant.Sink
      def checkpoint do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :read, fn config ->
          __ash_replicant_effect__(:checkpoint, [], config)
        end)
      end

      @impl Replicant.Sink
      def handle_transaction(txn) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          __ash_replicant_effect__(:transaction, [txn], config)
        end)
      end

      @impl Replicant.Sink
      def sink_kind, do: :state_mirror

      @impl Replicant.Sink
      def handle_schema_change(sc, ctx) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :read, fn config ->
          __ash_replicant_effect__(:schema_change, [sc, ctx], config)
        end)
      end

      @impl Replicant.Sink
      def handle_snapshot(changes, ctx) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          __ash_replicant_effect__(:snapshot, [changes, ctx], config)
        end)
      end

      @impl Replicant.Sink
      def handle_snapshot_complete(lsn) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          __ash_replicant_effect__(:snapshot_complete, [lsn], config)
        end)
      end

      defp __ash_replicant_effect__(:session_identity, [identity, context], config),
        do: Impl.handle_session_identity(config, identity, context)

      defp __ash_replicant_effect__(:checkpoint, [], config),
        do: Impl.checkpoint(config)

      defp __ash_replicant_effect__(:transaction, [transaction], config),
        do: Impl.handle_transaction(config, transaction)

      defp __ash_replicant_effect__(:schema_change, [schema_change, context], config),
        do: Impl.handle_schema_change(config, schema_change, context)

      defp __ash_replicant_effect__(:snapshot, [changes, context], config),
        do: Impl.handle_snapshot(config, changes, context)

      defp __ash_replicant_effect__(:snapshot_complete, [lsn], config),
        do: Impl.handle_snapshot_complete(config, lsn)

      defoverridable __ash_replicant_effect__: 3

      @on_definition {AshReplicant.Sink, :__on_definition__}
    end
  end
end
