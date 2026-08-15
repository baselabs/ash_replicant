defmodule AshReplicant.DestinationTest do
  use ExUnit.Case, async: false

  alias AshReplicant.Destination
  alias AshReplicant.DestinationParticipant
  alias AshReplicant.Test.DestinationFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Scd2Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.OrderVersion
      resource AshReplicant.Test.Checkpoint
    end
  end

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
    assert {AshReplicant.Test.Checkpoint, :operator_reset, :checkpoint} in participants

    auxiliary =
      Enum.find(first.entries, &(&1.resource == DestinationFixtures.Auxiliary))

    assert auxiliary.source == DestinationFixtures.AuxiliaryChange
    assert auxiliary.tenant_mode == :inherit
    assert auxiliary.replay_identity.participant == :destination_auxiliary
    assert :ordinal in auxiliary.replay_identity.components
  end

  test "generation fingerprint includes every core admission and execution module" do
    config = DestinationFixtures.Sink.__ash_replicant_config__()
    assert {:ok, manifest} = Destination.manifest(config)
    assert {:ok, modules} = Destination.code_modules(DestinationFixtures.Sink, manifest)

    for module <- [
          AshReplicant,
          AshReplicant.Apply,
          AshReplicant.Apply.Context,
          AshReplicant.Apply.Scd2,
          AshReplicant.Destination,
          AshReplicant.DestinationParticipant,
          AshReplicant.Error,
          AshReplicant.Resolver,
          AshReplicant.Resource.Info,
          AshReplicant.Sink,
          AshReplicant.Sink.Impl,
          AshReplicant.Telemetry
        ] do
      assert module in modules
    end
  end

  test "SCD2 history close action is part of the admitted root graph" do
    assert {:ok, manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [Scd2Domain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })

    assert Enum.any?(
             manifest.entries,
             &(&1.resource == AshReplicant.Test.OrderVersion and &1.action == :close_version and
                 &1.role == :history_close)
           )
  end

  test "resolver resources and index share one deterministic mapped-resource enumeration" do
    domains = [DestinationFixtures.Domain]

    assert {:ok, first} = AshReplicant.Resolver.build_index(domains)
    assert {:ok, second} = AshReplicant.Resolver.build_index(domains)
    assert first == second
    assert Map.values(first) == [DestinationFixtures.Root]

    # The manifest roots and the resolver index enumerate the SAME mapped
    # resources: both traverse Resolver.domain_resources/1, and an enumeration
    # or filter drift between the two surfaces breaks this pin. (A
    # reflection-failing module cannot ride in a WELL-FORMED domain — Ash.Domain's
    # compile-time Spark verification rejects it loudly; only a build that
    # tolerates the warning can list one, landing on the defensive-depth path —
    # so the index-skip / manifest-fail stances are defensive depth, not a
    # reachable drift class for this pin.)
    assert {:ok, manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: domains,
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })

    manifest_root_resources =
      manifest.entries
      |> Enum.filter(&(&1.role == :mapped))
      |> Enum.map(& &1.resource)
      |> Enum.uniq()
      |> Enum.sort()

    assert manifest_root_resources == Enum.sort(Map.values(first))
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

  test "non-Postgres auxiliary resource is rejected" do
    assert {:error, {:destination_repo_not_postgres, DestinationFixtures.SimpleAuxiliary}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.SimpleAuxiliaryDomain],
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

  test "opaque custom type in a non-writable result attribute is rejected" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.OpaqueTypeRoot, :read,
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

  test "anonymous non-writable update default is rejected for create upserts" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.HiddenUpdateDefaultRoot,
             :create, Function}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.HiddenUpdateDefaultDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "resource participation does not admit generated anonymous defaults" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.ParticipantDefaultRoot,
             :create, Function}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.ParticipantDefaultDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "soft destroy update defaults are inspected through recursive cascades" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.SoftDestroyChild, :destroy,
             Function}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.SoftDestroyDomain],
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

  test "undeclared custom validation is rejected" do
    assert {:error,
            {:destination_participant_required, DestinationFixtures.OpaqueValidationRoot, :create,
             DestinationFixtures.OpaqueValidation}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.OpaqueValidationDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "empty participant action declaration is rejected" do
    assert {:error, {:destination_participant_invalid, DestinationFixtures.MalformedChange}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.MalformedParticipantDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "mapped create, destroy, and SCD2-close actions cannot redirect the data-layer target" do
    for {domain, resource, action, module} <- [
          {DestinationFixtures.ContextRedirectCreateDomain,
           DestinationFixtures.ContextRedirectCreateRoot, :create,
           Ash.Resource.Change.SetContext},
          {DestinationFixtures.ContextRedirectDestroyDomain,
           DestinationFixtures.ContextRedirectDestroyRoot, :destroy,
           Ash.Resource.Change.SetContext},
          {DestinationFixtures.ContextRedirectScd2Domain,
           DestinationFixtures.ContextRedirectScd2Root, :close_version,
           Ash.Resource.Change.SetContext}
        ] do
      assert {:error, {:destination_participant_invalid, ^resource, ^action, ^module}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [domain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end
  end

  test "checkpoint upsert cannot redirect the admitted data-layer target" do
    assert {:error,
            {:destination_participant_invalid, DestinationFixtures.ContextRedirectCheckpoint,
             :upsert, Ash.Resource.Change.SetContext}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.Domain],
               checkpoint_resource: DestinationFixtures.ContextRedirectCheckpoint
             })
  end

  test "non-data-layer SetContext remains supported" do
    assert {:ok, _manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.SafeContextDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "an MFA SetContext is admitted via its module's participant declaration and rejected without one" do
    # The dynamic (MFA) context is admissible ONLY through the DestinationParticipant
    # escape hatch — the module behind the MFA declares its effects.
    assert {:ok, manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.DeclaredMfaContextDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })

    assert Enum.any?(
             manifest.entries,
             &(&1.resource == DestinationFixtures.DeclaredMfaContextRoot and &1.role == :mapped)
           )

    # The same MFA form with NO declaration fails closed.
    assert {:error,
            {:destination_participant_required, DestinationFixtures.UndeclaredMfaContextRoot,
             :create, DestinationFixtures.UndeclaredMfaContextRoot}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.UndeclaredMfaContextDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "a Preparation.SetContext that replaces :data_layer is rejected" do
    assert {:error,
            {:destination_participant_invalid, DestinationFixtures.ContextRedirectPreparationRoot,
             :read, Ash.Resource.Preparation.SetContext}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.ContextRedirectPreparationDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "a SetContext through :shared promotion cannot redirect the data layer" do
    assert {:error,
            {:destination_participant_invalid, DestinationFixtures.SharedContextRedirectRoot,
             :create, Ash.Resource.Change.SetContext}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.SharedContextRedirectDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "a SetContext cannot forge the sink-owned operation identity" do
    assert {:error,
            {:destination_participant_invalid, DestinationFixtures.ForgedOperationContextRoot,
             :create, Ash.Resource.Change.SetContext}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.ForgedOperationContextDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "a build preparation carrying a context option is rejected" do
    assert {:error,
            {:destination_participant_invalid, DestinationFixtures.BuildContextRedirectRoot,
             :read, Ash.Resource.Preparation.Build}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.BuildContextRedirectDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })
  end

  test "a declared auxiliary action under multitenancy bypass is rejected" do
    assert {:error,
            {:destination_action_tenant_bypass, DestinationFixtures.TenantBypassAuxiliary,
             :record}} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.TenantBypassDomain],
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
    assert entry.protection.strategy == :idempotency
    assert entry.protection.commit == :with_action
    assert entry.protection.on_definite_store_failure == :fail_closed

    assert entry.protection.key == [
             {:argument, :operation_key}
           ]

    assert entry.protection.scope == [
             {:static, "ash_replicant:destination-participant:1"},
             {:static, "onetime_auxiliary"}
           ]

    refute Map.has_key?(entry.protection, :__spark_metadata__)
  end

  test "AshOnetime WAL admission matrix rejects every replay-incompatible profile" do
    assert {:ok, manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [DestinationFixtures.OnetimeDomain],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })

    accepted =
      Enum.find(
        manifest.entries,
        &(&1.resource == DestinationFixtures.OnetimeAuxiliary and &1.action == :record)
      )

    exact_components = accepted.replay_identity.components

    rejected = [
      {"mapped row action", %{accepted | role: :mapped}},
      {"commit LSN only", put_in(accepted.replay_identity.components, [:commit_lsn])},
      {"missing ordinal",
       put_in(accepted.replay_identity.components, List.delete(exact_components, :ordinal))},
      {"missing participant component",
       put_in(accepted.replay_identity.components, List.delete(exact_components, :participant))},
      {"missing participant identity", put_in(accepted.replay_identity.participant, nil)},
      {"row-only identity", put_in(accepted.protection.key, [{:attribute, :id}])},
      {"random minted identity", put_in(accepted.protection.key, [{:minted, Ash.UUID}])},
      {"callable verified identity",
       put_in(accepted.protection.key, [
         {:verified, :operation_key, DestinationFixtures.ProofVerifier}
       ])},
      {"unversioned scope", put_in(accepted.protection.scope, [{:static, "auxiliary"}])},
      {"nonce with action",
       accepted
       |> put_in([Access.key(:protection), :strategy], :one_time_nonce)
       |> put_in([Access.key(:protection), :commit], :with_action)},
      {"nonce independent",
       accepted
       |> put_in([Access.key(:protection), :strategy], :one_time_nonce)
       |> put_in([Access.key(:protection), :commit], :independent)},
      {"idempotency independent", put_in(accepted.protection.commit, :independent)},
      {"execute untracked",
       put_in(accepted.protection.on_definite_store_failure, :execute_untracked)},
      {"external effect", put_in(accepted.protection.external_effect, String)},
      {"missing response", put_in(accepted.protection.response, nil)}
    ]

    Enum.each(rejected, fn {label, entry} ->
      assert {:error, {:destination_participant_invalid, AshOnetime.Resource}} =
               Destination.validate_onetime_entries([entry]),
             label
    end)

    assert :ok = Destination.validate_onetime_entries([accepted])
  end

  test "AshOnetime cache must be the effect-free cache" do
    previous = Application.get_env(:ash_onetime, :cache)
    on_exit(fn -> restore_env(:ash_onetime, :cache, previous) end)

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

    Application.put_env(:ash_onetime, :cache, DestinationFixtures.OpaqueCache)

    assert {:error, {:destination_participant_invalid, AshOnetime.Resource}} =
             Destination.validate_onetime_entries([entry])

    Application.put_env(:ash_onetime, :cache, AshOnetime.Cache.None)
    assert :ok = Destination.validate_onetime_entries([entry])
  end

  @tag :integration
  test "context-tenant store preflight is root-scoped and runs inside the transaction" do
    :ok = Sandbox.checkout(AshReplicant.TestRepo)

    assert {:ok, dynamic_repo} =
             Destination.effective_dynamic_repo(AshReplicant.TestRepo)

    assert {:ok, manifest} =
             Destination.manifest(%{
               repo: AshReplicant.TestRepo,
               domains: [
                 DestinationFixtures.OnetimeDomain,
                 DestinationFixtures.ContextOnetimeDomain
               ],
               checkpoint_resource: AshReplicant.Test.Checkpoint
             })

    assert :ok = Destination.preflight_onetime(manifest, dynamic_repo)

    assert :ok =
             AshReplicant.TestRepo.transaction(fn ->
               Destination.preflight_onetime_transaction(
                 manifest,
                 dynamic_repo,
                 "public",
                 DestinationFixtures.ContextOnetimeRoot,
                 :create
               )
             end)
             |> elem(1)

    missing_prefix = "missing_#{System.unique_integer([:positive])}"

    assert {:error, {:invalid_destination_config, :onetime_store}} =
             AshReplicant.TestRepo.transaction(fn ->
               Destination.preflight_onetime_transaction(
                 manifest,
                 dynamic_repo,
                 missing_prefix,
                 DestinationFixtures.ContextOnetimeRoot,
                 :create
               )
             end)
             |> elem(1)

    assert %{rows: [[nil]]} =
             SQL.query!(
               AshReplicant.TestRepo,
               "SELECT to_regclass('public.destination_context_onetime_roots')",
               []
             )

    assert {:ok, resolver_index} =
             AshReplicant.Resolver.build_index([DestinationFixtures.ContextOnetimeDomain])

    config = %{
      repo: AshReplicant.TestRepo,
      dynamic_repo: dynamic_repo,
      data_layer_context: %{repo: dynamic_repo},
      destination_manifest: manifest,
      resolver_index: resolver_index,
      authorize?: false,
      source_identity: %{system_identifier: "system", database: "source"},
      slot_name: "slot"
    }

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "destination_context_onetime_source_roots",
      record: %{"id" => Ash.UUID.generate(), "tenant" => missing_prefix},
      commit_lsn: 42,
      ordinal: 0
    }

    error =
      assert_raise AshReplicant.Error, fn ->
        AshReplicant.TestRepo.transaction(fn ->
          AshReplicant.Apply.apply_change(config, change)
        end)
      end

    assert error.reason == {:invalid_destination_config, :onetime_store}

    assert :ok =
             AshReplicant.TestRepo.transaction(fn ->
               Destination.preflight_onetime_transaction(
                 manifest,
                 dynamic_repo,
                 nil,
                 DestinationFixtures.OnetimeRoot,
                 :create
               )
             end)
             |> elem(1)
  end

  test "operation keys are closed, deterministic, and sensitive to every identity axis" do
    context = %{
      source_system_identifier: "system",
      source_database: "source",
      slot_name: "slot",
      commit_lsn: 42,
      ordinal: 0,
      invocation: :upsert
    }

    assert {:ok, first} =
             DestinationParticipant.operation_key(context, :auxiliary)

    assert {:ok, ^first} =
             DestinationParticipant.operation_key(context, :auxiliary)

    for {component, replacement} <- [
          source_system_identifier: "other-system",
          source_database: "other-source",
          slot_name: "other-slot",
          commit_lsn: 43,
          ordinal: 1,
          invocation: :close_prior
        ] do
      assert {:ok, changed} =
               context
               |> Map.put(component, replacement)
               |> DestinationParticipant.operation_key(:auxiliary)

      refute first == changed, Atom.to_string(component)
    end

    assert {:ok, changed_participant} =
             DestinationParticipant.operation_key(context, :other_auxiliary)

    refute first == changed_participant

    assert {:error, :invalid_declaration} =
             context
             |> Map.delete(:ordinal)
             |> DestinationParticipant.operation_key(:auxiliary)

    assert {:error, :invalid_declaration} =
             context
             |> Map.put(:unexpected, true)
             |> DestinationParticipant.operation_key(:auxiliary)

    assert {:error, :invalid_declaration} =
             DestinationParticipant.operation_key(context, nil)
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

  @tag :integration
  test "a live nonce protection is rejected at admission with zero claim rows" do
    :ok = Sandbox.checkout(AshReplicant.TestRepo)

    claims_before = fn ->
      [[idem]] =
        SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM ash_onetime_idempotency_claims").rows

      [[nonce]] =
        SQL.query!(AshReplicant.TestRepo, "SELECT count(*) FROM ash_onetime_nonce_claims").rows

      {idem, nonce}
    end

    before = claims_before.()

    # The live-substrate proof the design names: a REAL nonce profile (not a
    # struct mutation) fails sink admission on the onetime PROFILE (the verifier
    # module declares :no_database participation, so the walk reaches the
    # strategy check — the rejection isolates nonce-ness itself), and writes no
    # claim row on the way out. Admission fires at the sink's @after_compile, so
    # the sink cannot even compile — let alone start or claim.
    error =
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule AshReplicant.Test.NonceRejectionSink do
          use AshReplicant.Sink,
            repo: AshReplicant.TestRepo,
            domains: [AshReplicant.Test.DestinationFixtures.NonceDomain],
            checkpoint_resource: AshReplicant.Test.Checkpoint,
            slot_name: "nonce_rejection_slot"
        end
        """)
      end

    assert error.description =~ "{:destination_participant_invalid, AshOnetime.Resource}"
    assert claims_before.() == before
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

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

  describe "notifier load/2 manifest admission (U3/D2)" do
    test "an undeclared non-empty load/2 fails the manifest naming resource+action+notifier" do
      # The walk visits the mapped read first; a load-carrying notifier
      # WITHOUT the participant behaviour is undeclared on every
      # sink-driven action.
      assert {:error,
              {:destination_notifier_required, DestinationFixtures.LoadRoot, :read,
               DestinationFixtures.LoadNotifier}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.LoadDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end

    test "TWO declared load-carrying notifiers on one resource admit (redundant edges, never a cycle)" do
      assert {:ok, manifest} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.TwoNotifierLoadDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })

      # Both notifiers' declared reads enter the graph, each sourced from its
      # own declaration.
      read_sources =
        manifest.entries
        |> Enum.filter(
          &(&1.resource == DestinationFixtures.TwoNotifierLoadRoot and &1.action == :read)
        )
        |> Enum.map(& &1.source)

      assert {:notifier, DestinationFixtures.DeclaredLoadNotifier} in read_sources
      assert {:notifier, DestinationFixtures.SecondLoadNotifier} in read_sources
    end

    test "a CROSS-NOTIFIER declaration loop is a true cycle (diff-review F1 pin)" do
      # The root's notifier declares AuxY's read; AuxY's declares AuxX's;
      # AuxX's declares AuxY's again — a deterministic back-edge through
      # NON-ROOT aux reads (memoization at completed cannot absorb it). The
      # strict arm rejects it; the removed redundant-edge arm would have
      # admitted it.
      assert {:error, {:destination_participant_cycle, _resource, action}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.LoopRootDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })

      assert is_atom(action)
    end

    test "a context-INSENSITIVE uniform declaration admits (diff-review F2 pin)" do
      # Declares (R, :read) for EVERY action — including the :read it is
      # probed on. The SELF-EDGE DROP admits it: a notifier declaring the
      # action it was probed on is redundant information, not a cycle of
      # distinct nodes; without the drop this shape cycles at the read root.
      assert {:ok, _manifest} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.UniformLoadDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end

    test "a no_database declaration admits with no new graph edge (the read is already admitted)" do
      assert {:ok, _manifest} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.EmptyDeclarationLoadDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end

    test "a DECLARED load/2 admits (the reads it can trigger enter the manifest)" do
      assert {:ok, manifest} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.DeclaredLoadDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })

      assert Enum.any?(
               manifest.entries,
               &(&1.resource == DestinationFixtures.DeclaredLoadRoot and
                   &1.action == :read and
                   &1.source == {:notifier, DestinationFixtures.DeclaredLoadNotifier})
             ),
             "the load-triggered read enters the admitted graph, sourced from the notifier declaration"
    end
  end

  describe "admission-time identifier validation (U3/D4)" do
    test "a control-character table name fails the manifest before any SQL" do
      assert {:error, {:invalid_destination_config, :identifier}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.BadTableDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end

    test "a control-character schema name fails the manifest" do
      assert {:error, {:invalid_destination_config, :identifier}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.BadSchemaDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end

    test "a control-character SCD2 window column fails the manifest" do
      assert {:error, {:invalid_destination_config, :identifier}} =
               Destination.manifest(%{
                 repo: AshReplicant.TestRepo,
                 domains: [DestinationFixtures.BadWindowDomain],
                 checkpoint_resource: AshReplicant.Test.Checkpoint
               })
    end
  end
end
