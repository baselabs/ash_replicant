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
        argument :proof, :string, allow_nil?: false
        accept []
      end
    end

    onetime do
      protect :record do
        strategy :one_time_nonce
        scope([{:static, "destination-onetime"}])
        key({:verified, :proof, AshReplicant.Test.DestinationFixtures.ProofVerifier})
        window(max_age: {5, :minute}, clock_skew: {30, :second})
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
      attribute :custom, AshReplicant.Test.DestinationFixtures.OpaqueType, public?: true
    end

    actions do
      defaults [:read, :destroy, create: [:custom]]
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

  defmodule OnetimeDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.DestinationFixtures.OnetimeRoot
      resource AshReplicant.Test.DestinationFixtures.OnetimeAuxiliary
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

  defmodule Sink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.DestinationFixtures.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "destination_fixture_slot"
  end
end
