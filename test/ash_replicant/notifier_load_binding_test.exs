defmodule AshReplicant.NotifierLoadBindingTest do
  @moduledoc """
  Issue #3 — the admitted notifier `load/2` statement is a BINDING, not a
  one-time observation.

  `Ash.Notifier.notifier_calculation_query/3` re-derives every notifier's load
  statement at delivery and merges it into the post-write load query
  (`deps/ash/lib/ash/notifier/notifier.ex:90`,
  `deps/ash/lib/ash/actions/helpers.ex:751`). Admission probed it once. A
  `load/2` that reads runtime state can therefore be empty when the manifest
  is built and non-empty when the sink delivers — undeclared reads inside the
  destination transaction, with nothing red.

  These tests pin both halves: admission records a closure-aware fingerprint
  for EVERY notifier (empty statements included), and delivery re-derives and
  compares before the action runs.
  """
  use ExUnit.Case, async: false

  alias Ash.Resource.Info, as: AshInfo
  alias AshReplicant.Apply.Context
  alias AshReplicant.Destination
  alias AshReplicant.Destination.NotifierLoads
  alias AshReplicant.DestinationParticipant.ActionRef
  alias AshReplicant.DestinationParticipant.Context, as: ParticipantContext
  alias AshReplicant.Test.DestinationFixtures

  @checkpoint AshReplicant.Test.Checkpoint
  @drift_resource DestinationFixtures.DriftLoadOrder

  # Two closures from ONE code position whose ONLY difference is the captured
  # value. `:erlang.fun_info/1` gives them the same module/index/uniq and
  # different `env` — the exact shape "closure drift" names.
  defp adder(n), do: fn x -> x + n end

  defp config_for(domain),
    do: %{repo: AshReplicant.TestRepo, domains: [domain], checkpoint_resource: @checkpoint}

  # Serve `statement` from application config, then record what admission
  # would have pinned for it.
  defp bind(key, statement, resource \\ @drift_resource, action \\ :create) do
    Application.put_env(:ash_replicant, key, statement)
    {:ok, admitted} = NotifierLoads.bindings(resource, action)
    %{{resource, action} => admitted}
  end

  defp restore_statement_env do
    key = DestinationFixtures.DriftLoadNotifier.statement_key()
    previous = Application.get_env(:ash_replicant, key, :unset)

    on_exit(fn ->
      case previous do
        :unset -> Application.delete_env(:ash_replicant, key)
        value -> Application.put_env(:ash_replicant, key, value)
      end
    end)

    {:ok, key: key}
  end

  describe "fingerprint" do
    test "an identical statement fingerprints identically (non-vacuity control)" do
      assert NotifierLoads.fingerprint([:a, :b]) == NotifierLoads.fingerprint([:a, :b])
      assert NotifierLoads.fingerprint([]) == NotifierLoads.fingerprint([])
    end

    test "a different statement fingerprints differently" do
      refute NotifierLoads.fingerprint([:a]) == NotifierLoads.fingerprint([:b])
      refute NotifierLoads.fingerprint([]) == NotifierLoads.fingerprint([:a])
    end

    test "a closure's CAPTURED VALUE is part of the fingerprint (closure drift)" do
      # Control first: the same capture from the same code position is stable,
      # so the refute below cannot pass by the fingerprint simply being
      # per-instance noise.
      assert NotifierLoads.fingerprint(calc: adder(1)) ==
               NotifierLoads.fingerprint(calc: adder(1))

      refute NotifierLoads.fingerprint(calc: adder(1)) ==
               NotifierLoads.fingerprint(calc: adder(2))
    end

    test "a closure fingerprints the same from any process (fun_info :pid is excluded)" do
      # `:erlang.fun_info/1` reports the CREATING process. Admission and
      # delivery run in different processes, so including it would fail every
      # legitimate closure-carrying load statement.
      mine = NotifierLoads.fingerprint(calc: adder(1))
      elsewhere = Task.async(fn -> NotifierLoads.fingerprint(calc: adder(1)) end)

      assert Task.await(elsewhere) == mine
    end

    test "an external capture is pinned by module/name/arity" do
      assert NotifierLoads.fingerprint(calc: &String.length/1) ==
               NotifierLoads.fingerprint(calc: &String.length/1)

      refute NotifierLoads.fingerprint(calc: &String.length/1) ==
               NotifierLoads.fingerprint(calc: &String.upcase/1)
    end
  end

  describe "admission binds the statement into the manifest" do
    test "every admitted action carries a binding, notifier-free actions included" do
      assert {:ok, manifest} =
               Destination.manifest(config_for(DestinationFixtures.DeclaredLoadDomain))

      admitted = MapSet.new(manifest.entries, &{&1.resource, &1.action})
      bound = MapSet.new(Map.keys(manifest.notifier_loads))

      assert MapSet.subset?(admitted, bound),
             "admitted actions with no notifier binding: #{inspect(MapSet.to_list(MapSet.difference(admitted, bound)))}"
    end

    test "a load-carrying notifier binds its statement's fingerprint" do
      assert {:ok, manifest} =
               Destination.manifest(config_for(DestinationFixtures.DeclaredLoadDomain))

      assert %{DestinationFixtures.DeclaredLoadNotifier => {statement, closure}} =
               manifest.notifier_loads[{DestinationFixtures.DeclaredLoadRoot, :create}]

      assert statement == NotifierLoads.fingerprint([:some_calculation])

      # The DECLARED ACTION CLOSURE is bound beside the statement: the exact
      # participant declaration this notifier returns for this context.
      assert closure ==
               NotifierLoads.fingerprint(
                 DestinationFixtures.DeclaredLoadNotifier.destination_participants(
                   [],
                   %ParticipantContext{
                     resource: DestinationFixtures.DeclaredLoadRoot,
                     action: :create,
                     kind: :notifier
                   }
                 )
               )
    end

    test "a notifier with NO load/2 binds the EMPTY statement (not a missing key)" do
      # This is what makes an empty-to-non-empty flip detectable at delivery:
      # the absence of a load statement is recorded, never merely unrecorded.
      assert {:ok, manifest} =
               Destination.manifest(config_for(DestinationFixtures.SilentNotifierDomain))

      assert manifest.notifier_loads[{DestinationFixtures.SilentNotifierRoot, :create}] ==
               %{DestinationFixtures.SilentNotifier => {NotifierLoads.fingerprint([]), nil}}
    end

    test "a STATEFUL load/2 is rejected at admission (naming resource + action + notifier)" do
      assert {:error,
              {:destination_notifier_unstable, DestinationFixtures.UnstableLoadRoot, action,
               DestinationFixtures.UnstableLoadNotifier}} =
               Destination.manifest(config_for(DestinationFixtures.UnstableLoadDomain))

      assert is_atom(action)
    end

    test "an UNWRAPPED non-empty load is rejected even when it declares participation" do
      # The declaration alone binds nothing: Ash calls `load/2` again at
      # delivery and only `AshReplicant.Notifier` sits in that call path.
      assert {:error,
              {:destination_notifier_unwrapped, DestinationFixtures.UnwrappedLoadRoot, action,
               DestinationFixtures.UnwrappedLoadNotifier}} =
               Destination.manifest(config_for(DestinationFixtures.UnwrappedLoadDomain))

      assert is_atom(action)

      assert {[:some_calculation], false} =
               AshReplicant.Notifier.probe_load(
                 DestinationFixtures.UnwrappedLoadNotifier,
                 DestinationFixtures.UnwrappedLoadRoot,
                 %{name: :create}
               )

      assert {[:some_calculation], true} =
               AshReplicant.Notifier.probe_load(
                 DestinationFixtures.DeclaredLoadNotifier,
                 DestinationFixtures.DeclaredLoadRoot,
                 %{name: :create}
               )
    end

    test "a retained wrapper marker cannot admit an overridden load/2" do
      assert DestinationFixtures.OverriddenLoadNotifier.module_info(:attributes)
             |> Keyword.get_values(:behaviour)
             |> List.flatten()
             |> Enum.member?(AshReplicant.Notifier)

      assert {[:some_calculation], false} =
               AshReplicant.Notifier.probe_load(
                 DestinationFixtures.OverriddenLoadNotifier,
                 DestinationFixtures.OverriddenLoadRoot,
                 %{name: :create}
               )

      assert {:error,
              {:destination_notifier_unwrapped, DestinationFixtures.OverriddenLoadRoot, action,
               DestinationFixtures.OverriddenLoadNotifier}} =
               Destination.manifest(config_for(DestinationFixtures.OverriddenLoadDomain))

      assert is_atom(action)
    end

    test "an UNDECLARED non-empty load still names the missing declaration first" do
      # Both faults at once (unwrapped AND undeclared): the missing declaration
      # is the more useful diagnostic, so it wins the ordering.
      assert {:error,
              {:destination_notifier_required, DestinationFixtures.LoadRoot, _action,
               DestinationFixtures.LoadNotifier}} =
               Destination.manifest(config_for(DestinationFixtures.LoadDomain))
    end

    test "a RAISING load/2 is still rejected at admission (unchanged)" do
      assert {:error,
              {:destination_notifier_required, DestinationFixtures.RaisingLoadRoot, _action,
               DestinationFixtures.RaisingLoadNotifier}} =
               Destination.manifest(config_for(DestinationFixtures.RaisingLoadDomain))
    end

    test "the generated checkpoint cannot carry a host notifier (the exemption's premise)" do
      # `use AshReplicant.Checkpoint` owns the `use Ash.Resource` call and
      # forwards only domain/data_layer/authorizers, so the sink's checkpoint
      # call sites need no delivery-time verification. If that ever changes,
      # this goes red before the exemption becomes a hole.
      assert AshInfo.notifiers(@checkpoint) == []
    end
  end

  describe "delivery-time verification" do
    setup do
      restore_statement_env()
    end

    test "an unchanged statement verifies", %{key: key} do
      bound = bind(key, [:spy_probe])

      assert :ok = NotifierLoads.verify(bound, @drift_resource, :create)
    end

    test "EMPTY at admission and non-empty at delivery is drift", %{key: key} do
      bound = bind(key, [])
      assert :ok = NotifierLoads.verify(bound, @drift_resource, :create)

      Application.put_env(:ash_replicant, key, [:spy_probe])

      assert {:error, {:invalid_destination_config, :notifier_load_drift}} =
               NotifierLoads.verify(bound, @drift_resource, :create)
    end

    test "a changed STATEMENT is drift", %{key: key} do
      bound = bind(key, [:spy_probe])

      Application.put_env(:ash_replicant, key, [:spy_probe, :another_calculation])

      assert {:error, {:invalid_destination_config, :notifier_load_drift}} =
               NotifierLoads.verify(bound, @drift_resource, :create)
    end

    test "a changed CLOSURE is drift", %{key: key} do
      bound = bind(key, calc: adder(1))
      assert :ok = NotifierLoads.verify(bound, @drift_resource, :create)

      Application.put_env(:ash_replicant, key, calc: adder(2))

      assert {:error, {:invalid_destination_config, :notifier_load_drift}} =
               NotifierLoads.verify(bound, @drift_resource, :create)
    end

    test "the binding rides the manifest digest (the generation revalidation gate)", %{key: key} do
      Application.put_env(:ash_replicant, key, [:spy_probe])

      assert {:ok, admitted} =
               Destination.manifest(config_for(DestinationFixtures.DriftLoadDomain))

      Application.put_env(:ash_replicant, key, [:spy_probe, :smuggled])

      assert {:ok, drifted} =
               Destination.manifest(config_for(DestinationFixtures.DriftLoadDomain))

      refute admitted.notifier_loads == drifted.notifier_loads
      refute admitted.digest == drifted.digest
      refute admitted == drifted
    end

    test "a statement that varies BETWEEN delivery probes is drift" do
      # The stateful fixture flips every call: whatever was admitted, delivery
      # cannot produce a stable answer, so nothing may run.
      resource = DestinationFixtures.UnstableLoadRoot

      bound = %{
        {resource, :create} => %{DestinationFixtures.UnstableLoadNotifier => {<<0>>, nil}}
      }

      assert {:error, {:invalid_destination_config, :notifier_load_drift}} =
               NotifierLoads.verify(bound, resource, :create)
    end

    test "a notifier the binding does not know about is drift", %{key: key} do
      bound = bind(key, [:spy_probe])

      forged =
        Map.update!(bound, {@drift_resource, :create}, fn admitted ->
          Map.put(
            admitted,
            DestinationFixtures.LoadNotifier,
            {NotifierLoads.fingerprint([]), nil}
          )
        end)

      assert {:error, {:invalid_destination_config, :notifier_load_drift}} =
               NotifierLoads.verify(forged, @drift_resource, :create)
    end

    test "an action with NO binding fails closed" do
      assert {:error, {:invalid_destination_config, :notifier_load_unadmitted}} =
               NotifierLoads.verify(%{}, @drift_resource, :create)
    end

    test "a raising load/2 at delivery is a probe fault, never an admission" do
      bound = %{{DestinationFixtures.RaisingLoadRoot, :create} => %{}}

      assert {:error, {:invalid_destination_config, :notifier_load_probe_failed}} =
               NotifierLoads.verify(bound, DestinationFixtures.RaisingLoadRoot, :create)
    end

    test "a no-load notifier and a notifier-free resource are unchanged" do
      silent = DestinationFixtures.SilentNotifierRoot

      bound = %{
        {silent, :create} => %{
          DestinationFixtures.SilentNotifier => {NotifierLoads.fingerprint([]), nil}
        }
      }

      assert :ok = NotifierLoads.verify(bound, silent, :create)

      read = AshInfo.primary_action!(@checkpoint, :read).name
      assert {:ok, %{}} = NotifierLoads.bindings(@checkpoint, read)
      assert :ok = NotifierLoads.verify(%{{@checkpoint, read} => %{}}, @checkpoint, read)
    end

    test "verify/3 accepts the manifest itself" do
      assert {:ok, manifest} =
               Destination.manifest(config_for(DestinationFixtures.DeclaredLoadDomain))

      assert :ok = NotifierLoads.verify(manifest, DestinationFixtures.DeclaredLoadRoot, :create)
    end
  end

  describe "the verified wrapper (the in-band layer Ash itself calls)" do
    alias DestinationFixtures.ClosureDriftNotifier
    alias DestinationFixtures.ClosureDriftOrder

    setup do
      key = ClosureDriftNotifier.closure_key()
      previous = Application.get_env(:ash_replicant, key, :unset)

      on_exit(fn ->
        case previous do
          :unset -> Application.delete_env(:ash_replicant, key)
          value -> Application.put_env(:ash_replicant, key, value)
        end
      end)

      {:ok, manifest} = Destination.manifest(config_for(DestinationFixtures.ClosureDriftDomain))
      {:ok, key: key, manifest: manifest}
    end

    test "outside a sink delivery it is an ORDINARY Ash notifier (the host's own writes)" do
      # No manifest bound: the sink is not running this transaction, so the
      # wrapper hands Ash the statement unverified — wrapping must not change
      # how the host's own application behaves.
      refute Context.admitted_manifest()

      assert [:spy_probe] =
               ClosureDriftNotifier.load(
                 ClosureDriftOrder,
                 AshInfo.action(ClosureDriftOrder, :create)
               )
    end

    test "inside a delivery it returns THAT EXACT statement when it matches", %{
      manifest: manifest
    } do
      Context.with_admitted_manifest(%{destination_manifest: manifest}, fn ->
        assert Context.admitted_manifest() == manifest

        assert [:spy_probe] =
                 ClosureDriftNotifier.load(
                   ClosureDriftOrder,
                   AshInfo.action(ClosureDriftOrder, :create)
                 )
      end)
    end

    test "a widened DECLARED ACTION CLOSURE halts inside the delivery", %{
      key: key,
      manifest: manifest
    } do
      # The statement is untouched; only the participant declaration widens.
      # Those extra reads were never walked, so they may not run.
      Application.put_env(
        :ash_replicant,
        key,
        {:ok,
         {:actions,
          [
            %ActionRef{
              resource: ClosureDriftOrder,
              action: :read
            }
          ]}}
      )

      error =
        assert_raise AshReplicant.Error, fn ->
          Context.with_admitted_manifest(%{destination_manifest: manifest}, fn ->
            ClosureDriftNotifier.load(
              ClosureDriftOrder,
              AshInfo.action(ClosureDriftOrder, :create)
            )
          end)
        end

      assert error.reason == {:invalid_destination_config, :notifier_load_drift}
      assert error.op == :notifier_load
    end

    test "the binding is removed on the way out, so a later host write is not judged", %{
      manifest: manifest
    } do
      Context.with_admitted_manifest(%{destination_manifest: manifest}, fn -> :ok end)
      refute Context.admitted_manifest()
    end

    test "a config with no manifest binds nothing" do
      Context.with_admitted_manifest(%{repo: AshReplicant.TestRepo}, fn ->
        refute Context.admitted_manifest()
      end)
    end
  end

  describe "the sink's delivery guard" do
    setup do
      restore_statement_env()
    end

    test "raises a value-free structural reason on drift", %{key: key} do
      Application.put_env(:ash_replicant, key, [:spy_probe])

      assert {:ok, manifest} =
               Destination.manifest(config_for(DestinationFixtures.DriftLoadDomain))

      Application.put_env(:ash_replicant, key, [:spy_probe, :smuggled])

      error =
        assert_raise AshReplicant.Error, fn ->
          Context.verify_notifier_loads!(
            %{destination_manifest: manifest},
            @drift_resource,
            :create,
            :upsert
          )
        end

      assert error.reason == {:invalid_destination_config, :notifier_load_drift}
      assert error.resource == @drift_resource
      assert error.op == :upsert
      refute Exception.message(error) =~ "smuggled"
    end

    test "the drift reasons survive the sink's scrub (operators can still branch)" do
      for tag <- [:notifier_load_drift, :notifier_load_unadmitted, :notifier_load_probe_failed] do
        assert AshReplicant.Error.scrub(
                 %AshReplicant.Error{reason: {:invalid_destination_config, tag}},
                 @drift_resource,
                 :upsert
               ).reason == {:invalid_destination_config, tag}
      end
    end

    test "a bare unit config with no manifest is inert (the onetime-preflight precedent)" do
      assert :ok =
               Context.verify_notifier_loads!(
                 %{repo: AshReplicant.TestRepo},
                 @drift_resource,
                 :create,
                 :upsert
               )
    end

    test "every delivery entry point binds the admitted manifest for the wrapper (live source pin)" do
      # `load/2` gets only (resource, action) from Ash, so the wrapper can only
      # reach the manifest through the process-scoped binding. Each entry point
      # that drives a host action must establish it, or the wrapper silently
      # degrades to an ordinary unverified notifier.
      for path <- [
            "lib/ash_replicant/apply.ex",
            "lib/ash_replicant/append.ex",
            "lib/ash_replicant/sink/impl.ex",
            "lib/ash_replicant/messages.ex"
          ] do
        assert path |> File.read!() |> String.contains?("with_admitted_manifest("),
               "#{path} drives a host action without binding the admitted manifest"
      end
    end

    test "every sink-driven HOST action call site is guarded (live source pin)" do
      # The live half of this suite drives the upsert, destroy and snapshot
      # sites end-to-end. The SCD2 close/open and message-route sites share
      # the same guard; this pin is what keeps them wired — deleting a call
      # turns it red. Counts are call sites, not mentions: the guard name
      # appears nowhere else in these modules.
      for {path, expected} <- [
            {"lib/ash_replicant/apply.ex", 2},
            {"lib/ash_replicant/append.ex", 1},
            {"lib/ash_replicant/apply/scd2.ex", 2},
            {"lib/ash_replicant/sink/impl.ex", 1},
            {"lib/ash_replicant/messages.ex", 1}
          ] do
        calls =
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.count(&String.contains?(&1, "verify_notifier_loads!("))

        assert calls == expected,
               "#{path} carries #{calls} notifier-load guards, expected #{expected}"
      end
    end
  end
end
