defmodule AshReplicant.DestinationTest do
  use ExUnit.Case, async: false

  alias AshReplicant.Destination
  alias AshReplicant.Test.DestinationFixtures

  test "builds one deterministic closed manifest for mapped, auxiliary, and checkpoint actions" do
    config = DestinationFixtures.Sink.__ash_replicant_config__()

    assert {:ok, first} = Destination.manifest(config)
    assert {:ok, second} = Destination.manifest(config)
    assert first == second
    assert byte_size(first.digest) == 32

    participants = MapSet.new(first.entries, &{&1.resource, &1.action, &1.role})

    assert {DestinationFixtures.Auxiliary, :record, :auxiliary} in participants
    assert {DestinationFixtures.Root, :create, :mapped} in participants
    assert {AshReplicant.Test.Checkpoint, :upsert, :checkpoint} in participants
    assert {AshReplicant.Test.Checkpoint, :read, :checkpoint} in participants

    auxiliary =
      Enum.find(first.entries, &(&1.resource == DestinationFixtures.Auxiliary))

    assert auxiliary.source == DestinationFixtures.AuxiliaryChange
    assert auxiliary.tenant_mode == :inherit
    assert auxiliary.replay_identity.participant == :destination_auxiliary
    assert :ordinal in auxiliary.replay_identity.components
  end

  test "resolver resources and index share one deterministic mapped-resource enumeration" do
    domains = [DestinationFixtures.Domain]

    assert [DestinationFixtures.Root] = AshReplicant.Resolver.resources(domains)
    assert {:ok, index} = AshReplicant.Resolver.build_index(domains)
    assert Map.values(index) == AshReplicant.Resolver.resources(domains)
  end

  test "unknown custom action code fails closed" do
    config = %{
      repo: AshReplicant.TestRepo,
      domains: [DestinationFixtures.UnknownDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint
    }

    assert {:error,
            {:destination_participant_required, DestinationFixtures.UnknownRoot, :create,
             DestinationFixtures.UnknownChange}} = Destination.manifest(config)
  end

  test "plain Ecto sink Repo is rejected" do
    assert {:error, {:invalid_destination_config, :repo}} =
             Destination.manifest(%{
               repo: DestinationFixtures.PlainRepo,
               domains: [DestinationFixtures.Domain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "non-Postgres mapped resource is rejected" do
    assert {:error, {:destination_repo_not_postgres, DestinationFixtures.SimpleRoot}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.SimpleDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "foreign mapped resource Repo is rejected" do
    assert {:error, {:destination_repo_mismatch, DestinationFixtures.ForeignMappedRoot}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.ForeignMappedDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "foreign checkpoint Repo is rejected" do
    assert {:error, {:destination_repo_mismatch, DestinationFixtures.ForeignCheckpoint}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.Domain],
               checkpoint_resource: DestinationFixtures.ForeignCheckpoint
             })
  end

  test "declared auxiliary resource on another Repo is rejected" do
    assert {:error, {:destination_repo_mismatch, DestinationFixtures.ForeignAuxiliary}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.ForeignAuxiliaryDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "missing declared auxiliary action is rejected" do
    assert {:error, {:destination_action_missing, DestinationFixtures.Auxiliary, :missing}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.MissingActionDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "missing required mapped root action is rejected" do
    assert {:error,
            {:destination_action_missing, DestinationFixtures.MissingRootAction, :destroy}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.MissingRootActionDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "opaque custom input type is rejected" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.OpaqueTypeRoot, :create,
             DestinationFixtures.OpaqueType}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.OpaqueTypeDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "opaque tenant resolver is rejected" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.OpaqueTenantRoot, :create,
             DestinationFixtures.OpaqueTenantResolver}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.OpaqueTenantDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "provider and touches_resources must name the same resource set" do
    assert {:error,
            {:destination_participant_mismatch, DestinationFixtures.BadTouchesRoot, :create}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.BadTouchesDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "stale touches_resources entry without a participant is rejected" do
    assert {:error,
            {:destination_participant_mismatch, DestinationFixtures.StaleTouchesRoot, :create}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.StaleTouchesDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "callable raw Repo is rejected without invocation" do
    key = DestinationFixtures.CallableRepo.probe_key()
    :persistent_term.erase(key)
    on_exit(fn -> :persistent_term.erase(key) end)

    assert {:error, {:destination_repo_dynamic, DestinationFixtures.CallableRepoRoot}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.CallableRepoDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })

    refute :persistent_term.get(key, false)
  end

  test "split read and mutate Repo callable is rejected without invocation" do
    assert {:error, {:destination_repo_dynamic, DestinationFixtures.SplitRepoRoot}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.SplitRepoDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "callable application Repo override is rejected without invocation" do
    resource = DestinationFixtures.Auxiliary
    key = DestinationFixtures.CallableRepo.probe_key()
    previous = Application.fetch_env(:ash_replicant, resource)

    :persistent_term.erase(key)

    on_exit(fn ->
      :persistent_term.erase(key)

      case previous do
        {:ok, value} -> Application.put_env(:ash_replicant, resource, value)
        :error -> Application.delete_env(:ash_replicant, resource)
      end
    end)

    Application.put_env(
      :ash_replicant,
      resource,
      postgres: [repo: &DestinationFixtures.CallableRepo.resolve/2]
    )

    assert {:error, {:destination_repo_dynamic, DestinationFixtures.Auxiliary}} =
             Destination.manifest(DestinationFixtures.Sink.__ash_replicant_config__())

    refute :persistent_term.get(key, false)
  end

  test "anonymous action change is rejected as opaque application code" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.AnonymousRoot, :create,
             Ash.Resource.Change.Function}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.AnonymousDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "anonymous action argument default is rejected as opaque application code" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.AnonymousDefaultRoot, :create,
             Function}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.AnonymousDefaultDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "anonymous non-writable attribute default is rejected even when the action accepts nothing" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.HiddenDefaultRoot, :create,
             Function}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.HiddenDefaultDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "named default provider whose function begins with default is admitted by declaration" do
    assert {:ok, _manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.NamedDefaultDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "custom type nested inside a builtin union is inspected" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.UnionTypeRoot, :create,
             DestinationFixtures.OpaqueType}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.UnionTypeDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "safe action-local validation remains supported" do
    assert {:ok, _manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.ValidationDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "unknown lifecycle wrapper fails closed" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.UnknownWrapperRoot, :create,
             DestinationFixtures.UnknownWrapper}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.UnknownWrapperDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "raising provider is normalized without leaking its exception value" do
    result =
      Destination.manifest(%{
        repo: AshReplicant.TestRepo,
        domains: [DestinationFixtures.RaisingDomain],
        checkpoint_resource: AshReplicant.Test.Checkpoint
      })

    assert {:error, {:destination_participant_invalid, DestinationFixtures.RaisingChange}} =
             result

    refute inspect(result) =~ "row-value sentinel"
  end

  test "invalid provider declaration is rejected" do
    assert {:error, {:destination_participant_invalid, DestinationFixtures.InvalidChange}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.InvalidDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "opaque generic action implementation is inspected and rejected" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.Auxiliary, :opaque,
             DestinationFixtures.OpaqueAction}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.GenericDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "recursive declared action graph is rejected at the active back-edge" do
    config = %{
      repo: AshReplicant.TestRepo,
      domains: [DestinationFixtures.CycleDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint
    }

    assert {:error, {:destination_participant_cycle, DestinationFixtures.CycleA, :create}} =
             Destination.manifest(config)
  end

  test "manifest retains exact AshOnetime protection metadata and wrapper correlation" do
    assert {:ok, manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.OnetimeDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })

    entry =
      Enum.find(
        manifest.entries,
        &(&1.resource == DestinationFixtures.OnetimeAuxiliary and &1.action == :record)
      )

    assert entry.source == DestinationFixtures.OnetimeAuxiliaryChange
    assert entry.protection.strategy == :one_time_nonce
    assert entry.protection.commit == :with_action
    assert entry.protection.on_definite_store_failure == :fail_closed

    assert entry.protection.key == [
             {:verified, :proof, DestinationFixtures.ProofVerifier}
           ]

    refute Map.has_key?(entry.protection, :__spark_metadata__)
  end

  test "AshOnetime verifier callback must declare destination participation" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.OnetimeOpaqueRoot, :create,
             DestinationFixtures.OpaqueProofVerifier}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.OnetimeOpaqueDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "managed relationship recursion rejects a foreign destination Repo" do
    assert {:error, {:destination_repo_mismatch, DestinationFixtures.ForeignChild}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.RelationshipDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "cascade recursion rejects a foreign destination Repo" do
    assert {:error, {:destination_repo_mismatch, DestinationFixtures.ForeignChild}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.CascadeDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "cascade recursion inspects the relationship-selected read action" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.CascadeReadChild,
             :unsafe_read, DestinationFixtures.OpaquePreparation}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.CascadeReadDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "relate_actor has-one recursion rejects a foreign destination Repo" do
    assert {:error, {:destination_repo_mismatch, DestinationFixtures.ForeignChild}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.RelateActorDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "activation revalidates application Repo drift before writing generation state" do
    resource = DestinationFixtures.Auxiliary
    slot = DestinationFixtures.Sink.__ash_replicant_config__().slot_name
    key = {AshReplicant, slot}
    previous = Application.fetch_env(:ash_replicant, resource)

    on_exit(fn ->
      :persistent_term.erase(key)

      case previous do
        {:ok, value} -> Application.put_env(:ash_replicant, resource, value)
        :error -> Application.delete_env(:ash_replicant, resource)
      end
    end)

    Application.put_env(
      :ash_replicant,
      resource,
      postgres: [repo: &DestinationFixtures.CallableRepo.resolve/2]
    )

    assert {:error, {:destination_repo_dynamic, DestinationFixtures.Auxiliary}} =
             AshReplicant.start_link(
               sink: DestinationFixtures.Sink,
               source_identity: [system_identifier: "destination-system", database: "source"],
               publication: "destination_publication"
             )

    assert :persistent_term.get(key, :absent) == :absent
  end

  test "after-compile gate rejects an invalid sink without writing generation state" do
    module = Module.concat(__MODULE__, "InvalidSink#{System.unique_integer([:positive])}")
    slot = "invalid_destination_#{System.unique_integer([:positive])}"
    key = {AshReplicant, slot}

    source = """
    defmodule #{inspect(module)} do
      use AshReplicant.Sink,
        repo: AshReplicant.TestRepo,
        domains: [AshReplicant.Test.DestinationFixtures.UnknownDomain],
        checkpoint_resource: AshReplicant.Test.Checkpoint,
        slot_name: #{inspect(slot)}
    end
    """

    assert_raise CompileError, ~r/unsafe AshReplicant destination/, fn ->
      Code.compile_string(source, "invalid_destination_sink.ex")
    end

    assert :persistent_term.get(key, :absent) == :absent
    :code.purge(module)
    :code.delete(module)
  end

  test "generated sink adds no future Replicant capabilities" do
    assert Code.ensure_loaded?(DestinationFixtures.Sink)
    assert function_exported?(DestinationFixtures.Sink, :handle_transaction, 1)
    refute function_exported?(DestinationFixtures.Sink, :handle_message, 2)
    refute function_exported?(DestinationFixtures.Sink, :handle_batch, 1)
    refute function_exported?(DestinationFixtures.Sink, :snapshot_progress, 0)
    refute function_exported?(DestinationFixtures.Sink, :append, 2)
  end
end
