defmodule AshReplicant.NotifierLoadBindingIntegrationTest do
  @moduledoc """
  Issue #3, live half: a notifier `load/2` whose statement drifts away from
  the admitted binding halts the delivery BEFORE any query runs.

  The unit suite proves the binding and the comparison. This suite proves the
  consequence on a real Postgres: the mirror row is never written, the
  notifier's dependency pre-load never executes, and an UNDRIFTED load still
  delivers with its pre-load running inside the destination transaction.
  """
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Apply
  alias AshReplicant.Sink.Impl
  alias AshReplicant.Test.{AdmittedGeneration, Marquee}

  alias AshReplicant.Test.DestinationFixtures.{
    DriftLoadNotifier,
    DriftLoadOrder,
    InbandDriftOrder,
    PreloadFlipNotifier
  }

  @slot "notifier_drift_slot"
  @ids ["nlb-stable", "nlb-drift", "nlb-empty", "nlb-destroy", "nlb-snapshot", "nlb-inband"]

  setup do
    Application.put_env(:ash_replicant, :notifier_probe_pid, self())
    on_exit(fn -> Application.delete_env(:ash_replicant, :notifier_probe_pid) end)

    key = DriftLoadNotifier.statement_key()
    previous = Application.get_env(:ash_replicant, key, :unset)

    on_exit(fn ->
      case previous do
        :unset -> Application.delete_env(:ash_replicant, key)
        value -> Application.put_env(:ash_replicant, key, value)
      end
    end)

    on_exit(fn ->
      Marquee.q!("DELETE FROM orders WHERE id = ANY($1)", [@ids])
      :persistent_term.erase({AshReplicant, @slot})
      Impl.clear_snapshot_ordinals(@slot)
    end)

    {:ok, key: key}
  end

  # Admit a generation with `statement` in force, then hand back the delivery
  # config the sink would run with.
  defp admit!(key, statement) do
    Application.put_env(:ash_replicant, key, statement)
    generation = AdmittedGeneration.put!(DriftLoadSink)

    config = %{
      resolver_index: %{{"public", "orders"} => DriftLoadOrder},
      repo: AshReplicant.TestRepo,
      authorize?: false,
      destination_manifest: generation.manifest
    }

    {generation, config}
  end

  defp change(op, record, old_record \\ nil) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: "orders",
      record: record,
      old_record: old_record,
      unchanged: []
    }
  end

  defp count(id) do
    Marquee.q!("SELECT count(*) FROM orders WHERE id = $1", [id]).rows |> hd() |> hd()
  end

  test "an admitted STABLE load delivers, and its pre-load runs inside the transaction",
       %{key: key} do
    {_generation, config} = admit!(key, [:spy_probe])

    assert :ok =
             Apply.apply_change(config, change(:insert, %{"id" => "nlb-stable", "note" => "n"}))

    assert count("nlb-stable") == 1
    # The dependency pre-load executed on the mirrored write — the read the
    # manifest admitted, inside the sink's delivery path.
    assert_receive {:spy_calc_ran, _}, 2_000
  end

  test "a DRIFTED load halts the upsert before the row is written", %{key: key} do
    {_generation, config} = admit!(key, [:spy_probe])

    Application.put_env(:ash_replicant, key, [:spy_probe, :other_probe])

    error =
      assert_raise AshReplicant.Error, fn ->
        Apply.apply_change(config, change(:insert, %{"id" => "nlb-drift", "note" => "n"}))
      end

    assert error.reason == {:invalid_destination_config, :notifier_load_drift}
    assert error.op == :upsert

    # BEFORE a query: no mirror row, and NEITHER leg of the drifted load ran —
    # not the admitted one, and not the calculation the drift smuggled in.
    assert count("nlb-drift") == 0
    refute_receive {:spy_calc_ran, _}, 300
    refute_receive {:other_calc_ran, _}, 300
  end

  test "an EMPTY admitted load that turns non-empty halts before the row is written",
       %{key: key} do
    {_generation, config} = admit!(key, [])

    # Control: while the load stays empty the mirror writes normally and no
    # dependency pre-load runs.
    assert :ok =
             Apply.apply_change(config, change(:insert, %{"id" => "nlb-empty", "note" => "n"}))

    assert count("nlb-empty") == 1
    refute_receive {:spy_calc_ran, _}, 300

    Application.put_env(:ash_replicant, key, [:spy_probe])

    error =
      assert_raise AshReplicant.Error, fn ->
        Apply.apply_change(config, change(:insert, %{"id" => "nlb-empty", "note" => "changed"}))
      end

    assert error.reason == {:invalid_destination_config, :notifier_load_drift}
    assert Marquee.q!("SELECT note FROM orders WHERE id = 'nlb-empty'").rows == [["n"]]
    refute_receive {:spy_calc_ran, _}, 300
  end

  test "a DRIFTED load halts the mirrored DELETE before the row is removed", %{key: key} do
    {_generation, config} = admit!(key, [:spy_probe])

    assert :ok =
             Apply.apply_change(config, change(:insert, %{"id" => "nlb-destroy", "note" => "n"}))

    assert count("nlb-destroy") == 1

    Application.put_env(:ash_replicant, key, [:spy_probe, :other_probe])

    error =
      assert_raise AshReplicant.Error, fn ->
        Apply.apply_change(config, change(:delete, nil, %{"id" => "nlb-destroy"}))
      end

    assert error.reason == {:invalid_destination_config, :notifier_load_drift}
    assert error.op == :destroy
    assert count("nlb-destroy") == 1
  end

  test "a DRIFTED load halts the snapshot bulk_create before any row lands", %{key: key} do
    {generation, _config} = admit!(key, [:spy_probe])

    identity = %Replicant.SessionIdentity{
      system_identifier: generation.source_identity.system_identifier,
      timeline_id: 1,
      current_lsn: 0,
      database: generation.source_identity.database
    }

    DriftLoadSink.handle_session_identity(identity, %{
      slot_name: @slot,
      publication: generation.publication
    })

    Application.put_env(:ash_replicant, key, [:spy_probe, :other_probe])

    changes = [
      %Replicant.Change{
        op: :snapshot,
        schema: "public",
        table: "orders",
        record: %{"id" => "nlb-snapshot", "note" => "n"}
      }
    ]

    # The binding rides the manifest digest, so drift present at CALLBACK
    # ENTRY is rejected by the generation revalidation before delivery starts
    # — the coarse outer layer. The per-action guard behind it is what catches
    # drift that appears mid-delivery (below).
    assert {:error, %AshReplicant.Error{reason: :config_invalid, op: :callback}} =
             DriftLoadSink.handle_snapshot(changes, %{
               table: "public.orders",
               first_for_table?: true,
               snapshot_lsn: 10
             })

    assert count("nlb-snapshot") == 0
    refute_receive {:spy_calc_ran, _}, 300
    refute_receive {:other_calc_ran, _}, 300
  end

  test "drift that appears MID-DELIVERY is caught before the next change is written",
       %{key: key} do
    # The window the generation gate cannot see: the manifest was valid at
    # callback entry, and the statement moves while the delivery is already
    # running (here the admitted pre-load itself moves it). The per-action
    # guard is the only thing standing between that and an undeclared read.
    {_generation, config} = admit!(key, [:spy_probe])
    Application.put_env(:ash_replicant, :notifier_load_flip_to, [:spy_probe, :other_probe])
    on_exit(fn -> Application.delete_env(:ash_replicant, :notifier_load_flip_to) end)

    assert :ok =
             Apply.apply_change(config, change(:insert, %{"id" => "nlb-stable", "note" => "n"}))

    assert_receive {:spy_calc_ran, _}, 2_000

    error =
      assert_raise AshReplicant.Error, fn ->
        Apply.apply_change(config, change(:insert, %{"id" => "nlb-drift", "note" => "n"}))
      end

    assert error.reason == {:invalid_destination_config, :notifier_load_drift}
    assert count("nlb-drift") == 0
    refute_receive {:other_calc_ran, _}, 300
  end

  test "drift landing INSIDE Ash's own derivation is halted by the wrapper, and rolls back",
       %{key: key} do
    # The last window: the sink's check already passed, and a sibling
    # notifier's `preload/2` moves the statement while Ash is still building
    # the load query. Only the wrapper is in that call path. This also proves
    # Ash does not swallow the wrapper's halt into an error result — the
    # exception has to reach the sink's transaction and roll it back.
    Application.put_env(:ash_replicant, key, [:spy_probe])
    generation = AdmittedGeneration.put!(InbandDriftSink)

    config = %{
      resolver_index: %{{"public", "orders"} => InbandDriftOrder},
      repo: AshReplicant.TestRepo,
      authorize?: false,
      destination_manifest: generation.manifest
    }

    on_exit(fn ->
      Application.delete_env(:ash_replicant, PreloadFlipNotifier.flip_key())
      :persistent_term.erase({AshReplicant, "notifier_inband_drift_slot"})
    end)

    Application.put_env(
      :ash_replicant,
      PreloadFlipNotifier.flip_key(),
      [:spy_probe, :other_probe]
    )

    assert_raise AshReplicant.Error, fn ->
      AshReplicant.TestRepo.transaction(fn ->
        Apply.apply_change(config, change(:insert, %{"id" => "nlb-inband", "note" => "n"}))
      end)
    end

    # The undeclared read never ran, and the write it rode with is gone.
    refute_receive {:other_calc_ran, _}, 300
    assert count("nlb-inband") == 0
  end
end
