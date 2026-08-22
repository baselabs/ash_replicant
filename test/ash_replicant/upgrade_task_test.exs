defmodule AshReplicant.UpgradeTaskTest.CustomSnapshotRepo do
  use AshPostgres.Repo,
    otp_app: :ash_replicant,
    warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule AshReplicant.UpgradeTaskTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  alias Mix.Tasks.AshReplicant.Upgrade, as: Task

  @mix_exs """
  defmodule MyApp.MixProject do
    use Mix.Project

    def project, do: [app: :my_app, version: "0.1.0", deps: []]
    def application, do: [extra_applications: [:logger], mod: {MyApp.Application, []}]
  end
  """

  @repo """
  defmodule MyApp.Repo do
    use AshPostgres.Repo, otp_app: :my_app
  end
  """

  @sink """
  defmodule MyApp.LegacySink do
    use AshReplicant.Sink,
      repo: MyApp.Repo,
      domains: [MyApp.Domain],
      checkpoint_resource: MyApp.Checkpoint,
      slot_name: "legacy_slot",
      apply_ledger: :legacy_apply_ledger
  end
  """

  @application """
  defmodule MyApp.Application do
    use Application

    def start(_type, _args) do
      children = [
        MyApp.Repo,
        {AshReplicant,
         sink: MyApp.LegacySink,
         connection: [hostname: "destination.invalid", password: "connection-secret"],
         publication: "legacy_publication",
         go_forward_only: true,
         snapshot: false}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
    end
  end
  """

  @dynamic_application """
  defmodule MyApp.Application do
    use Application

    def start(_type, _args) do
      children = [
        MyApp.Repo,
        {AshReplicant, Application.fetch_env!(:my_app, :replicant)}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
    end
  end
  """

  @binding ~s({"sink":"MyApp.LegacySink","pipeline":"MyApp.Replicant.Pipeline","source_system_id":"source-system","source_database":"source-database"})

  defp project(application \\ @application, include_snapshot? \\ true) do
    files = %{
      "mix.exs" => @mix_exs,
      "lib/my_app/repo.ex" => @repo,
      "lib/my_app/legacy_sink.ex" => @sink,
      "lib/my_app/application.ex" => application,
      "config/config.exs" => "import Config\n",
      "priv/repo/migrations/20260101000000_install.exs" => "# existing\n"
    }

    files =
      if include_snapshot? do
        Map.put(
          files,
          "priv/resource_snapshots/repo/ash_replicant_checkpoints/20260101000000.json",
          legacy_snapshot()
        )
      else
        files
      end

    test_project(
      app_name: :my_app,
      files: files
    )
  end

  defp legacy_snapshot(repo \\ MyApp.Repo) do
    Jason.encode!(
      %{
        attributes: [
          %{
            allow_nil?: false,
            default: "nil",
            generated?: false,
            primary_key?: true,
            references: nil,
            size: nil,
            source: "slot_name",
            type: "text"
          },
          %{
            allow_nil?: false,
            default: "nil",
            generated?: false,
            primary_key?: false,
            references: nil,
            size: nil,
            source: "commit_lsn",
            type: "bigint"
          }
        ],
        base_filter: nil,
        check_constraints: [],
        create_table_options: nil,
        custom_indexes: [],
        custom_statements: [],
        has_create_action: true,
        hash: String.duplicate("A", 64),
        identities: [
          %{
            all_tenants?: false,
            base_filter: nil,
            index_name: "ash_replicant_checkpoints_unique_slot_index",
            keys: [%{type: "atom", value: "slot_name"}],
            name: "unique_slot",
            nils_distinct?: true,
            where: nil
          }
        ],
        multitenancy: %{attribute: nil, global: nil, strategy: nil},
        repo: Atom.to_string(repo),
        schema: nil,
        table: "ash_replicant_checkpoints"
      },
      pretty: true
    )
  end

  defp upgrade(igniter, extra \\ [], repo \\ "MyApp.Repo") do
    argv =
      [
        "0.4.0",
        "1.0.0",
        "--repo",
        repo,
        "--destination-database",
        "destination_db",
        "--binding",
        @binding
      ] ++ extra

    Igniter.compose_task(igniter, Task, argv)
  end

  defp content(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  test "converts a static 0.4 child and writes the guarded reversible migration in memory" do
    igniter = project() |> upgrade() |> apply_igniter!()

    sink = content(igniter, "lib/my_app/legacy_sink.ex")
    refute sink =~ "apply_ledger"
    assert sink =~ ~s(slot_name: "legacy_slot")

    migration =
      "priv/repo/migrations/20260101000001_upgrade_ash_replicant_0_4_0_to_1_0_0.exs"

    assert Igniter.exists?(igniter, migration)
    source = content(igniter, migration)
    assert source =~ "AshReplicant.Upgrade.Checkpoint.up"
    assert source =~ "AshReplicant.Upgrade.Checkpoint.down"
    assert source =~ "ASH_REPLICANT_PIPELINES_STOPPED"

    snapshot_path =
      "priv/resource_snapshots/repo/ash_replicant_checkpoints/20260101000002.json"

    assert Igniter.exists?(igniter, snapshot_path)
    snapshot = content(igniter, snapshot_path) |> Jason.decode!()

    expected_snapshot =
      AshReplicant.Upgrade.render_checkpoint_snapshot(MyApp.Repo) |> Jason.decode!()

    assert snapshot["hash"] == expected_snapshot["hash"]

    assert Igniter.exists?(igniter, "lib/my_app/replicant/pipeline.ex")

    pipeline = content(igniter, "lib/my_app/replicant/pipeline.ex")
    assert pipeline =~ "use AshReplicant.Pipeline"
    assert pipeline =~ "sink: MyApp.LegacySink"

    application = content(igniter, "lib/my_app/application.ex")
    assert application =~ "MyApp.Replicant.Pipeline"
    refute application =~ "{AshReplicant,"

    config = content(igniter, "config/runtime.exs")
    assert config =~ "MyApp.Replicant.Pipeline"
    assert config =~ "connection-secret"
    assert config =~ "source-system"
  end

  test "is idempotent after the generated migration and marker rewrite exist" do
    once = project() |> upgrade() |> apply_igniter!()
    twice = once |> upgrade() |> apply_igniter!()

    assert content(twice, "lib/my_app/legacy_sink.ex") ==
             content(once, "lib/my_app/legacy_sink.ex")

    migration_paths =
      twice.rewrite
      |> Rewrite.sources()
      |> Enum.map(& &1.path)
      |> Enum.filter(&String.ends_with?(&1, "_upgrade_ash_replicant_0_4_0_to_1_0_0.exs"))

    assert length(migration_paths) == 1
  end

  test "writes the current snapshot beside a repo's configured snapshot history" do
    repo = AshReplicant.UpgradeTaskTest.CustomSnapshotRepo
    snapshot_root = "priv/custom_resource_snapshots"
    previous = Application.get_env(:ash_replicant, repo)

    Application.put_env(:ash_replicant, repo,
      priv: "priv/custom_repo",
      snapshots_path: snapshot_root,
      url: "postgres://postgres@localhost/unused"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:ash_replicant, repo, previous)
      else
        Application.delete_env(:ash_replicant, repo)
      end
    end)

    repo_source = """
    defmodule #{inspect(repo)} do
      use AshPostgres.Repo, otp_app: :ash_replicant
    end
    """

    sink = String.replace(@sink, "MyApp.Repo", inspect(repo))

    files = %{
      "mix.exs" => @mix_exs,
      "lib/my_app/repo.ex" => repo_source,
      "lib/my_app/legacy_sink.ex" => sink,
      "lib/my_app/application.ex" => @application,
      "config/config.exs" => "import Config\n",
      "priv/custom_repo/migrations/20260101000000_install.exs" => "# existing\n",
      Path.join(
        snapshot_root,
        "custom_snapshot_repo/ash_replicant_checkpoints/20260101000000.json"
      ) => legacy_snapshot(repo)
    }

    upgraded =
      test_project(app_name: :my_app, files: files)
      |> upgrade([], inspect(repo))
      |> apply_igniter!()

    current_path =
      Path.join(
        snapshot_root,
        "custom_snapshot_repo/ash_replicant_checkpoints/20260101000002.json"
      )

    assert Igniter.exists?(upgraded, current_path)

    assert Igniter.exists?(
             upgraded,
             "priv/custom_repo/migrations/20260101000001_upgrade_ash_replicant_0_4_0_to_1_0_0.exs"
           )

    refute Igniter.exists?(
             upgraded,
             "priv/repo/migrations/20260101000001_upgrade_ash_replicant_0_4_0_to_1_0_0.exs"
           )

    refute Igniter.exists?(
             upgraded,
             "priv/resource_snapshots/custom_snapshot_repo/ash_replicant_checkpoints/20260101000002.json"
           )
  end

  test "unsupported versions refuse before any source change" do
    igniter = project() |> upgrade(["--dry-run"])

    assert igniter.issues == []

    refused =
      Igniter.compose_task(
        project(),
        Task,
        [
          "0.4.0",
          "1.0.1",
          "--repo",
          "MyApp.Repo",
          "--destination-database",
          "destination_db",
          "--binding",
          @binding
        ]
      )

    assert [issue] = refused.issues
    assert issue =~ "exactly"

    refute_creates(
      refused,
      "priv/repo/migrations/20260101000001_upgrade_ash_replicant_0_4_0_to_1_0_0.exs"
    )

    assert content(refused, "lib/my_app/legacy_sink.ex") == @sink
  end

  test "dynamic legacy supervision refuses and preserves every source byte" do
    before = project(@dynamic_application)

    refused = upgrade(before)

    assert Enum.any?(refused.issues, &String.contains?(&1, "legacy supervision"))
    assert content(refused, "lib/my_app/application.ex") == @dynamic_application
    assert content(refused, "lib/my_app/legacy_sink.ex") == @sink
    refute Igniter.exists?(refused, "lib/my_app/replicant/pipeline.ex")
  end

  test "non-relocatable legacy connection calls refuse before changing source" do
    literal_connection =
      ~s(connection: [hostname: "destination.invalid", password: "connection-secret"])

    for expression <- [
          "build_connection()",
          "MyApp.DevOnly.Config.replication_connection()"
        ] do
      application = String.replace(@application, literal_connection, "connection: #{expression}")
      before = project(application)
      refused = upgrade(before)

      assert Enum.any?(refused.issues, &String.contains?(&1, "legacy supervision"))
      assert content(refused, "lib/my_app/application.ex") == application
      assert content(refused, "lib/my_app/legacy_sink.ex") == @sink
      refute Igniter.exists?(refused, "lib/my_app/replicant/pipeline.ex")
    end
  end

  test "System environment reads remain relocatable" do
    literal_connection =
      ~s(connection: [hostname: "destination.invalid", password: "connection-secret"])

    application =
      String.replace(
        @application,
        literal_connection,
        "connection: System.fetch_env!(\"REPLICANT_CONNECTION\")"
      )

    upgraded = project(application) |> upgrade()

    assert upgraded.issues == []

    config = upgraded |> apply_igniter!() |> content("config/runtime.exs")
    assert config =~ "System.fetch_env!(\"REPLICANT_CONNECTION\")"
  end

  test "composition refuses before identity-bearing changes can reach Igniter raw diff output" do
    composed =
      project()
      |> Map.put(:task, "igniter.upgrade")
      |> Igniter.compose_task(Task, [
        "0.4.0",
        "1.0.0",
        "--repo",
        "MyApp.Repo",
        "--destination-database",
        "destination-secret",
        "--binding",
        @binding
      ])

    assert [issue] = composed.issues
    assert issue =~ "mix ash_replicant.upgrade"

    for secret <- ["connection-secret", "destination-secret", "source-system", "source-database"] do
      refute issue =~ secret
    end

    assert content(composed, "lib/my_app/application.ex") == @application
    assert content(composed, "lib/my_app/legacy_sink.ex") == @sink
    refute Igniter.exists?(composed, "lib/my_app/replicant/pipeline.ex")
  end

  test "missing legacy checkpoint snapshot refuses before changing source" do
    refused = project(@application, false) |> upgrade()

    assert Enum.any?(refused.issues, &String.contains?(&1, "checkpoint snapshot"))
    assert content(refused, "lib/my_app/application.ex") == @application
    assert content(refused, "lib/my_app/legacy_sink.ex") == @sink
    refute Igniter.exists?(refused, "lib/my_app/replicant/pipeline.ex")
  end
end
