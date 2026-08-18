defmodule AshReplicant.DestinationParticipant do
  @moduledoc """
  Declares database participants reached by custom Ash action code and callbacks.

  AshReplicant can inspect framework-owned action metadata, but it cannot infer the
  body of an arbitrary custom change, validation, preparation, manual action, query/error
  callback, input type, or tenant resolver.
  Implement this behaviour on such a module to declare either that it performs no
  database work or the exact Ash actions it can invoke. Declarations are admission
  metadata; they do not authorize raw SQL, another Repo, asynchronous work, or an
  external effect.
  """

  defmodule Context do
    @moduledoc "The selected parent action and declaration kind being inspected."
    @enforce_keys [:resource, :action, :kind]
    defstruct [:resource, :action, :kind, message_route?: false]

    @type kind ::
            :change
            | :validation
            | :preparation
            | :manual
            | :callback
            | :type
            | :tenant_resolver
            | :notifier
    @type t :: %__MODULE__{
            resource: module(),
            action: atom(),
            kind: kind(),
            message_route?: boolean()
          }
  end

  defmodule ReplayIdentity do
    @moduledoc "A closed operation identity for a replay-compatible auxiliary action."
    @enforce_keys [:components, :participant]
    defstruct [:components, :participant]

    @type component ::
            :source_system_identifier
            | :source_database
            | :slot_name
            | :commit_lsn
            | :ordinal
            | :participant
    @type t :: %__MODULE__{components: [component()], participant: atom()}
  end

  defmodule ActionRef do
    @moduledoc "One literal Ash resource/action participant."
    @enforce_keys [:resource, :action]
    defstruct [:resource, :action, tenant_mode: :inherit, replay_identity: nil]

    @type t :: %__MODULE__{
            resource: module(),
            action: atom(),
            tenant_mode: :inherit,
            replay_identity: ReplayIdentity.t() | nil
          }
  end

  @typedoc "Closed structural admission failures; values from a row never enter them."
  @type reason ::
          :invalid_declaration
          | :external_effect
          | :raw_database_effect
          | :asynchronous_effect

  @callback destination_participants(keyword(), Context.t()) ::
              {:ok, :no_database | {:actions, nonempty_list(ActionRef.t())}}
              | {:error, reason()}

  @operation_components [
    :source_system_identifier,
    :source_database,
    :slot_name,
    :commit_lsn,
    :ordinal,
    :participant,
    :invocation
  ]

  @invocation_labels AshReplicant.Apply.Context.invocation_labels()

  @doc """
  The canonical operation-identity component list — the ONE home consumed by
  BOTH `operation_key/2` (minting) and the manifest's declaration check
  (`valid_replay_identity?/1`, which requires the DECLARED axes to equal this
  list minus the sink-minted `:invocation`). A per-invocation discriminator
  closes the intra-change operation-key collision: one ordinal fans to up to
  three effects (SCD2 close-prior + close-current + open), and without it the
  second close replays the first's stored AshOnetime response — the declared
  effect silently never runs.
  """
  @spec operation_components() :: [atom()]
  def operation_components, do: @operation_components

  @doc """
  The closed per-invocation mint set (one label per sink call site). Shared
  with `AshReplicant.Apply.Context` — the labels live there, beside the mint
  sites they name.
  """
  @spec invocation_labels() :: [atom()]
  def invocation_labels, do: @invocation_labels

  @doc """
  Builds the closed AshOnetime operation key for one admitted auxiliary participant.

  `context` is the private `:ash_replicant_operation` action context supplied by the sink.
  Missing, extra, nil, or incorrectly typed identity components fail closed.
  """
  @spec operation_key(map(), atom()) :: {:ok, binary()} | {:error, :invalid_declaration}
  def operation_key(%Ash.Changeset{} = changeset, participant)
      when is_atom(participant) and participant not in [nil, true, false] do
    with operation when is_map(operation) <-
           Map.get(changeset.context, :ash_replicant_operation),
         {:ok, operation} <- materialize_bulk_ordinal(operation, changeset) do
      operation_key(operation, participant)
    else
      _other -> {:error, :invalid_declaration}
    end
  end

  def operation_key(context, participant)
      when is_map(context) and is_atom(participant) and participant not in [nil, true, false] do
    identity = Map.put(context, :participant, participant)

    with true <- Map.keys(identity) |> Enum.sort() == Enum.sort(@operation_components),
         source_system_identifier when is_binary(source_system_identifier) <-
           identity.source_system_identifier,
         source_database when is_binary(source_database) <- identity.source_database,
         slot_name when is_binary(slot_name) <- identity.slot_name,
         commit_lsn when is_integer(commit_lsn) and commit_lsn >= 0 <- identity.commit_lsn,
         ordinal when is_integer(ordinal) and ordinal >= 0 <- identity.ordinal,
         invocation when invocation in @invocation_labels <- identity.invocation,
         {:ok, encoded} <-
           AshOnetime.Canonical.encode([
             source_system_identifier,
             source_database,
             slot_name,
             commit_lsn,
             ordinal,
             participant,
             invocation
           ]) do
      {:ok, Base.url_encode64(encoded, padding: false)}
    else
      _other -> {:error, :invalid_declaration}
    end
  end

  def operation_key(_context, _participant), do: {:error, :invalid_declaration}

  defp materialize_bulk_ordinal(%{ordinal: ordinal} = operation, _changeset)
       when is_integer(ordinal),
       do: {:ok, operation}

  defp materialize_bulk_ordinal(%{ordinal_base: base} = operation, changeset)
       when is_integer(base) and base >= 0 do
    case get_in(changeset.context, [:bulk_create, :index]) do
      index when is_integer(index) and index >= 0 ->
        {:ok, operation |> Map.delete(:ordinal_base) |> Map.put(:ordinal, base + index)}

      _other ->
        {:error, :invalid_declaration}
    end
  end

  defp materialize_bulk_ordinal(_operation, _changeset), do: {:error, :invalid_declaration}
end
