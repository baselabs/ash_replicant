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

  test "renders the current checkpoint snapshot from the locked AshPostgres contract" do
    generated =
      AshPostgres.MigrationGenerator.get_snapshots(
        AshReplicant.Test.Checkpoint,
        [AshReplicant.Test.Checkpoint]
      )
      |> List.first()

    snapshot = Upgrade.render_checkpoint_snapshot(AshReplicant.TestRepo)
    decoded = Jason.decode!(snapshot)

    assert decoded["hash"] == generated.hash
    assert decoded["repo"] == "Elixir.AshReplicant.TestRepo"

    assert Enum.map(decoded["attributes"], & &1["source"]) ==
             ~w(source_system_id source_database slot_name source_timeline publication_contract publication_fingerprint commit_lsn snapshot_progress snapshot_state origin_floor inserted_at updated_at)

    assert [%{"keys" => keys}] = decoded["identities"]

    assert Enum.map(keys, & &1["value"]) ==
             ~w(source_system_id source_database slot_name)
  end
end
