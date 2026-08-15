defmodule AshReplicant.Test.DestinationFixtures do
  @moduledoc false

  alias AshReplicant.DestinationParticipant.{ActionRef, Context, ReplayIdentity}

  defmodule NoDatabaseChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: {:ok, :no_database}
  end

  defmodule AuxiliaryChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(opts, %Context{}) do
      action = Keyword.get(opts, :auxiliary_action, :record)

      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.Auxiliary,
            action: action,
            replay_identity: %ReplayIdentity{
              participant: :destination_auxiliary,
              components: [
                :source_system_identifier,
                :source_database,
                :slot_name,
                :commit_lsn,
                :ordinal,
                :participant
              ]
            }
          }
        ]}}
    end
  end

  defmodule RaisingChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: raise("row-value sentinel")
  end

  defmodule InvalidChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: {:error, :invalid_declaration}
  end

  defmodule MalformedChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    # Deliberately violates the behaviour's nonempty_list success type: the
    # runtime must still reject an empty declaration even though typespecs are
    # not enforced at runtime. Narrow nowarn for exactly this fixture purpose.
    @dialyzer {:nowarn_function, destination_participants: 2}

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: {:ok, {:actions, []}}
  end

  defmodule OpaqueValidation do
    @moduledoc false
    use Ash.Resource.Validation

    @impl Ash.Resource.Validation
    def supports(_opts), do: [Ash.Changeset]

    @impl Ash.Resource.Validation
    def validate(_changeset, _opts, _context), do: :ok
  end

  defmodule MissingActionChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.Auxiliary,
            action: :missing
          }
        ]}}
    end
  end

  defmodule ForeignAuxiliaryChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.ForeignAuxiliary,
            action: :record
          }
        ]}}
    end
  end

  defmodule SimpleAuxiliaryChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.SimpleAuxiliary,
            action: :record
          }
        ]}}
    end
  end

  defmodule CycleAChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.CycleB,
            action: :record
          }
        ]}}
    end
  end

  defmodule CycleBChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.CycleA,
            action: :create
          }
        ]}}
    end
  end

  defmodule OpaqueAction do
    @moduledoc false
    use Ash.Resource.Actions.Implementation

    @impl Ash.Resource.Actions.Implementation
    def run(_input, _opts, _context), do: :ok
  end

  defmodule OpaqueType do
    @moduledoc false
    use Ash.Type.NewType, subtype_of: :string
  end

  defmodule OpaqueTenantResolver do
    @moduledoc false
    def resolve(record), do: Map.get(record, "tenant")
  end

  defmodule ProofVerifier do
    @moduledoc false
    @behaviour AshOnetime.Verifier
    @behaviour AshReplicant.DestinationParticipant

    @impl AshOnetime.Verifier
    def verify(_raw_token, _context), do: {:error, :invalid}

    @impl AshOnetime.Verifier
    def algorithm, do: :hmac_sha256

    @impl AshOnetime.Verifier
    def trust_model, do: :same_service

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: {:ok, :no_database}
  end

  defmodule StoreResponse do
    @moduledoc false
    @behaviour AshOnetime.ResponseClassifier
    @behaviour AshReplicant.DestinationParticipant

    @impl AshOnetime.ResponseClassifier
    def classify(result, _context), do: {:store, result}

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: {:ok, :no_database}
  end

  defmodule OpaqueProofVerifier do
    @moduledoc false
    @behaviour AshOnetime.Verifier

    @impl AshOnetime.Verifier
    def verify(_raw_token, _context), do: {:error, :invalid}

    @impl AshOnetime.Verifier
    def algorithm, do: :hmac_sha256

    @impl AshOnetime.Verifier
    def trust_model, do: :same_service
  end

  defmodule OpaqueCache do
    @moduledoc false
    @behaviour AshOnetime.Cache

    @impl AshOnetime.Cache
    def get(_key), do: :miss

    @impl AshOnetime.Cache
    def put(_key, _entry, _ttl), do: :ok

    @impl AshOnetime.Cache
    def delete(_key), do: :ok
  end

  defmodule OpaquePreparation do
    @moduledoc false
    use Ash.Resource.Preparation

    @impl Ash.Resource.Preparation
    def prepare(query, _opts, _context), do: query
  end

  defmodule UnknownWrapper do
    @moduledoc false
    use Ash.Resource.Change

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset
  end

  defmodule NamedDefaultProvider do
    @moduledoc false
    @behaviour AshReplicant.DestinationParticipant

    def default_value, do: "named-default"

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: {:ok, :no_database}
  end

  defmodule OnetimeAuxiliaryChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.OnetimeAuxiliary,
            action: :record,
            replay_identity: %ReplayIdentity{
              participant: :onetime_auxiliary,
              components: [
                :source_system_identifier,
                :source_database,
                :slot_name,
                :commit_lsn,
                :ordinal,
                :participant
              ]
            }
          }
        ]}}
    end
  end

  defmodule ContextTenantResolver do
    @moduledoc false
    @behaviour AshReplicant.DestinationParticipant

    def resolve(record), do: Map.get(record, "tenant")

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: {:ok, :no_database}
  end

  defmodule ContextOnetimeAuxiliaryChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.ContextOnetimeAuxiliary,
            action: :record,
            replay_identity: %ReplayIdentity{
              participant: :context_onetime_auxiliary,
              components: [
                :source_system_identifier,
                :source_database,
                :slot_name,
                :commit_lsn,
                :ordinal,
                :participant
              ]
            }
          }
        ]}}
    end
  end

  defmodule UnknownChange do
    @moduledoc false
    use Ash.Resource.Change

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset
  end

  defmodule CallableRepo do
    @moduledoc false
    @probe {__MODULE__, :invoked}

    def probe_key, do: @probe

    def resolve(_resource, _type) do
      :persistent_term.put(@probe, true)
      AshReplicant.TestRepo
    end
  end

  defmodule SplitRepo do
    @moduledoc false

    def resolve(_resource, :read), do: AshReplicant.TestRepo
    def resolve(_resource, :mutate), do: AshReplicant.Test.DestinationFixtures.ForeignRepo
  end

  defmodule ForeignRepo do
    @moduledoc false
    use AshPostgres.Repo, otp_app: :ash_replicant

    @impl AshPostgres.Repo
    def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

    @impl AshPostgres.Repo
    def installed_extensions, do: ["ash-functions"]
  end

  defmodule PlainRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :ash_replicant, adapter: Ecto.Adapters.Postgres
  end

  defmodule Auxiliary do
    @moduledoc false
    use Ash.Resource,
      otp_app: :ash_replicant,
      domain: AshReplicant.Test.DestinationFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "destination_auxiliary"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        accept []
      end

      action :opaque do
        run AshReplicant.Test.DestinationFixtures.OpaqueAction
      end
    end
  end

  defmodule ForeignAuxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ForeignAuxiliaryDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "destination_foreign_auxiliaries"
      repo AshReplicant.Test.DestinationFixtures.ForeignRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
      create :record, accept: []
    end
  end

  defmodule OnetimeAuxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.OnetimeDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "destination_onetime_auxiliaries"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        argument :operation_key, :string, allow_nil?: false, public?: false
        accept []
      end
    end

    onetime do
      protect :record do
        strategy :idempotency

        scope([
          {:static, "ash_replicant:destination-participant:1"},
          {:static, "onetime_auxiliary"}
        ])

        key({:argument, :operation_key})
        fingerprint(arguments: [:operation_key])

        response(AshOnetime.Codec.Resource,
          fields: [:id],
          classify: AshReplicant.Test.DestinationFixtures.StoreResponse
        )

        retention({1, :day})
      end
    end
  end

  defmodule ContextOnetimeAuxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ContextOnetimeDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "destination_context_onetime_auxiliaries"
      repo AshReplicant.TestRepo
    end

    multitenancy do
      strategy :context
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        argument :operation_key, :string, allow_nil?: false, public?: false
        accept []
      end
    end

    onetime do
      protect :record do
        strategy :idempotency

        scope([
          {:static, "ash_replicant:destination-participant:1"},
          {:static, "context_onetime_auxiliary"}
        ])

        key({:argument, :operation_key})
        fingerprint(arguments: [:operation_key])

        response(AshOnetime.Codec.Resource,
          fields: [:id],
          classify: AshReplicant.Test.DestinationFixtures.StoreResponse
        )

        retention({1, :day})
      end
    end
  end

  defmodule Root do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.Auxiliary]
        change AshReplicant.Test.DestinationFixtures.NoDatabaseChange
        change AshReplicant.Test.DestinationFixtures.AuxiliaryChange
      end
    end
  end

  defmodule UnknownRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.UnknownDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_unknown_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_unknown_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change AshReplicant.Test.DestinationFixtures.UnknownChange
      end
    end
  end

  defmodule BadTouchesRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.BadTouchesDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_bad_touches_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_bad_touches_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change AshReplicant.Test.DestinationFixtures.AuxiliaryChange
      end
    end
  end

  defmodule StaleTouchesRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.StaleTouchesDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_stale_touches_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_stale_touches_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.Auxiliary]
        change AshReplicant.Test.DestinationFixtures.NoDatabaseChange
      end
    end
  end

  defmodule MissingRootAction do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.MissingRootActionDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_missing_root_actions"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_missing_root_action_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: :*]
    end
  end

  defmodule OpaqueTypeRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.OpaqueTypeDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_opaque_type_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_opaque_type_sources")
    end

    attributes do
      uuid_primary_key :id

      attribute :custom, AshReplicant.Test.DestinationFixtures.OpaqueType,
        public?: true,
        writable?: false
    end

    actions do
      defaults [:read, :destroy, create: []]
    end
  end

  defmodule OpaqueTenantRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.OpaqueTenantDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_opaque_tenant_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_opaque_tenant_sources")
      tenant_mfa({AshReplicant.Test.DestinationFixtures.OpaqueTenantResolver, :resolve, []})
    end

    multitenancy do
      strategy :context
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule AnonymousRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.AnonymousDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_anonymous_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_anonymous_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change fn changeset, _context -> changeset end
      end
    end
  end

  defmodule RaisingRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.RaisingDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_raising_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_raising_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change AshReplicant.Test.DestinationFixtures.RaisingChange
      end
    end
  end

  defmodule InvalidRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.InvalidDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_invalid_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_invalid_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change AshReplicant.Test.DestinationFixtures.InvalidChange
      end
    end
  end

  defmodule MissingActionRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.MissingActionDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_missing_action_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_missing_action_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.Auxiliary]
        change AshReplicant.Test.DestinationFixtures.MissingActionChange
      end
    end
  end

  defmodule ForeignAuxiliaryRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ForeignAuxiliaryDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_foreign_auxiliary_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_foreign_auxiliary_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.ForeignAuxiliary]
        change AshReplicant.Test.DestinationFixtures.ForeignAuxiliaryChange
      end
    end
  end

  defmodule ForeignMappedRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ForeignMappedDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_foreign_mapped_roots"
      repo AshReplicant.Test.DestinationFixtures.ForeignRepo
    end

    replicant do
      source_table("destination_foreign_mapped_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule SimpleRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.SimpleDomain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshReplicant.Resource]

    replicant do
      source_table("destination_simple_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule SimpleAuxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.SimpleAuxiliaryDomain,
      data_layer: Ash.DataLayer.Simple

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
      create :record, accept: []
    end
  end

  defmodule SimpleAuxiliaryRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.SimpleAuxiliaryDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_simple_auxiliary_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_simple_auxiliary_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.SimpleAuxiliary]
        change AshReplicant.Test.DestinationFixtures.SimpleAuxiliaryChange
      end
    end
  end

  defmodule GenericRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.GenericDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_generic_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_generic_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.Auxiliary]

        change {AshReplicant.Test.DestinationFixtures.AuxiliaryChange, auxiliary_action: :opaque}
      end
    end
  end

  defmodule CycleA do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.CycleDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_cycle_as"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_cycle_source_as")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.CycleB]
        change AshReplicant.Test.DestinationFixtures.CycleAChange
      end
    end
  end

  defmodule OnetimeRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.OnetimeDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_onetime_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_onetime_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.OnetimeAuxiliary]
        change AshReplicant.Test.DestinationFixtures.OnetimeAuxiliaryChange
      end
    end
  end

  defmodule ContextOnetimeRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ContextOnetimeDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_context_onetime_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_context_onetime_source_roots")

      tenant_mfa({AshReplicant.Test.DestinationFixtures.ContextTenantResolver, :resolve, []})
    end

    multitenancy do
      strategy :context
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.ContextOnetimeAuxiliary]
        change AshReplicant.Test.DestinationFixtures.ContextOnetimeAuxiliaryChange
      end
    end
  end

  defmodule CycleB do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.CycleDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "destination_cycle_bs"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.CycleA]
        change AshReplicant.Test.DestinationFixtures.CycleBChange
      end
    end
  end

  defmodule ForeignCheckpoint do
    @moduledoc false
    use AshReplicant.Checkpoint,
      repo: AshReplicant.Test.DestinationFixtures.ForeignRepo,
      domain: AshReplicant.Test.DestinationFixtures.ForeignCheckpointDomain
  end

  defmodule CallableRepoRoot do
    @moduledoc false
    alias AshReplicant.Test.DestinationFixtures.CallableRepo

    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.CallableRepoDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_callable_repo_roots"
      repo &CallableRepo.resolve/2
    end

    replicant do
      source_table("destination_callable_repo_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule ForeignChild do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.RelationshipDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "destination_foreign_children"
      repo AshReplicant.Test.DestinationFixtures.ForeignRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :root_id, :uuid, allow_nil?: false
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule CascadeRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.CascadeDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_cascade_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_cascade_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    relationships do
      has_many :children, AshReplicant.Test.DestinationFixtures.ForeignChild do
        destination_attribute :root_id
      end
    end

    actions do
      defaults [:read, create: :*]

      destroy :destroy do
        primary? true
        touches_resources [AshReplicant.Test.DestinationFixtures.ForeignChild]
        change cascade_destroy(:children)
      end
    end
  end

  defmodule RelationshipRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.RelationshipDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_relationship_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_relationship_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    relationships do
      has_many :children, AshReplicant.Test.DestinationFixtures.ForeignChild do
        destination_attribute :root_id
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        argument :children, {:array, :map}
        touches_resources [AshReplicant.Test.DestinationFixtures.ForeignChild]

        change manage_relationship(:children, :children,
                 on_no_match: :create,
                 on_match: :ignore,
                 on_missing: :ignore,
                 on_lookup: :ignore
               )
      end
    end
  end

  defmodule SplitRepoRoot do
    @moduledoc false
    alias AshReplicant.Test.DestinationFixtures.SplitRepo

    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.SplitRepoDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_split_repo_roots"
      repo &SplitRepo.resolve/2
    end

    replicant do
      source_table("destination_split_repo_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy, create: :*]
    end
  end

  defmodule UnionTypeRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.UnionTypeDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_union_type_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_union_type_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []

        argument :payload, :union,
          constraints: [types: [opaque: [type: AshReplicant.Test.DestinationFixtures.OpaqueType]]]
      end
    end
  end

  defmodule AnonymousDefaultRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.AnonymousDefaultDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_anonymous_default_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_anonymous_default_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        argument :generated, :string, default: fn -> "generated" end
      end
    end
  end

  defmodule HiddenDefaultRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.HiddenDefaultDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_hidden_default_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_hidden_default_source_roots")
    end

    attributes do
      uuid_primary_key :id
      attribute :hidden, :string, writable?: false, default: fn -> "generated" end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
      end
    end
  end

  defmodule HiddenUpdateDefaultRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.HiddenUpdateDefaultDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_hidden_update_default_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_hidden_update_default_source_roots")
    end

    attributes do
      uuid_primary_key :id
      attribute :hidden, :string, writable?: false, update_default: fn -> "generated" end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
      end
    end
  end

  defmodule ParticipantDefaultRoot do
    @moduledoc false
    @behaviour AshReplicant.DestinationParticipant

    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ParticipantDefaultDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_participant_default_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_participant_default_source_roots")
    end

    attributes do
      uuid_primary_key :id
      attribute :hidden, :string, writable?: false, default: fn -> "generated" end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
      end
    end

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}), do: {:ok, :no_database}
  end

  defmodule NamedDefaultRoot do
    @moduledoc false
    alias AshReplicant.Test.DestinationFixtures.NamedDefaultProvider

    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.NamedDefaultDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_named_default_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_named_default_source_roots")
    end

    attributes do
      uuid_primary_key :id

      attribute :hidden, :string,
        writable?: false,
        update_default: &NamedDefaultProvider.default_value/0
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []

        argument :generated, :string, default: &NamedDefaultProvider.default_value/0
      end
    end
  end

  defmodule SoftDestroyChild do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.SoftDestroyDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "destination_soft_destroy_children"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :root_id, :uuid, allow_nil?: false
      attribute :discarded, :boolean, allow_nil?: false, default: false
      attribute :hidden, :string, writable?: false, update_default: fn -> "generated" end
    end

    actions do
      defaults [:read, create: :*]

      destroy :destroy do
        primary? true
        soft? true
        require_atomic? false
        accept []
        change set_attribute(:discarded, true)
      end
    end
  end

  defmodule SoftDestroyRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.SoftDestroyDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_soft_destroy_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_soft_destroy_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    relationships do
      has_many :children, AshReplicant.Test.DestinationFixtures.SoftDestroyChild do
        destination_attribute :root_id
      end
    end

    actions do
      defaults [:read, create: :*]

      destroy :destroy do
        primary? true
        touches_resources [AshReplicant.Test.DestinationFixtures.SoftDestroyChild]
        change cascade_destroy(:children)
      end
    end
  end

  defmodule ValidationRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ValidationDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_validation_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_validation_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        validate present(:id)
      end
    end
  end

  defmodule OpaqueValidationRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.OpaqueValidationDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_opaque_validation_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_opaque_validation_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        validate AshReplicant.Test.DestinationFixtures.OpaqueValidation
      end
    end
  end

  defmodule MalformedParticipantRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.MalformedParticipantDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_malformed_participant_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_malformed_participant_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change AshReplicant.Test.DestinationFixtures.MalformedChange
      end
    end
  end

  defmodule ContextRedirectCreateRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ContextRedirectCreateDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_context_redirect_create_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_context_redirect_create_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change set_context(%{data_layer: %{table: "unmanifested_create_target"}})
      end
    end
  end

  defmodule ContextRedirectDestroyRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ContextRedirectDestroyDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_context_redirect_destroy_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_context_redirect_destroy_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: :*]

      destroy :destroy do
        primary? true
        change set_context(%{data_layer: %{schema: "unmanifested_destroy_schema"}})
      end
    end
  end

  defmodule SafeContextRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.SafeContextDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_safe_context_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_safe_context_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change set_context(%{private: %{safe_marker: true}})
      end
    end
  end

  # An MFA (dynamic) SetContext whose module DECLARES its effects through the
  # DestinationParticipant escape hatch — admitted.
  defmodule DeclaredMfaContextRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.DeclaredMfaContextDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    @behaviour AshReplicant.DestinationParticipant

    postgres do
      table "destination_declared_mfa_context_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_declared_mfa_context_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change set_context({__MODULE__, :compute_context, []})
      end
    end

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %AshReplicant.DestinationParticipant.Context{}),
      do: {:ok, :no_database}

    def compute_context(_subject), do: %{private: %{mfa_marker: true}}
  end

  # The same MFA SetContext with NO declaration — rejected fail-closed.
  defmodule UndeclaredMfaContextRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.UndeclaredMfaContextDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_undeclared_mfa_context_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_undeclared_mfa_context_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change set_context({__MODULE__, :compute_context, []})
      end
    end

    def compute_context(_subject), do: %{data_layer: %{table: "unmanifested_mfa_target"}}
  end

  # The Preparation twin of the data-layer redirect — rejected like the change.
  defmodule ContextRedirectPreparationRoot do
    @moduledoc false
    use Ash.Resource,
      primary_read_warning?: false,
      domain: AshReplicant.Test.DestinationFixtures.ContextRedirectPreparationDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_context_redirect_preparation_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_context_redirect_preparation_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:destroy, create: :*]

      read :read do
        primary? true
        prepare set_context(%{data_layer: %{table: "unmanifested_preparation_target"}})
      end
    end
  end

  # `:shared` promotion redirect — Ash.Changeset.set_context merges `map[:shared]`
  # over the WHOLE context, so a nested shared.data_layer redirects too.
  defmodule SharedContextRedirectRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.SharedContextRedirectDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_shared_context_redirect_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_shared_context_redirect_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change set_context(%{shared: %{data_layer: %{table: "unmanifested_shared_target"}}})
      end
    end
  end

  # Operation-identity forge: `:ash_replicant_operation` is the sink-owned
  # effect-once identity operation_key/2 reads — a host SetContext over it would
  # mint one replay key for every row.
  defmodule ForgedOperationContextRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ForgedOperationContextDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_forged_operation_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_forged_operation_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change set_context(%{ash_replicant_operation: %{commit_lsn: 0, ordinal: 0}})
      end
    end
  end

  # `prepare build(context: ...)` forwards into Ash.Query.build, whose context
  # option can redirect data_layer.
  defmodule BuildContextRedirectRoot do
    @moduledoc false
    use Ash.Resource,
      primary_read_warning?: false,
      domain: AshReplicant.Test.DestinationFixtures.BuildContextRedirectDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_build_context_redirect_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_build_context_redirect_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:destroy, create: :*]

      read :read do
        primary? true
        prepare build(context: %{data_layer: %{table: "unmanifested_build_target"}})
      end
    end
  end

  # A declared auxiliary action under `multitenancy :bypass` — Ash would ignore
  # the inherited tenant on its writes.
  defmodule TenantBypassAuxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.TenantBypassDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "destination_tenant_bypass_auxiliaries"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        multitenancy :bypass
        accept []
      end
    end
  end

  defmodule TenantBypassAuxiliaryChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    alias AshReplicant.DestinationParticipant.{ActionRef, Context}

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.TenantBypassAuxiliary,
            action: :record
          }
        ]}}
    end
  end

  defmodule TenantBypassRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.TenantBypassDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_tenant_bypass_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_tenant_bypass_sources")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.TenantBypassAuxiliary]
        change AshReplicant.Test.DestinationFixtures.TenantBypassAuxiliaryChange
      end
    end
  end

  defmodule ContextRedirectScd2Root do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ContextRedirectScd2Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_context_redirect_scd2_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_context_redirect_scd2_sources")
      history_strategy(:scd2)
      history_business_key([:business_id])
      upsert_identity(:version)
      history_close_action(:close_version)
      history_current_attribute(:is_current)
    end

    attributes do
      uuid_primary_key :id
      attribute :business_id, :string, allow_nil?: false
      attribute :valid_from_lsn, :integer, allow_nil?: false
      attribute :valid_to_lsn, :integer
      attribute :is_current, :boolean, allow_nil?: false, default: true
    end

    identities do
      identity :version, [:business_id, :valid_from_lsn]
    end

    actions do
      defaults [:read, :destroy, create: :*]

      update :close_version do
        accept [:valid_to_lsn, :is_current]
        change set_context(%{data_layer: %{table: "unmanifested_scd2_target"}})
      end
    end
  end

  defmodule ContextRedirectCheckpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.ContextRedirectCheckpointDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "destination_context_redirect_checkpoints"
      repo AshReplicant.TestRepo
    end

    attributes do
      attribute :slot_name, :string, primary_key?: true, allow_nil?: false
      attribute :commit_lsn, :integer, allow_nil?: false
    end

    identities do
      identity :unique_slot, [:slot_name]
    end

    actions do
      defaults [:read]

      create :upsert do
        upsert? true
        upsert_identity :unique_slot
        accept [:slot_name, :commit_lsn]
        change set_context(%{data_layer: %{table: "unmanifested_checkpoint_target"}})
      end

      # The checkpoint root set requires the operator-reset destroy (B2 shape).
      destroy :operator_reset
    end
  end

  defmodule UnknownWrapperRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.UnknownWrapperDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_unknown_wrapper_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_unknown_wrapper_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        change AshReplicant.Test.DestinationFixtures.UnknownWrapper
      end
    end
  end

  defmodule OnetimeOpaqueRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.OnetimeOpaqueDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource, AshOnetime.Resource]

    postgres do
      table "destination_onetime_opaque_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_onetime_opaque_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        transaction? true
        argument :proof, :string, allow_nil?: false
        accept []
      end
    end

    onetime do
      protect :create do
        strategy :one_time_nonce
        scope([{:static, "destination-onetime-opaque"}])
        key({:verified, :proof, AshReplicant.Test.DestinationFixtures.OpaqueProofVerifier})
        window(max_age: {5, :minute}, clock_skew: {30, :second})
      end
    end
  end

  defmodule CascadeReadChild do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.CascadeReadDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "destination_cascade_read_children"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :root_id, :uuid, allow_nil?: false
    end

    actions do
      defaults [:read, :destroy, create: :*]

      read :unsafe_read do
        prepare AshReplicant.Test.DestinationFixtures.OpaquePreparation
      end
    end
  end

  defmodule CascadeReadRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.CascadeReadDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_cascade_read_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_cascade_read_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    relationships do
      has_many :children, AshReplicant.Test.DestinationFixtures.CascadeReadChild do
        destination_attribute :root_id
        read_action :unsafe_read
      end
    end

    actions do
      defaults [:read, create: :*]

      destroy :destroy do
        primary? true
        touches_resources [AshReplicant.Test.DestinationFixtures.CascadeReadChild]
        change cascade_destroy(:children)
      end
    end
  end

  defmodule RelateActorRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.RelateActorDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_relate_actor_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_relate_actor_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    relationships do
      has_one :child, AshReplicant.Test.DestinationFixtures.ForeignChild do
        destination_attribute :root_id
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.ForeignChild]
        change relate_actor(:child)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.Root
      resource AshReplicant.Test.DestinationFixtures.Auxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule UnknownDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.UnknownRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule BadTouchesDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.BadTouchesRoot
      resource AshReplicant.Test.DestinationFixtures.Auxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule StaleTouchesDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.StaleTouchesRoot
      resource AshReplicant.Test.DestinationFixtures.Auxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule MissingRootActionDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.MissingRootAction
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule OpaqueTypeDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.OpaqueTypeRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule OpaqueTenantDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.OpaqueTenantRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule AnonymousDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.AnonymousRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule RaisingDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.RaisingRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule InvalidDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.InvalidRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule MissingActionDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.MissingActionRoot
      resource AshReplicant.Test.DestinationFixtures.Auxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ForeignAuxiliaryDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ForeignAuxiliaryRoot
      resource AshReplicant.Test.DestinationFixtures.ForeignAuxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ForeignMappedDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ForeignMappedRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule SimpleDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.SimpleRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule SimpleAuxiliaryDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.SimpleAuxiliaryRoot
      resource AshReplicant.Test.DestinationFixtures.SimpleAuxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule GenericDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.GenericRoot
      resource AshReplicant.Test.DestinationFixtures.Auxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule CycleDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.CycleA
      resource AshReplicant.Test.DestinationFixtures.CycleB
      resource AshReplicant.Test.Checkpoint
    end
  end

  # Live nonce-profile fixtures: a REAL AshOnetime :one_time_nonce protection
  # (not a struct mutation) riding a declared participant — the live-substrate
  # proof that nonce admission rejection writes zero claim rows.
  defmodule NonceProofVerifier do
    @moduledoc false
    @behaviour AshOnetime.Verifier
    @behaviour AshReplicant.DestinationParticipant

    @impl AshOnetime.Verifier
    def verify(_token, _context), do: {:error, :unverified}

    @impl AshOnetime.Verifier
    def algorithm, do: :hmac_sha256

    @impl AshOnetime.Verifier
    def trust_model, do: :same_service

    # Declared so the manifest walk passes the verifier as a participant and the
    # rejection isolates the NONCE STRATEGY itself (the profile check), not
    # module opacity.
    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %AshReplicant.DestinationParticipant.Context{}),
      do: {:ok, :no_database}
  end

  defmodule NonceAuxiliary do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.NonceDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "destination_nonce_auxiliaries"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        argument :proof, :string, allow_nil?: false, public?: false
        accept []
      end
    end

    onetime do
      protect :record do
        strategy :one_time_nonce

        scope([
          {:static, "ash_replicant:destination-participant:1"},
          {:static, "nonce_auxiliary"}
        ])

        key({:verified, :proof, AshReplicant.Test.DestinationFixtures.NonceProofVerifier})
        window(max_age: {5, :minute}, clock_skew: {30, :second})
      end
    end
  end

  defmodule NonceAuxiliaryChange do
    @moduledoc false
    use Ash.Resource.Change
    @behaviour AshReplicant.DestinationParticipant

    alias AshReplicant.DestinationParticipant.{ActionRef, Context, ReplayIdentity}

    @impl Ash.Resource.Change
    def change(changeset, _opts, _context), do: changeset

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %Context{}) do
      {:ok,
       {:actions,
        [
          %ActionRef{
            resource: AshReplicant.Test.DestinationFixtures.NonceAuxiliary,
            action: :record,
            replay_identity: %ReplayIdentity{
              participant: :nonce_auxiliary,
              components: [
                :source_system_identifier,
                :source_database,
                :slot_name,
                :commit_lsn,
                :ordinal,
                :participant
              ]
            }
          }
        ]}}
    end
  end

  defmodule NonceRoot do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.DestinationFixtures.NonceDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "destination_nonce_roots"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("destination_nonce_source_roots")
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept []
        touches_resources [AshReplicant.Test.DestinationFixtures.NonceAuxiliary]
        change AshReplicant.Test.DestinationFixtures.NonceAuxiliaryChange
      end
    end
  end

  defmodule NonceDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.NonceRoot
      resource AshReplicant.Test.DestinationFixtures.NonceAuxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule OnetimeDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.OnetimeRoot
      resource AshReplicant.Test.DestinationFixtures.OnetimeAuxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ContextOnetimeDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ContextOnetimeRoot
      resource AshReplicant.Test.DestinationFixtures.ContextOnetimeAuxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ForeignCheckpointDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.Root
      resource AshReplicant.Test.DestinationFixtures.Auxiliary
      resource AshReplicant.Test.DestinationFixtures.ForeignCheckpoint
    end
  end

  defmodule CallableRepoDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.CallableRepoRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule RelationshipDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.RelationshipRoot
      resource AshReplicant.Test.DestinationFixtures.ForeignChild
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule CascadeDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.CascadeRoot
      resource AshReplicant.Test.DestinationFixtures.ForeignChild
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule SplitRepoDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.SplitRepoRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule UnionTypeDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.UnionTypeRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule AnonymousDefaultDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.AnonymousDefaultRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule HiddenDefaultDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.HiddenDefaultRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule HiddenUpdateDefaultDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.HiddenUpdateDefaultRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ParticipantDefaultDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ParticipantDefaultRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule NamedDefaultDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.NamedDefaultRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule SoftDestroyDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.SoftDestroyRoot
      resource AshReplicant.Test.DestinationFixtures.SoftDestroyChild
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ValidationDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ValidationRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule UnknownWrapperDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.UnknownWrapperRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule OnetimeOpaqueDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.OnetimeOpaqueRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule CascadeReadDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.CascadeReadRoot
      resource AshReplicant.Test.DestinationFixtures.CascadeReadChild
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule RelateActorDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.RelateActorRoot
      resource AshReplicant.Test.DestinationFixtures.ForeignChild
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule OpaqueValidationDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.OpaqueValidationRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule MalformedParticipantDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.MalformedParticipantRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ContextRedirectCreateDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ContextRedirectCreateRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ContextRedirectDestroyDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ContextRedirectDestroyRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule SafeContextDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.SafeContextRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule DeclaredMfaContextDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.DeclaredMfaContextRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule UndeclaredMfaContextDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.UndeclaredMfaContextRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ContextRedirectPreparationDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ContextRedirectPreparationRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule SharedContextRedirectDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.SharedContextRedirectRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ForgedOperationContextDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ForgedOperationContextRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule BuildContextRedirectDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.BuildContextRedirectRoot
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule TenantBypassDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.TenantBypassRoot
      resource AshReplicant.Test.DestinationFixtures.TenantBypassAuxiliary
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ContextRedirectScd2Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ContextRedirectScd2Root
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule ContextRedirectCheckpointDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.ContextRedirectCheckpoint
    end
  end

  defmodule Sink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.DestinationFixtures.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "destination_fixture_slot"
  end
end

# --- U3/D4 admission-time identifier-validation fixtures (top level: the
# manifest walk reflects on these through Ash.Domain.Info, which requires
# fully-registered Spark DSL modules) ---

defmodule AshReplicant.Test.DestinationFixtures.BadTableDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.DestinationFixtures.BadTableRoot
    resource AshReplicant.Test.Checkpoint
  end
end

defmodule AshReplicant.Test.DestinationFixtures.BadTableRoot do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.DestinationFixtures.BadTableDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "bad\tname"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("bad_table_source")
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept []
    end
  end
end

defmodule AshReplicant.Test.DestinationFixtures.BadSchemaDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.DestinationFixtures.BadSchemaRoot
    resource AshReplicant.Test.Checkpoint
  end
end

defmodule AshReplicant.Test.DestinationFixtures.BadSchemaRoot do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.DestinationFixtures.BadSchemaDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "bad_schema_roots"
    schema "bad\nschema"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("bad_schema_source")
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept []
    end
  end
end

defmodule AshReplicant.Test.DestinationFixtures.BadWindowDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.DestinationFixtures.BadWindowVersion
    resource AshReplicant.Test.Checkpoint
  end
end

defmodule AshReplicant.Test.DestinationFixtures.BadWindowVersion do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.DestinationFixtures.BadWindowDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "bad_window_versions"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("bad_window_source")
    history_strategy(:scd2)
    history_business_key([:order_id])
    upsert_identity(:bad_window_version)
    history_close_action(:close_version)
    history_current_attribute(:is_current)
    history_valid_to_timestamp_attribute(:valid_to_ts)
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :string, allow_nil?: false, public?: true
    attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
    attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
    attribute :valid_to_ts, :utc_datetime_usec, source: :"bad\nts", public?: true
    attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
  end

  identities do
    identity :bad_window_version, [:order_id, :valid_from_lsn]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :close_version do
      accept [:valid_to_lsn, :valid_to_ts, :is_current]
    end
  end
end
