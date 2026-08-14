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
    defstruct [:resource, :action, :kind]

    @type kind ::
            :change | :validation | :preparation | :manual | :callback | :type | :tenant_resolver
    @type t :: %__MODULE__{resource: module(), action: atom(), kind: kind()}
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
end
