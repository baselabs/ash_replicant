defmodule AshReplicant.Notifier do
  @moduledoc """
  The verified wrapper an Ash notifier must use to carry a dependency pre-load
  into a mirrored write.

  Ash runs a notifier's dependency pre-load read after every successful
  create/destroy, with no notify gate — the sink suppresses notification
  DISPATCH, not the pre-load. A notifier whose load statement is non-empty
  therefore executes host reads *inside* the sink's delivery transaction, so
  those reads must be in the admitted destination graph
  (ADR-0006 destination transaction boundary, ADR-0010 host action contract).

  Declaring `AshReplicant.DestinationParticipant` alone cannot carry that: Ash
  re-derives the statement by calling `load/2` again at delivery, so an
  admission-time probe binds nothing. A `load/2` that reads application config,
  process state, an ETS table, or the clock can be empty when the manifest is
  built and non-empty when the sink delivers.

  This module closes that. `use AshReplicant.Notifier` defines `load/2` for
  you; you implement `c:preload/2` instead. Inside a sink delivery the
  generated `load/2` compares your statement — and your participant
  declaration's action closure — against what the live generation admitted,
  and only then hands that exact statement to Ash. Drift halts before the
  dependency query runs, value-free.

  ## Using it

      defmodule MyApp.OrderNotifier do
        use Ash.Notifier
        use AshReplicant.Notifier

        @behaviour AshReplicant.DestinationParticipant

        alias AshReplicant.DestinationParticipant.{ActionRef, Context}

        @impl Ash.Notifier
        def notify(_notification), do: :ok

        # Replaces `load/2`. Return anything `Ash.Query.load/2` accepts.
        @impl AshReplicant.Notifier
        def preload(_resource, _action), do: [:total]

        @impl AshReplicant.DestinationParticipant
        def destination_participants(_opts, %Context{resource: resource, action: action})
            when action != :read do
          {:ok, {:actions, [%ActionRef{resource: resource, action: :read}]}}
        end

        def destination_participants(_opts, _context), do: {:ok, :no_database}
      end

  `use Ash.Notifier` must come first — the generated `load/2` is annotated
  against the `Ash.Notifier` behaviour.

  ## What is required, and when

  Only a notifier attached to a resource AshReplicant mirrors, and only when
  its statement is non-empty:

  - a non-empty statement on an **unwrapped** notifier fails admission with
    `{:destination_notifier_unwrapped, resource, action, notifier}`
  - a non-empty statement on a notifier that declares no
    `AshReplicant.DestinationParticipant` fails with
    `{:destination_notifier_required, resource, action, notifier}`
  - a statement that will not reproduce itself between two consecutive calls
    fails with `{:destination_notifier_unstable, resource, action, notifier}`

  A notifier with no `load/2`/`c:preload/2`, or one whose statement is empty,
  needs nothing and behaves exactly as before. So does a wrapped notifier
  firing on a write the host makes itself: outside a sink delivery the
  generated `load/2` simply returns your statement.

  ## What it does not do

  Wrapping does not authorize notification dispatch. The sink still suppresses
  `notify/1` for mirrored changes; only the dependency pre-load runs.
  """

  alias AshReplicant.Apply.Context, as: DeliveryContext
  alias AshReplicant.Destination.NotifierLoads
  alias AshReplicant.Error

  @doc """
  The load statement this notifier depends on — everything `Ash.Query.load/2`
  accepts. Replaces `c:Ash.Notifier.load/2`, which the wrapper owns.
  """
  @callback preload(Ash.Resource.t(), Ash.Resource.Actions.action()) ::
              atom() | [atom()] | Keyword.t()

  defmacro __using__(_opts) do
    quote do
      # `Ash.Notifier` is NOT re-declared here: `use Ash.Notifier` already did,
      # and a second declaration warns on its optional callbacks. That is why
      # `use Ash.Notifier` has to come first.
      @behaviour AshReplicant.Notifier

      @impl Ash.Notifier
      def load(resource, action),
        do: AshReplicant.Notifier.verified_load(__MODULE__, resource, action)
    end
  end

  @doc "True when `notifier` routes its load statement through this wrapper."
  @spec wrapped?(module()) :: boolean()
  def wrapped?(notifier) when is_atom(notifier) do
    # `module_info(:attributes)` repeats the `behaviour` KEY once per
    # declaration, so `Keyword.get/2` would see only the first one — a module
    # that declares `Ash.Notifier` before this one would read as unwrapped.
    Code.ensure_loaded?(notifier) and
      notifier.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
      |> Enum.member?(__MODULE__)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @doc false
  @spec verified_load(module(), module(), map()) :: term()
  def verified_load(notifier, resource, action) do
    statement = List.wrap(notifier.preload(resource, action))

    case DeliveryContext.admitted_manifest() do
      # Not a sink delivery (the host's own write, or a bare unit config with
      # no manifest): the ordinary Ash contract, unverified — the sink is not
      # the one running this transaction.
      nil ->
        statement

      manifest ->
        case NotifierLoads.verify_statement(manifest, notifier, resource, action, statement) do
          :ok ->
            statement

          {:error, reason} ->
            # Raised INSIDE Ash's load derivation, so it lands before the
            # dependency query is built. The sink's boundary scrubs it.
            raise Error.exception(reason: reason, resource: resource, op: :notifier_load)
        end
    end
  end
end
