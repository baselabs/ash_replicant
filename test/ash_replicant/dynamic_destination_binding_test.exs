defmodule AshReplicant.DynamicDestinationBindingTest do
  @moduledoc """
  Cross-vendor REL02 finding (codex peer, CONFIRMED): the tombstone and
  horizon paths must bind the ADMITTED dynamic repo — the runtime delivery
  config pins `data_layer_context: %{repo: <admitted>}`, but the O02/O03
  control-plane writers were reconstructing the static sink config (status)
  or passing the layer map unwrapped (horizon), so on a host running an
  owned dynamic instance the durable tombstone, the digest-key witness, and
  the recovery-horizon resume gate read/write the WRONG database.

  The oracle: a second, OWNED instance of the test repo against a DEDICATED
  database on the same server. Which instance an Ash call routed to is
  observable by which database the row lands in — invisible when every
  instance shares one database. The caller's process binding is UN-set when
  the under-test function runs (the pipeline's processes carry the binding
  in their RUNTIME CONFIG, not their pdict — that is exactly the surface
  under test).
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshReplicant.{Error, Horizon, Messages, Status}
  alias AshReplicant.Test.{AdmittedGeneration, DynamicDestination}
  alias AshReplicant.TestRepo

  defmodule DynSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "dyn_binding_slot"
  end

  @dyn :dyn_binding_instance
  @slot "dyn_binding_slot"
  @identity %{system_identifier: "741852963", database: "postgres"}

  setup do
    {:ok, _} = DynamicDestination.start!(@dyn)

    DynamicDestination.query!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [
      @slot
    ])

    # config/test.exs sets BOTH key families globally — capture and RESTORE
    # (a delete would starve every later census's classify_witness).
    digest_baseline = Application.get_env(:ash_replicant, :message_digest_keys)
    provenance_baseline = Application.get_env(:ash_replicant, :horizon_provenance_keys)

    on_exit(fn ->
      restore_env(:message_digest_keys, digest_baseline)
      restore_env(:horizon_provenance_keys, provenance_baseline)
      AshReplicant.stop_supervised(@slot)
      :persistent_term.erase({AshReplicant, @slot})

      if Process.whereis(@dyn) do
        try do
          GenServer.stop(@dyn)
        catch
          _, _ -> :ok
        end
      end

      drop_source_slot!()
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:ash_replicant, key)
  defp restore_env(key, value), do: Application.put_env(:ash_replicant, key, value)

  defp dyn_row!(columns) do
    %{rows: rows} =
      DynamicDestination.query!(
        "SELECT #{columns} FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [@slot]
      )

    rows
  end

  defp seed_dyn_checkpoint! do
    DynamicDestination.query!(
      "INSERT INTO ash_replicant_checkpoints (source_system_id, source_database, slot_name, commit_lsn) " <>
        "VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
      [@identity.system_identifier, @identity.database, @slot, 100]
    )

    :ok
  end

  defp admitted_generation! do
    # The caller's binding is set ONLY for the admission (the generation
    # captures it — exactly what a pipeline activation does); the under-test
    # calls then run with the process UN-bound, carrying the binding only in
    # the generation/runtime config.
    previous = TestRepo.put_dynamic_repo(@dyn)

    generation =
      AdmittedGeneration.put!(DynSink, source_identity: @identity, publication: ["dyn_pub"])

    TestRepo.put_dynamic_repo(previous)
    assert generation.dynamic_repo == @dyn
    generation
  end

  defp source_connection do
    uri =
      "ASH_REPLICANT_TEST_URL"
      |> System.get_env("postgres://postgres@localhost:5599")
      |> URI.parse()

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: uri.userinfo || "postgres",
      database: "postgres"
    ]
  end

  defp drop_source_slot! do
    {:ok, conn} = Postgrex.start_link(source_connection())

    try do
      Postgrex.query!(conn, "SELECT pg_drop_replication_slot($1::text)", [@slot])
    rescue
      _ -> :ok
    after
      GenServer.stop(conn)
    end

    :ok
  end

  # The preflight cap only gates a ROUTED sink (a route-less sink has no
  # digest-key set to admit) — the messages fixtures' routed sink shape.
  defmodule RoutedSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Messages.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "dyn_routed_slot",
      message_routes: [{"outbox", AshReplicant.Test.Messages.Outbox, :record}],
      recovery_horizon: {24, :hour}
  end

  @tag :integration
  test "a terminal tombstone lands on the admitted dynamic repo's checkpoint row" do
    seed_dyn_checkpoint!()
    generation = admitted_generation!()
    assert generation.dynamic_repo == @dyn
    refute TestRepo.get_dynamic_repo() == @dyn

    halted = {:error, Error.exception(reason: :sink_failed)}
    ^halted = Status.record_callback_error(@slot, halted)

    assert [["sink_failed"]] = dyn_row!("terminal_cause")
    assert [["halt"]] = dyn_row!("terminal_class")

    # the identity actually recorded came from the live generation
    expected_database = @identity.database
    assert [[^expected_database]] = dyn_row!("source_database")
  end

  @tag :integration
  test "the digest-key witness rebinds on the admitted dynamic repo's checkpoint row" do
    seed_dyn_checkpoint!()
    generation = admitted_generation!()

    Application.put_env(:ash_replicant, :message_digest_keys, [
      {1, :crypto.strong_rand_bytes(16)}
    ])

    Application.put_env(:ash_replicant, :horizon_provenance_keys, [
      {1, :crypto.strong_rand_bytes(16)}
    ])

    runtime =
      Map.merge(generation.sink_config, %{
        source_identity: generation.source_identity,
        dynamic_repo: generation.dynamic_repo
      })

    assert :ok = Horizon.rebind_key_state(runtime)
    assert [[row]] = dyn_row!("digest_key_state")
    assert is_binary(row) and byte_size(row) > 0
  end

  @tag :integration
  test "the recovery-horizon resume gate reads the admitted dynamic repo's terminal record" do
    seed_dyn_checkpoint!()

    halted_at = DateTime.add(DateTime.utc_now(), -7_200, :second)

    DynamicDestination.query!(
      "UPDATE ash_replicant_checkpoints SET terminal_at = $1, terminal_cause = $2, terminal_class = $3 WHERE slot_name = $4",
      [halted_at, "sink_failed", "halt", @slot]
    )

    # A real, healthy slot on the source server so the resume classification
    # reaches the retention comparison (absent/lost/unreachable all defer).
    {:ok, bootstrap} = Postgrex.start_link(source_connection())

    try do
      Postgrex.query!(
        bootstrap,
        "SELECT pg_create_logical_replication_slot($1::text, 'pgoutput'::text)",
        [@slot]
      )
    rescue
      # already exists from a prior run — the seed is idempotent
      error in Postgrex.Error ->
        unless error.postgres.code == :duplicate_object, do: reraise(error, __STACKTRACE__)
    after
      GenServer.stop(bootstrap)
    end

    generation = admitted_generation!()

    manifest = %AshReplicant.Destination.Manifest{
      repo: AshReplicant.TestRepo,
      digest: :erlang.md5(:erlang.term_to_binary(:dyn_fixture)),
      onetime_prefixes_by_action: %{},
      notifier_loads: [],
      entries: [
        %AshReplicant.Destination.Entry{
          role: :message,
          resource: AshReplicant.Test.Checkpoint,
          action: :create,
          source: AshReplicant.Test.Checkpoint,
          tenant_mode: :inherit,
          replay_identity: nil,
          protection: %{retention: 3_600}
        }
      ]
    }

    assert {:error, %Error{reason: :retention_horizon_crossed}} =
             Horizon.preflight_resume(
               source_connection(),
               @slot,
               Map.merge(generation.sink_config, %{
                 source_identity: generation.source_identity,
                 dynamic_repo: generation.dynamic_repo
               }),
               @identity,
               manifest
             )
  end

  test "a digest-key set larger than the witness envelope cap is refused at preflight" do
    keys = for v <- 1..17, do: {v, :crypto.strong_rand_bytes(16)}
    baseline = Application.get_env(:ash_replicant, :message_digest_keys)
    Application.put_env(:ash_replicant, :message_digest_keys, keys)

    on_exit(fn ->
      restore_env(:message_digest_keys, baseline)
    end)

    config = RoutedSink.__ash_replicant_config__()

    assert {:error, %Error{reason: :config_invalid}} =
             Messages.preflight_digest(config)
  end
end
