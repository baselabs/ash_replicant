defmodule AshReplicant.Destination.NotifierLoads do
  @moduledoc false

  # Binds each notifier's load statement — and its participant declaration's
  # action closure — to the destination manifest at admission, and re-checks
  # both at delivery.
  #
  # Ash re-derives the statement on EVERY action invocation
  # (`Ash.Notifier.notifier_calculation_query/3`) and merges the result into
  # the post-write load query. Admission probes it once. Without a binding, a
  # `load/2` that reads application config, process state, an ETS table, or the
  # clock can be empty when the manifest is built and non-empty when the sink
  # delivers — undeclared reads inside the destination transaction, with
  # nothing red.
  #
  # Two layers consume the binding:
  #
  #   * `AshReplicant.Notifier` — the wrapper Ash itself calls. It compares the
  #     statement it is about to hand Ash, so for a wrapped notifier there is
  #     no probe-to-use window at all.
  #   * `AshReplicant.Apply.Context.verify_notifier_loads!/4` — the sink's own
  #     check, immediately before each admitted action. It covers what the
  #     wrapper structurally cannot: a notifier carrying no wrapper because its
  #     statement was EMPTY at admission and is not any more, a notifier that
  #     appeared in or vanished from the action's notifier list, and a `load/2`
  #     that faults.
  #
  # The fingerprint is closure-aware in the Elixir sense too: every function in
  # a statement is replaced by an explicit descriptor from `:erlang.fun_info/1`,
  # so a fun that captured a different value fingerprints differently even
  # though its code position is identical. `:pid` is excluded ON PURPOSE —
  # `fun_info` reports the process that created the fun, and admission runs in
  # a different process than delivery. No `fun` ever reaches
  # `:erlang.term_to_binary/2`, so the digest never depends on that encoding's
  # rules for funs.
  #
  # `probe/3` derives the binding TWICE and requires the two to agree. A
  # statement that cannot reproduce itself is not a promise about anything, so
  # it fails closed — at admission as an unstable notifier, at delivery as
  # drift.

  alias Ash.Resource.Info, as: AshInfo
  alias AshReplicant.DestinationParticipant.Context

  @fun_descriptor_keys [
    :module,
    :name,
    :arity,
    :type,
    :index,
    :new_index,
    :uniq,
    :new_uniq,
    :env
  ]

  @manifest AshReplicant.Destination.Manifest

  @typedoc "One notifier's admitted statement digest and declared-closure digest."
  @type binding :: {binary(), binary() | nil}

  @typedoc "One admitted action's notifier bindings, by notifier module."
  @type bindings :: %{optional(module()) => binding()}

  @typedoc "Every admitted action's bindings, keyed by `{resource, action}`."
  @type bound :: %{optional({module(), atom()}) => bindings()}

  @doc "The closure-aware digest of one term (a load statement, or a declaration)."
  @spec fingerprint(term()) :: binary()
  def fingerprint(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(canonical(term), [:deterministic]))

  @doc """
  Probe one notifier for `action` on `resource`.

  Returns the wrapped statement and its binding, `:unstable` when two
  consecutive probes disagree, or `:error` when the statement source or the
  participant declaration raised, threw, or exited.
  """
  @spec probe(module(), map(), module()) :: {:ok, list(), binding()} | :unstable | :error
  def probe(resource, action, notifier) do
    statement = statement(notifier, resource, action)
    first = binding_of(notifier, resource, action, statement)
    second = binding_of(notifier, resource, action, statement(notifier, resource, action))

    if first == second, do: {:ok, statement, first}, else: :unstable
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  @doc """
  The bindings `action` on `resource` produces RIGHT NOW — every notifier the
  action carries, including the ones whose statement is empty.
  """
  @spec bindings(module(), atom()) :: {:ok, bindings()} | {:error, :unstable | :probe_failed}
  def bindings(resource, action_name) when is_atom(resource) and is_atom(action_name) do
    case AshInfo.action(resource, action_name) do
      %{} = action -> bindings_for(resource, action)
      _other -> {:error, :probe_failed}
    end
  rescue
    _error -> {:error, :probe_failed}
  catch
    _kind, _reason -> {:error, :probe_failed}
  end

  @doc """
  The admission-time bindings for one already-reflected action. Shared with the
  manifest walk so the fingerprint comes from the SAME probe the walk validates
  with — a second probe would itself be a statefulness window.
  """
  @spec bindings_for(module(), map()) :: {:ok, bindings()} | {:error, :unstable | :probe_failed}
  def bindings_for(resource, action) do
    resource
    |> notifiers(action)
    |> Enum.reduce_while({:ok, %{}}, fn notifier, {:ok, acc} ->
      case probe(resource, action, notifier) do
        {:ok, _statement, binding} -> {:cont, {:ok, Map.put(acc, notifier, binding)}}
        :unstable -> {:halt, {:error, :unstable}}
        :error -> {:halt, {:error, :probe_failed}}
      end
    end)
  end

  @doc """
  The notifier list Ash itself will use for this action — the resource's own
  notifiers plus the action's.
  """
  @spec notifiers(module(), map()) :: [module()]
  def notifiers(resource, action),
    do: AshInfo.notifiers(resource) ++ List.wrap(Map.get(action, :notifiers))

  @doc "The load statement Ash would derive from this notifier right now."
  # Mirrors Ash's own gate exactly (`Ash.Notifier.notifier_calculation_query/3`):
  # `load/2` is optional, and a notifier that does not implement it imposes
  # nothing. `function_exported?/3` does not load the module, so the
  # `Code.ensure_loaded?/1` is what makes the check honest.
  @spec statement(module(), module(), map()) :: list()
  def statement(notifier, resource, action) do
    if Code.ensure_loaded?(notifier) and function_exported?(notifier, :load, 2) do
      List.wrap(Ash.Notifier.load(notifier, resource, action))
    else
      []
    end
  end

  @doc """
  Compare what `action` produces now against the manifest bindings.

  Accepts the manifest or the bare binding map. Every failure is structural and
  value-free; the caller raises it as an `AshReplicant.Error` reason.
  """
  @spec verify(map(), module(), atom()) :: :ok | {:error, {:invalid_destination_config, atom()}}
  # Matched through `__struct__` rather than `%Manifest{}` so this module keeps
  # a runtime — not compile-time — dependency on the module that owns the walk.
  def verify(%{__struct__: @manifest, notifier_loads: bound}, resource, action),
    do: verify(bound, resource, action)

  def verify(bound, resource, action) when is_map(bound) do
    case Map.fetch(bound, {resource, action}) do
      {:ok, admitted} -> compare(admitted, resource, action)
      :error -> {:error, {:invalid_destination_config, :notifier_load_unadmitted}}
    end
  end

  @doc """
  The wrapper's in-band check: the statement it is ABOUT to hand Ash, against
  the binding the live generation admitted for this exact notifier.
  """
  @spec verify_statement(map(), module(), module(), map(), list()) ::
          :ok | {:error, {:invalid_destination_config, atom()}}
  def verify_statement(
        %{__struct__: @manifest, notifier_loads: bound},
        notifier,
        resource,
        action,
        statement
      ),
      do: verify_statement(bound, notifier, resource, action, statement)

  def verify_statement(bound, notifier, resource, action, statement) when is_map(bound) do
    with {:ok, admitted} <- fetch_binding(bound, resource, action, notifier),
         {:ok, current} <- current_binding(notifier, resource, action, statement) do
      if current == admitted,
        do: :ok,
        else: {:error, {:invalid_destination_config, :notifier_load_drift}}
    end
  end

  defp fetch_binding(bound, resource, action, notifier) do
    with {:ok, action_bindings} <- Map.fetch(bound, {resource, action_name(action)}),
         {:ok, admitted} <- Map.fetch(action_bindings, notifier) do
      {:ok, admitted}
    else
      :error -> {:error, {:invalid_destination_config, :notifier_load_unadmitted}}
    end
  end

  defp current_binding(notifier, resource, action, statement) do
    {:ok, binding_of(notifier, resource, action, statement)}
  rescue
    _error -> {:error, {:invalid_destination_config, :notifier_load_probe_failed}}
  catch
    _kind, _reason -> {:error, {:invalid_destination_config, :notifier_load_probe_failed}}
  end

  defp action_name(action) when is_atom(action), do: action
  defp action_name(%{name: name}), do: name

  defp compare(admitted, resource, action) do
    case bindings(resource, action) do
      {:ok, ^admitted} ->
        :ok

      {:ok, _drifted} ->
        {:error, {:invalid_destination_config, :notifier_load_drift}}

      # A statement that will not reproduce itself between two consecutive
      # probes cannot BE the admitted one, whatever it returns next.
      {:error, :unstable} ->
        {:error, {:invalid_destination_config, :notifier_load_drift}}

      {:error, :probe_failed} ->
        {:error, {:invalid_destination_config, :notifier_load_probe_failed}}
    end
  end

  # The binding is the pair the ADR-0010 amendment names: the statement's
  # digest, and the DECLARED ACTION CLOSURE's — the exact participant
  # declaration this notifier returns for this (resource, action) context. A
  # declaration that widens at delivery would otherwise pull in reads the
  # manifest walk never admitted.
  defp binding_of(notifier, resource, action, statement),
    do: {fingerprint(statement), closure_fingerprint(notifier, resource, action)}

  defp closure_fingerprint(notifier, resource, action) do
    if Code.ensure_loaded?(notifier) and
         function_exported?(notifier, :destination_participants, 2) do
      fingerprint(
        notifier.destination_participants([], %Context{
          resource: resource,
          action: action_name(action),
          kind: :notifier
        })
      )
    end
  end

  defp canonical(term) when is_function(term) do
    info = :erlang.fun_info(term)
    {:ash_replicant_closure, Enum.map(@fun_descriptor_keys, &canonical(Keyword.get(info, &1)))}
  end

  defp canonical(term) when is_list(term), do: Enum.map(term, &canonical/1)

  defp canonical(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&canonical/1) |> List.to_tuple()

  # `:maps.to_list/1` — NOT `Map.new/2` — because a STRUCT is a map that does
  # not implement Enumerable, and both load statements
  # (`%Ash.Query.Calculation{}`) and participant declarations (`%ActionRef{}`)
  # carry structs.
  defp canonical(term) when is_map(term) do
    term
    |> :maps.to_list()
    |> Enum.map(fn {key, value} -> {canonical(key), canonical(value)} end)
    |> :maps.from_list()
  end

  defp canonical(term), do: term
end
