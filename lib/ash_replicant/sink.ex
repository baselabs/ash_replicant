defmodule AshReplicant.Sink do
  @moduledoc """
  Generates a `Replicant.Sink` implementation bound to a host's config.

      defmodule MyApp.ReplicantSink do
        use AshReplicant.Sink,
          repo: MyApp.Repo,
          domains: [MyApp.Shop],
          checkpoint_resource: MyApp.ReplicantCheckpoint,
          slot_name: "shop_orders",
          message_routes: [{"mail", MyApp.MailOutbox, :record}],
          ignored_message_prefixes: ["telemetry_noise"]
      end

  `Replicant.Sink` callbacks carry no pipeline context, so config is baked into
  the generated module. The resolver index is built by `AshReplicant.start_link/1`
  and read from `:persistent_term`.

  `message_routes` maps `pg_logical_emit_message` prefixes to host create
  actions (ADR-0015); a sink declaring routes or ignores exposes
  `handle_message/2` and the pipeline starts with `messages: true`. Every
  routed action must carry the closed AshOnetime message profile (validated at
  activation); an unknown prefix at delivery halts fail-closed.

  `handle_batch/1` is generated on EVERY sink (ADR-0016): batch semantics
  need nothing beyond the admitted generation, and the pipeline-level
  `batch_delivery` start option is what opts a pipeline into batched
  delivery.

  `snapshot_progress/0` is also generated on every sink (ADR-0017). An
  incremental pipeline may activate only when every mapped resource declares
  `snapshot_provenance true`; the callback then arms or resumes the exact
  checkpoint-owned attempt before Replicant starts its reader and stream. It
  returns `:backfill_pending` until the first authenticated progress token is
  durable, so a slot-created/pre-reader crash cannot abandon the backfill.
  """

  alias AshReplicant.Sink.Impl

  @final_callbacks [
    handle_session_identity: 2,
    checkpoint: 0,
    handle_transaction: 1,
    handle_batch: 1,
    handle_message: 2,
    sink_kind: 0,
    handle_schema_change: 2,
    handle_snapshot: 2,
    handle_snapshot_complete: 1,
    snapshot_progress: 0
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

  defp ignore_source_shape?(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [schema, table] -> schema != "" and table != "" and !String.contains?(table, ".")
      _other -> false
    end
  end

  defp ignore_source_shape?(_), do: false

  # A logical-message route: a strictly non-empty binary prefix routing to a
  # host create action. The action's protection profile is validated by the
  # destination manifest walk (ADR-0015); here only the route SHAPE is
  # compile-checked.
  defp message_route_shape?({prefix, resource, action})
       when is_binary(prefix) and prefix != "" and is_atom(resource) and is_atom(action),
       do: true

  defp message_route_shape?(_), do: false

  defp message_prefix_shape?(prefix) when is_binary(prefix) and prefix != "", do: true
  defp message_prefix_shape?(_), do: false

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domains = Keyword.fetch!(opts, :domains)
    checkpoint_resource = Keyword.fetch!(opts, :checkpoint_resource)
    slot_name = Keyword.fetch!(opts, :slot_name)

    # Fail closed on removed or unknown options: a previously-valid key (e.g. the
    # removed `apply_ledger`) must surface as a compile-time failure on the host,
    # never silently no-op with its effect gone.
    case Keyword.drop(opts, [
           :repo,
           :domains,
           :checkpoint_resource,
           :slot_name,
           :ignored_sources,
           :message_routes,
           :ignored_message_prefixes
         ]) do
      [] ->
        :ok

      extra ->
        raise ArgumentError,
              "unknown AshReplicant.Sink option(s) #{inspect(Keyword.keys(extra))} — " <>
                "the sink admits only :repo, :domains, :checkpoint_resource, :slot_name, " <>
                ":ignored_sources, :message_routes, :ignored_message_prefixes " <>
                "(apply_ledger was removed; a removed option must not silently no-op)"
    end

    # Compile-time validation of the explicit table ignores: strictly qualified
    # `schema.table` strings; bare names and duplicates are compile errors
    # (roadmap B3: "explicit qualified table/column ignores are compile/start
    # validated"). Existence is start-validated against the live catalog.
    ignored_sources = Keyword.get(opts, :ignored_sources, [])

    unless is_list(ignored_sources) and Enum.all?(ignored_sources, &ignore_source_shape?/1) do
      raise ArgumentError,
            "AshReplicant.Sink :ignored_sources must be a list of strictly qualified " <>
              ~s("schema.table" binary strings) <>
              " (got #{inspect(ignored_sources)})"
    end

    unless length(Enum.uniq(ignored_sources)) == length(ignored_sources) do
      raise ArgumentError, "AshReplicant.Sink :ignored_sources contains duplicates"
    end

    # Compile-time validation of the message routing surface (C1/ADR-0015):
    # strictly-shaped `{prefix, resource, action}` routes with UNIQUE prefixes,
    # never overlapping an explicit ignore, and unique non-empty ignore
    # prefixes. The AST is alias-expanded first (a route names a host module);
    # the routed action's existence and AshOnetime profile validate at
    # activation (the manifest walk); an unknown prefix at DELIVERY halts
    # fail-closed.
    caller = __CALLER__

    expand = fn value ->
      Macro.prewalk(value, fn node -> Macro.expand(node, caller) end)
    end

    message_routes =
      opts
      |> Keyword.get(:message_routes, [])
      |> then(&expand.(&1))
      |> Enum.map(fn
        {:{}, _, args} when length(args) == 3 -> List.to_tuple(args)
        other -> other
      end)

    # `Enum.map/2` guarantees the list shape; the shape check is per-element.
    unless Enum.all?(message_routes, &message_route_shape?/1) do
      raise ArgumentError,
            "AshReplicant.Sink :message_routes must be a list of " <>
              ~s({"prefix", Resource, :action} triples with non-empty binary prefixes) <>
              " (got #{inspect(message_routes)})"
    end

    route_prefixes = Enum.map(message_routes, &elem(&1, 0))

    unless length(Enum.uniq(route_prefixes)) == length(route_prefixes) do
      raise ArgumentError, "AshReplicant.Sink :message_routes contains duplicate prefixes"
    end

    ignored_message_prefixes = Keyword.get(opts, :ignored_message_prefixes, [])

    unless ignored_message_prefixes == [] or
             (is_list(ignored_message_prefixes) and
                Enum.all?(ignored_message_prefixes, &message_prefix_shape?/1)) do
      raise ArgumentError,
            "AshReplicant.Sink :ignored_message_prefixes must be a list of non-empty " <>
              "binary prefixes (got #{inspect(ignored_message_prefixes)})"
    end

    unless length(Enum.uniq(ignored_message_prefixes)) == length(ignored_message_prefixes) do
      raise ArgumentError, "AshReplicant.Sink :ignored_message_prefixes contains duplicates"
    end

    unless Enum.empty?(route_prefixes -- (route_prefixes -- ignored_message_prefixes)) do
      raise ArgumentError,
            "AshReplicant.Sink prefixes cannot be both routed and ignored: " <>
              "#{inspect(route_prefixes -- (route_prefixes -- ignored_message_prefixes))}"
    end

    # Deterministic order for the baked config (the config digest is
    # term_to_binary over it — declaration order must not change identity).
    message_routes = Enum.sort(message_routes)
    ignored_message_prefixes = Enum.sort(ignored_message_prefixes)

    # The message callback exists ONLY when a routing surface is declared:
    # Replicant's start gate then sees supports_messages?/1 true and the
    # adapter passes `messages: true` (an unknown prefix halts, never drops).
    message_capable? = message_routes != [] or ignored_message_prefixes != []

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
          slot_name: unquote(slot_name),
          ignored_sources: unquote(Macro.escape(ignored_sources)),
          message_routes: unquote(Macro.escape(message_routes)),
          ignored_message_prefixes: unquote(Macro.escape(ignored_message_prefixes))
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

      # Generated UNCONDITIONALLY (ADR-0016): unlike handle_message/2 the
      # batch body consumes nothing beyond the admitted generation, and
      # `batch_delivery` stays a pipeline-level start option — so every sink
      # satisfies Replicant's supports_batch?/1 gate for any caller opting in.
      @impl Replicant.Sink
      def handle_batch(transactions) do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          Impl.handle_batch(config, transactions)
        end)
      end

      if unquote(message_capable?) do
        @impl Replicant.Sink
        def handle_message(message, ctx) do
          AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
            Impl.handle_message(config, message, ctx)
          end)
        end
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

      @impl Replicant.Sink
      def snapshot_progress do
        AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
          Impl.snapshot_progress(config)
        end)
      end

      Process.put({AshReplicant.Sink, :expanding}, false)
    end
  end
end
