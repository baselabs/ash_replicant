defmodule AshReplicant.UpgradeTest do
  use ExUnit.Case, async: false

  alias AshReplicant.Upgrade
  alias AshReplicant.Upgrade.Error

  @binding_json ~s({"sink":"MyApp.LegacySink","pipeline":"MyApp.Replicant.Pipeline","source_system_id":"source-system","source_database":"source-database"})

  test "accepts exactly the published 0.4.0 to 1.0.0 transition" do
    assert :ok = Upgrade.validate_versions("0.4.0", "1.0.0")

    for {from, to} <- [
          {"0.4", "1.0.0"},
          {"0.4.0", "1.0.1"},
          {"0.4.0-rc.1", "1.0.0"},
          {"1.0.0", "0.4.0"}
        ] do
      assert {:error, %Error{reason: :version_unsupported}} =
               Upgrade.validate_versions(from, to)
    end
  end

  test "parses repeatable JSON bindings without creating arbitrary atoms" do
    assert {:ok, _binding} = Upgrade.parse_binding(@binding_json, [MyApp.LegacySink])
    before_count = :erlang.system_info(:atom_count)

    assert {:ok,
            %{
              sink: MyApp.LegacySink,
              pipeline: "MyApp.Replicant.Pipeline",
              source_system_id: "source-system",
              source_database: "source-database"
            }} = Upgrade.parse_binding(@binding_json, [MyApp.LegacySink])

    assert :erlang.system_info(:atom_count) == before_count
  end

  test "binding refusals are value-free" do
    secret = "postgres://operator:do-not-print@example.invalid/source"

    assert {:error, %Error{} = error} =
             Upgrade.parse_binding(
               Jason.encode!(%{
                 sink: "Unknown.SecretSink",
                 source_system_id: secret,
                 source_database: secret
               }),
               [MyApp.LegacySink]
             )

    refute Exception.message(error) =~ secret
    refute Exception.message(error) =~ "Unknown.SecretSink"
  end

  test "rejects a malformed generated pipeline target without interning it" do
    pipeline_name = "not-a-module-#{System.unique_integer([:positive])}"

    encoded =
      Jason.encode!(%{
        sink: "MyApp.LegacySink",
        pipeline: pipeline_name,
        source_system_id: "source-system",
        source_database: "source-database"
      })

    assert_raise ArgumentError, fn -> String.to_existing_atom(pipeline_name) end

    assert {:error, %Error{reason: :binding_invalid}} =
             Upgrade.parse_binding(encoded, [MyApp.LegacySink])

    assert_raise ArgumentError, fn -> String.to_existing_atom(pipeline_name) end
  end

  test "renders a guarded reversible migration and a redacted report" do
    plan = %Upgrade.Plan{
      repo: MyApp.Repo,
      prefix: "public",
      destination_database: "destination-secret",
      bindings: [
        %{
          sink: MyApp.LegacySink,
          slot_name: "slot-secret",
          source_system_id: "system-secret",
          source_database: "source-secret"
        }
      ]
    }

    source = Upgrade.render_migration(plan, MyApp.Repo.Migrations.UpgradeAshReplicant040To100)

    assert source =~ "AshReplicant.Upgrade.Checkpoint.up"
    assert source =~ "AshReplicant.Upgrade.Checkpoint.down"
    assert source =~ "ASH_REPLICANT_PIPELINES_STOPPED"
    assert source =~ "slot-secret"
    assert {:ok, _ast} = Code.string_to_quoted(source)

    report = Upgrade.report(plan, :legacy_ready)
    assert report =~ "bindings=1"

    for secret <- ["destination-secret", "slot-secret", "system-secret", "source-secret"] do
      refute report =~ secret
    end
  end

  test "chooses the next deterministic migration number" do
    paths = [
      "priv/repo/migrations/20260101000000_first.exs",
      "priv/repo/migrations/20260101000004_later.exs",
      "README.md"
    ]

    assert Upgrade.next_migration_number(paths) == "20260101000005"
  end

  test "the rendered snapshot follows the host's AshPostgres snapshot shape" do
    base = %{table: "ash_replicant_checkpoints"}

    refute Map.has_key?(Upgrade.put_snapshot_shape(base, "2.13.1"), :temporal)
    assert %{temporal: nil} = Upgrade.put_snapshot_shape(base, "2.14.0")
    assert %{temporal: nil} = Upgrade.put_snapshot_shape(base, "2.14.5")
  end

  test "renders the checkpoint snapshot file the installed AshPostgres generator writes" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ash_replicant_upgrade_snapshot_#{System.unique_integer([:positive])}"
      )

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(shell)
      File.rm_rf!(root)
    end)

    AshPostgres.MigrationGenerator.generate([AshReplicant.Test.Domain],
      snapshot_path: Path.join(root, "snapshots"),
      migration_path: Path.join(root, "migrations"),
      tenant_migration_path: Path.join(root, "tenant_migrations"),
      snapshots_only: true,
      auto_name: true,
      format: false,
      quiet: true,
      no_shell?: true
    )

    assert [path] =
             root
             |> Path.join("snapshots/*/ash_replicant_checkpoints/*.json")
             |> Path.wildcard()

    written = File.read!(path)
    snapshot = Upgrade.render_checkpoint_snapshot(AshReplicant.TestRepo)
    decoded = Jason.decode!(snapshot)

    assert decoded == Jason.decode!(written)
    assert Upgrade.current_checkpoint_snapshot?(written, AshReplicant.TestRepo)
    assert decoded["repo"] == "Elixir.AshReplicant.TestRepo"

    assert Enum.map(decoded["attributes"], & &1["source"]) ==
             ~w(source_system_id source_database slot_name source_timeline publication_contract publication_fingerprint commit_lsn snapshot_progress snapshot_state origin_floor terminal_cause terminal_class terminal_at digest_key_state inserted_at updated_at)

    assert [%{"keys" => keys}] = decoded["identities"]

    assert Enum.map(keys, & &1["value"]) ==
             ~w(source_system_id source_database slot_name)
  end

  test "a current checkpoint snapshot stays current across AshPostgres's 2.16 hash change" do
    before_2_16 = Upgrade.render_checkpoint_snapshot(AshReplicant.TestRepo, "2.15.2")
    since_2_16 = Upgrade.render_checkpoint_snapshot(AshReplicant.TestRepo, "2.16.0")

    refute Jason.decode!(before_2_16)["hash"] == Jason.decode!(since_2_16)["hash"]

    assert Map.delete(Jason.decode!(before_2_16), "hash") ==
             Map.delete(Jason.decode!(since_2_16), "hash")

    assert Upgrade.current_checkpoint_snapshot?(before_2_16, AshReplicant.TestRepo)
    assert Upgrade.current_checkpoint_snapshot?(since_2_16, AshReplicant.TestRepo)
  end

  test "a checkpoint snapshot missing keys AshPostgres defaults on load is current" do
    snapshot =
      AshReplicant.TestRepo
      |> Upgrade.render_checkpoint_snapshot()
      |> Jason.decode!()
      |> Map.delete("temporal")
      |> Map.update!("attributes", fn attributes ->
        Enum.map(attributes, &Map.drop(&1, ["precision", "scale"]))
      end)

    assert Upgrade.current_checkpoint_snapshot?(Jason.encode!(snapshot), AshReplicant.TestRepo)
  end

  test "a checkpoint snapshot with other content, or without a snapshot hash, is not current" do
    rendered = AshReplicant.TestRepo |> Upgrade.render_checkpoint_snapshot() |> Jason.decode!()

    nullable_slot =
      Map.update!(rendered, "attributes", fn attributes ->
        Enum.map(attributes, fn
          %{"source" => "slot_name"} = attribute -> %{attribute | "allow_nil?" => true}
          attribute -> attribute
        end)
      end)

    for snapshot <- [
          nullable_slot,
          Map.put(rendered, "repo", "Elixir.MyApp.OtherRepo"),
          Map.put(rendered, "hash", String.downcase(rendered["hash"])),
          Map.delete(rendered, "hash"),
          [rendered]
        ] do
      content = Jason.encode!(snapshot)

      refute Upgrade.current_checkpoint_snapshot?(content, AshReplicant.TestRepo)
      refute Upgrade.legacy_checkpoint_snapshot?(content, AshReplicant.TestRepo)
    end
  end
end
