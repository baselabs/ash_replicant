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

  `sink_kind` (ADR-0018) makes the generated sink exclusively `:state_mirror`
  (default — every pre-existing host is unchanged) or `:append_log`. An append
  sink additionally declares `initial_state: :snapshot | :go_forward`, its ONE
  initial-state intent; `:go_forward` is what generates `handle_slot_origin/2`,
  which persists the log's immutable origin floor. A slot CREATED under an
  existing floor is rejected as a gap. Replicant never filtered-WAL
  idle-advances an append sink, so a reused origin above the durable destination
  watermark is also a gap; quiet append publications advance through an ordinary
  published heartbeat transaction. Activation cross-checks the kind against
  every mapped resource and the intent against the `snapshot:` start option.
  """

  alias AshReplicant.Sink.Impl

  @final_callbacks [
    handle_session_identity: 2,
    handle_slot_origin: 2,
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

  # {count, unit} → seconds, bounded by the same ceiling ash_onetime admits
  # for a claim's retention_seconds so a declared horizon is always
  # representable by the retention it must be compared against.
  @horizon_units %{
    second: 1,
    seconds: 1,
    minute: 60,
    minutes: 60,
    hour: 3_600,
    hours: 3_600,
    day: 86_400,
    days: 86_400,
    week: 604_800,
    weeks: 604_800
  }

  @max_horizon_seconds 2_147_483_647

  defp normalize_recovery_horizon!({count, unit})
       when is_integer(count) and count >= 1 and is_atom(unit) do
    case Map.fetch(@horizon_units, unit) do
      {:ok, seconds} ->
        total = count * seconds

        if total <= @max_horizon_seconds do
          total
        else
          raise ArgumentError,
                ":recovery_horizon must be a positive bounded {count, unit} duration " <>
                  "(the declared window exceeds the representable retention ceiling)"
        end

      :error ->
        raise ArgumentError,
              ":recovery_horizon must be a positive bounded {count, unit} duration " <>
                "(unknown unit — use second(s), minute(s), hour(s), day(s), or week(s))"
    end
  end

  defp normalize_recovery_horizon!(_other) do
    raise ArgumentError,
          ":recovery_horizon must be a positive bounded {count, unit} duration " <>
            "(e.g. {24, :hour})"
  end

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domains = Keyword.fetch!(opts, :domains)
    checkpoint_resource = Keyword.fetch!(opts, :checkpoint_resource)
    slot_name = Keyword.fetch!(opts, :slot_name)
    legacy_apply_ledger? = Keyword.has_key?(opts, :apply_ledger)

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
           :ignored_message_prefixes,
           :recovery_horizon,
           :sink_kind,
           :initial_state,
           :apply_ledger
         ]) do
      [] ->
        :ok

      extra ->
        raise ArgumentError,
              "unknown AshReplicant.Sink option(s) #{inspect(Keyword.keys(extra))} — " <>
                "the sink admits only :repo, :domains, :checkpoint_resource, :slot_name, " <>
                ":ignored_sources, :message_routes, :ignored_message_prefixes, " <>
                ":recovery_horizon, :sink_kind, :initial_state, and the compile-only " <>
                "legacy :apply_ledger marker"
    end

    # ADR-0018 §1: a generated sink is EXCLUSIVELY one kind. Replicant reads
    # `sink_kind/0` per sink with no runtime context to consult, so the kind is
    # necessarily a compile-time decision; activation then cross-checks that
    # every mapped resource agrees with it.
    sink_kind = Keyword.get(opts, :sink_kind, :state_mirror)

    unless sink_kind in [:state_mirror, :append_log] do
      raise ArgumentError,
            "AshReplicant.Sink :sink_kind must be :state_mirror (default) or :append_log " <>
              "(got #{inspect(sink_kind)})"
    end

    # ADR-0018 §5: "A fresh append sink declares exactly one initial-state
    # intent: snapshot or go-forward." Declared, not inferred — the choice
    # decides whether the origin floor comes from the slot-origin callback or
    # from the snapshot's consistent point, and a sink that left it implicit
    # would make no honest completeness claim at all.
    initial_state = Keyword.get(opts, :initial_state)

    case {sink_kind, initial_state} do
      {:append_log, state} when state in [:snapshot, :go_forward] ->
        :ok

      {:append_log, other} ->
        raise ArgumentError,
              "AshReplicant.Sink :sink_kind :append_log requires :initial_state to be " <>
                ":snapshot or :go_forward — a fresh append sink declares exactly one " <>
                "initial-state intent, and it is what fixes the log's origin floor " <>
                "(got #{inspect(other)})"

      {:state_mirror, nil} ->
        :ok

      {:state_mirror, other} ->
        raise ArgumentError,
              "AshReplicant.Sink :initial_state (#{inspect(other)}) applies only to " <>
                ":sink_kind :append_log. A state mirror converges to current state and " <>
                "claims no origin floor."
    end

    # Only a GO-FORWARD append sink implements `handle_slot_origin/2`: it is the
    # callback that supplies its floor. Replicant gates the extra connect query
    # on the callback's presence, so a snapshot-intent or mirror sink must not
    # export it (`supports_slot_origin?/1`).
    slot_origin_capable? = sink_kind == :append_log and initial_state == :go_forward

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

    # O03 (ADR-0022): the recovery horizon — the operator's supported
    # outage/replay window, the floor every claim-backed route retention must
    # cover (activation enforces it against the manifest; AshReplicant.Horizon
    # owns the one comparison body). Declared exactly when claim-backed
    # message routes exist: route-less sinks have nothing to protect, and an
    # :append_log sink's routes dedup structurally through the append
    # identity — a stray horizon in either posture is config drift.
    recovery_horizon =
      case Keyword.get(opts, :recovery_horizon) do
        nil ->
          nil

        value ->
          cond do
            message_routes == [] ->
              raise ArgumentError,
                    ":recovery_horizon is declared with no message routes to protect — " <>
                      "remove it or declare message_routes"

            sink_kind == :append_log ->
              raise ArgumentError,
                    ":recovery_horizon does not apply to an :append_log sink — its " <>
                      "message routes dedup through the append identity, not claims"

            true ->
              normalize_recovery_horizon!(value)
          end
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

      # O03 (ADR-0022): claim-backed routes without a declared horizon never
      # compile — the spec's retention-vs-horizon validation cannot be
      # silently absent. Spliced AFTER the finality guard so a host breaking
      # BOTH rules still learns about the callback first.
      unquote(
        if message_routes != [] and sink_kind == :state_mirror and is_nil(recovery_horizon) do
          quote do
            raise ArgumentError,
                  ":recovery_horizon is required when message_routes are declared — " <>
                    "declare a recovery horizon (the supported outage/replay window) " <>
                    "so every route's claim retention can be validated against it"
          end
        end
      )

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
          ignored_message_prefixes: unquote(Macro.escape(ignored_message_prefixes)),
          recovery_horizon: unquote(recovery_horizon),
          sink_kind: unquote(sink_kind),
          initial_state: unquote(initial_state),
          legacy_apply_ledger?: unquote(legacy_apply_ledger?)
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
      def sink_kind, do: unquote(sink_kind)

      if unquote(slot_origin_capable?) do
        @impl Replicant.Sink
        def handle_slot_origin(origin, ctx) do
          AshReplicant.run_callback(unquote(slot_name), __MODULE__, :mutate, fn config ->
            Impl.handle_slot_origin(config, origin, ctx)
          end)
        end
      end

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
