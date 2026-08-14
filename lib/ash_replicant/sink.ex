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
    unless Process.get({__MODULE__, :expanding}, false) do
      arity = length(args || [])

      if {name, arity} in @final_callbacks do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "AshReplicant sink callback #{name}/#{arity} is final"
      end
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domains = Keyword.fetch!(opts, :domains)
    checkpoint_resource = Keyword.fetch!(opts, :checkpoint_resource)
    slot_name = Keyword.fetch!(opts, :slot_name)

    # Fail closed on removed or unknown options: a previously-valid key (e.g. the
    # removed `apply_ledger`) must surface as a compile-time failure on the host,
    # never silently no-op with its effect gone.
    case Keyword.drop(opts, [:repo, :domains, :checkpoint_resource, :slot_name]) do
      [] ->
        :ok

      extra ->
        raise ArgumentError,
              "unknown AshReplicant.Sink option(s) #{inspect(Keyword.keys(extra))} — " <>
                "the sink admits only :repo, :domains, :checkpoint_resource, :slot_name " <>
                "(apply_ledger was removed; a removed option must not silently no-op)"
    end

    quote do
      # A host def placed BEFORE `use` never fires @on_definition at all — scan
      # the module's already-registered definitions at use time (an
      # earlier-defined clause would win dispatch and skip the generation guard,
      # activation lock, and dynamic-repo pin).
      for {name, arity} <-
            Module.definitions_in(__MODULE__, :def) ++
              Module.definitions_in(__MODULE__, :defp),
          {name, arity} in unquote(Enum.to_list(@final_callbacks)) do
        raise CompileError,
          file: __ENV__.file,
          line: __ENV__.line,
          description: "AshReplicant sink callback #{name}/#{arity} is final"
      end

      # Registered before the macro's own injected definitions: @on_definition
      # fires only for definitions made AFTER the attribute is set, so any LATER
      # host def hits the guard. The expanding flag exempts the injected defs.
      @on_definition {AshReplicant.Sink, :__on_definition__}
      Process.put({AshReplicant.Sink, :expanding}, true)

      @behaviour Replicant.Sink
      @after_compile {AshReplicant.Destination, :__after_compile__}

      @doc false
      def __ash_replicant_config__ do
        %{
          repo: unquote(repo),
          domains: unquote(domains),
          checkpoint_resource: unquote(checkpoint_resource),
          slot_name: unquote(slot_name)
        }
      end

      @impl Replicant.Sink
      def handle_session_identity(identity, context) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          Impl.handle_session_identity(config, identity, context)
        end)
      end

      @impl Replicant.Sink
      def checkpoint do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :read, fn config ->
          Impl.checkpoint(config)
        end)
      end

      @impl Replicant.Sink
      def handle_transaction(txn) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          Impl.handle_transaction(config, txn)
        end)
      end

      @impl Replicant.Sink
      def sink_kind, do: :state_mirror

      @impl Replicant.Sink
      def handle_schema_change(sc, ctx) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :read, fn config ->
          Impl.handle_schema_change(config, sc, ctx)
        end)
      end

      @impl Replicant.Sink
      def handle_snapshot(changes, ctx) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          Impl.handle_snapshot(config, changes, ctx)
        end)
      end

      @impl Replicant.Sink
      def handle_snapshot_complete(lsn) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          Impl.handle_snapshot_complete(config, lsn)
        end)
      end

      Process.put({AshReplicant.Sink, :expanding}, false)
    end
  end
end
