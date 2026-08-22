defmodule AshReplicant.Upgrade.CheckpointIntegrationTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Upgrade.Checkpoint
  alias AshReplicant.Upgrade.Checkpoint.{Error, Report}

  @database "ash_replicant_test"
  @binding %{
    slot_name: "upgrade_slot",
    source_system_id: "source-system",
    source_database: "source-database"
  }

  setup context do
    prefix = "i02_#{context.test |> Atom.to_string() |> :erlang.phash2()}"
    q!(~s|CREATE SCHEMA "#{prefix}"|)
    %{prefix: prefix}
  end

  test "upgrades a populated legacy table atomically and rolls it back while unchanged", %{
    prefix: prefix
  } do
    legacy!(prefix)

    q!(
      ~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ($1, $2)|,
      [@binding.slot_name, 42]
    )

    assert {:ok, %Report{state: :upgraded, legacy_rows: 1}} =
             Checkpoint.up(TestRepo, options(prefix))

    source_system_id = @binding.source_system_id
    source_database = @binding.source_database

    assert [[^source_system_id, ^source_database, 42]] =
             q!(
               ~s|SELECT source_system_id, source_database, commit_lsn FROM "#{prefix}".ash_replicant_checkpoints|,
               []
             ).rows

    assert {:ok, %Report{state: :already_upgraded}} =
             Checkpoint.check(TestRepo, options(prefix))

    assert {:ok, %Report{state: :rolled_back, legacy_rows: 1}} =
             Checkpoint.down(TestRepo, options(prefix))

    assert {:ok, %Report{state: :legacy_ready}} =
             Checkpoint.check(TestRepo, options(prefix))
  end

  test "upgrades an empty legacy table and retains dormant bindings", %{prefix: prefix} do
    legacy!(prefix)

    assert {:ok, %Report{state: :upgraded, legacy_rows: 0, dormant_bindings: 1}} =
             Checkpoint.up(TestRepo, options(prefix))
  end

  test "recognizes the canonical fresh-install current column order", %{prefix: prefix} do
    canonical_current!(prefix)

    assert {:ok, %Report{state: :already_upgraded, bound_rows: 0, dormant_bindings: 1}} =
             Checkpoint.check(TestRepo, options(prefix))
  end

  test "refuses shared, foreign, interrupted, and already-written rollback states", %{
    prefix: prefix
  } do
    legacy!(prefix)
    q!(~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ('foreign_slot', 7)|)

    assert {:error, %Error{reason: :legacy_row_unbound}} =
             Checkpoint.up(TestRepo, options(prefix))

    q!(~s|DELETE FROM "#{prefix}".ash_replicant_checkpoints|)
    q!(~s|ALTER TABLE "#{prefix}".ash_replicant_checkpoints ADD COLUMN foreign_column text|)

    assert {:error, %Error{reason: :foreign_checkpoint}} =
             Checkpoint.check(TestRepo, options(prefix))

    q!(~s|ALTER TABLE "#{prefix}".ash_replicant_checkpoints DROP COLUMN foreign_column|)
    q!(~s|ALTER TABLE "#{prefix}".ash_replicant_checkpoints ADD COLUMN source_system_id text|)

    assert {:error, %Error{reason: :interrupted_upgrade}} =
             Checkpoint.check(TestRepo, options(prefix))

    q!(~s|DROP TABLE "#{prefix}".ash_replicant_checkpoints|)
    legacy!(prefix)

    q!(~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ($1, 7)|, [
      @binding.slot_name
    ])

    assert {:ok, %Report{state: :upgraded}} = Checkpoint.up(TestRepo, options(prefix))

    q!(~s|UPDATE "#{prefix}".ash_replicant_checkpoints SET commit_lsn = 8|)

    assert {:error, %Error{reason: :rollback_state_changed}} =
             Checkpoint.down(TestRepo, options(prefix))
  end

  test "a forced mid-upgrade failure rolls every DDL and ledger write back", %{prefix: prefix} do
    legacy!(prefix)

    q!(
      ~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ($1, 42)|,
      [@binding.slot_name]
    )

    assert {:error, %Error{reason: :database_fault}} =
             Checkpoint.up(TestRepo, Keyword.put(options(prefix), :test_fail_after_ddl?, true))

    assert {:ok, %Report{state: :legacy_ready}} =
             Checkpoint.check(TestRepo, options(prefix))

    assert [[nil]] =
             q!("SELECT to_regclass($1)", [
               ~s("#{prefix}"."ash_replicant_checkpoint_upgrade_0_4_0")
             ]).rows
  end

  test "rollback refuses a ledger whose version constraint was removed", %{prefix: prefix} do
    legacy!(prefix)

    q!(~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ($1, 42)|, [
      @binding.slot_name
    ])

    assert {:ok, %Report{state: :upgraded}} = Checkpoint.up(TestRepo, options(prefix))

    q!("""
    ALTER TABLE "#{prefix}".ash_replicant_checkpoint_upgrade_0_4_0
    DROP CONSTRAINT ash_replicant_checkpoint_upgrade_version_check
    """)

    assert {:error, %Error{reason: :rollback_ledger_invalid}} =
             Checkpoint.down(TestRepo, options(prefix))
  end

  test "rollback refuses every 1.0-only state family and a tampered checksum", %{prefix: prefix} do
    legacy!(prefix)

    q!(~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ($1, 42)|, [
      @binding.slot_name
    ])

    assert {:ok, %Report{state: :upgraded}} = Checkpoint.up(TestRepo, options(prefix))

    for {column, value_sql} <- [
          {"source_timeline", "1"},
          {"publication_contract", "decode('01', 'hex')"},
          {"publication_fingerprint", "decode('02', 'hex')"},
          {"snapshot_progress", "decode('03', 'hex')"},
          {"snapshot_state", "decode('04', 'hex')"},
          {"origin_floor", "1"}
        ] do
      q!(~s|UPDATE "#{prefix}".ash_replicant_checkpoints SET #{column} = #{value_sql}|)

      assert {:error, %Error{reason: :rollback_state_changed}} =
               Checkpoint.down(TestRepo, options(prefix))

      q!(~s|UPDATE "#{prefix}".ash_replicant_checkpoints SET #{column} = NULL|)
    end

    q!("""
    UPDATE "#{prefix}".ash_replicant_checkpoint_upgrade_0_4_0
    SET checksum = decode(repeat('00', 32), 'hex')
    """)

    assert {:error, %Error{reason: :rollback_ledger_invalid}} =
             Checkpoint.down(TestRepo, options(prefix))
  end

  test "timestamp metadata does not make an otherwise untouched upgrade irreversible", %{
    prefix: prefix
  } do
    legacy!(prefix)

    q!(~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ($1, 42)|, [
      @binding.slot_name
    ])

    assert {:ok, %Report{state: :upgraded}} = Checkpoint.up(TestRepo, options(prefix))

    q!("""
    UPDATE "#{prefix}".ash_replicant_checkpoints
    SET inserted_at = inserted_at + interval '1 second',
        updated_at = updated_at + interval '2 seconds'
    """)

    assert {:ok, %Report{state: :rolled_back}} = Checkpoint.down(TestRepo, options(prefix))
  end

  @tag no_sandbox: true
  test "an old-shape writer blocks at the upgrade lock and fails after the schema changes", %{
    prefix: prefix
  } do
    on_exit(fn -> q!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|) end)
    legacy!(prefix)
    observer = self()

    upgrade =
      Task.async(fn ->
        Checkpoint.up(
          TestRepo,
          Keyword.put(options(prefix), :test_lock_observer, observer)
        )
      end)

    assert_receive {:ash_replicant_upgrade_locked, upgrade_process}, 2_000

    writer =
      Task.async(fn ->
        try do
          q!("""
          INSERT INTO "#{prefix}".ash_replicant_checkpoints (slot_name, commit_lsn)
          VALUES ('old_writer', 99)
          """)

          :wrote
        rescue
          _error -> :refused
        catch
          _kind, _reason -> :refused
        end
      end)

    assert Task.yield(writer, 100) == nil
    send(upgrade_process, :continue_ash_replicant_upgrade)

    assert {:ok, %Report{state: :upgraded}} = Task.await(upgrade, 2_000)
    assert :refused = Task.await(writer, 2_000)
    assert {:ok, %Report{state: :already_upgraded}} = Checkpoint.check(TestRepo, options(prefix))
  end

  test "mutating the ownership guard makes the shared-row fixture non-vacuously pass" do
    facts = %{
      schema: :legacy,
      rows: [%{slot_name: "unclaimed", commit_lsn: 1}],
      bindings: [@binding]
    }

    assert {:error, %Error{reason: :legacy_row_unbound}} = Checkpoint.classify(facts)

    mutated = Map.put(facts, :rows, [%{slot_name: @binding.slot_name, commit_lsn: 1}])
    assert {:ok, %Report{state: :legacy_ready}} = Checkpoint.classify(mutated)
  end

  test "refuses a wrong physical destination, missing table, and absent offline assertion", %{
    prefix: prefix
  } do
    legacy!(prefix)

    assert {:error, %Error{reason: :destination_mismatch}} =
             Checkpoint.up(
               TestRepo,
               Keyword.put(options(prefix), :destination_database, "another_database")
             )

    assert {:error, %Error{reason: :pipelines_not_stopped}} =
             Checkpoint.up(TestRepo, Keyword.put(options(prefix), :pipelines_stopped?, false))

    q!(~s|DROP TABLE "#{prefix}".ash_replicant_checkpoints|)

    assert {:error, %Error{reason: :checkpoint_missing}} =
             Checkpoint.up(TestRepo, options(prefix))
  end

  @tag no_sandbox: true
  test "the generated host migration executes through Ecto's migration runner", %{prefix: prefix} do
    version = System.system_time(:microsecond)

    on_exit(fn ->
      q!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
      q!("DELETE FROM schema_migrations WHERE version = $1", [version])
    end)

    legacy!(prefix)

    q!(
      ~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ($1, 42)|,
      [@binding.slot_name]
    )

    module =
      Module.concat([
        AshReplicant.Test,
        "GeneratedCheckpointUpgrade#{System.unique_integer([:positive])}"
      ])

    plan = %AshReplicant.Upgrade.Plan{
      repo: TestRepo,
      prefix: prefix,
      destination_database: @database,
      bindings: [Map.put(@binding, :sink, AshReplicant.Test.Sink)]
    }

    [{^module, _bytecode}] =
      plan
      |> AshReplicant.Upgrade.render_migration(module)
      |> Code.compile_string()

    previous = System.get_env("ASH_REPLICANT_PIPELINES_STOPPED")
    System.put_env("ASH_REPLICANT_PIPELINES_STOPPED", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("ASH_REPLICANT_PIPELINES_STOPPED", previous),
        else: System.delete_env("ASH_REPLICANT_PIPELINES_STOPPED")

      :code.purge(module)
      :code.delete(module)
    end)

    assert :ok = Ecto.Migrator.up(TestRepo, version, module, log: false)
    assert {:ok, %Report{state: :already_upgraded}} = Checkpoint.check(TestRepo, options(prefix))

    assert :ok = Ecto.Migrator.down(TestRepo, version, module, log: false)
    assert {:ok, %Report{state: :legacy_ready}} = Checkpoint.check(TestRepo, options(prefix))
  end

  @tag no_sandbox: true
  test "the public task upgrades a real legacy consumer without printing identity values", %{
    prefix: prefix
  } do
    root = File.cwd!()
    fixture = Path.join(root, "test/fixtures/upgrade_0_4_app")

    temp =
      Path.join(System.tmp_dir!(), "ash_replicant_upgrade_#{System.unique_integer([:positive])}")

    migration_version = 20_990_101_000_001

    on_exit(fn ->
      File.rm_rf!(temp)
      q!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)

      if q!("SELECT to_regclass('schema_migrations')").rows != [[nil]] do
        q!("DELETE FROM schema_migrations WHERE version = $1", [migration_version])
      end
    end)

    File.cp_r!(fixture, temp)
    legacy!(prefix)

    q!(~s|INSERT INTO "#{prefix}".ash_replicant_checkpoints VALUES ($1, 42)|, [
      "consumer_upgrade_slot"
    ])

    database_url =
      System.fetch_env!("ASH_REPLICANT_TEST_URL")
      |> URI.parse()
      |> Map.put(:path, "/#{@database}")
      |> URI.to_string()

    runtime = Path.join(root, "scripts/with-release-runtime.sh")

    env = [
      {"ASH_REPLICANT_PATH", root},
      {"ASH_REPLICANT_TEST_URL", database_url},
      {"MIX_ENV", "test"}
    ]

    assert_cmd!(runtime, ["mix", "deps.get"], temp, env)
    before_dry_run = source_digest(temp)

    binding =
      Jason.encode!(%{
        sink: "UpgradeFixture.LegacySink",
        pipeline: "UpgradeFixture.Replicant.Pipeline",
        source_system_id: "consumer-system-secret-sentinel",
        source_database: "consumer-database-secret-sentinel"
      })

    args = [
      "mix",
      "ash_replicant.upgrade",
      "0.4.0",
      "1.0.0",
      "--repo",
      "UpgradeFixture.Repo",
      "--destination-database",
      @database,
      "--prefix",
      prefix,
      "--binding",
      binding
    ]

    dry_output = assert_cmd!(runtime, args ++ ["--dry-run"], temp, env)
    assert source_digest(temp) == before_dry_run
    assert_redacted!(dry_output)

    apply_output = assert_cmd!(runtime, args ++ ["--yes"], temp, env)
    assert_redacted!(apply_output)

    refute File.read!(Path.join(temp, "lib/upgrade_fixture/legacy_sink.ex")) =~ "apply_ledger"

    assert File.read!(Path.join(temp, "lib/upgrade_fixture/application.ex")) =~
             "UpgradeFixture.Replicant.Pipeline"

    assert File.exists?(
             Path.join(
               temp,
               "priv/upgrade_snapshots/repo/ash_replicant_checkpoints/20990101000002.json"
             )
           )

    migration =
      Path.join(
        temp,
        "priv/repo/migrations/20990101000001_upgrade_ash_replicant_0_4_0_to_1_0_0.exs"
      )

    assert File.exists?(migration)

    migration_probe = """
    Application.ensure_all_started(:ash_replicant)
    {:ok, repo} = UpgradeFixture.Repo.start_link()
    Code.require_file(#{inspect(migration)})
    module = UpgradeFixture.Repo.Migrations.UpgradeAshReplicant040To100
    :ok = Ecto.Migrator.up(UpgradeFixture.Repo, #{migration_version}, module, log: false)
    {:ok, %{state: :already_upgraded}} =
      AshReplicant.Upgrade.Checkpoint.check(UpgradeFixture.Repo,
        bindings: [
          %{
            slot_name: "consumer_upgrade_slot",
            source_system_id: "consumer-system-secret-sentinel",
            source_database: "consumer-database-secret-sentinel"
          }
        ],
        prefix: #{inspect(prefix)},
        destination_database: #{inspect(@database)}
      )
    :ok = Ecto.Migrator.down(UpgradeFixture.Repo, #{migration_version}, module, log: false)
    GenServer.stop(repo)
    IO.puts("consumer-migration-up-down-ok")
    """

    migration_output =
      assert_cmd!(
        runtime,
        ["mix", "run", "--no-start", "-e", migration_probe],
        temp,
        [{"ASH_REPLICANT_PIPELINES_STOPPED", "1"} | env]
      )

    assert migration_output =~ "consumer-migration-up-down-ok"
    assert_redacted!(migration_output)

    assert {:ok, %Report{state: :legacy_ready}} =
             Checkpoint.check(TestRepo,
               bindings: [
                 %{
                   slot_name: "consumer_upgrade_slot",
                   source_system_id: "consumer-system-secret-sentinel",
                   source_database: "consumer-database-secret-sentinel"
                 }
               ],
               prefix: prefix,
               destination_database: @database
             )
  end

  defp options(prefix) do
    [
      bindings: [@binding],
      prefix: prefix,
      destination_database: @database,
      pipelines_stopped?: true,
      lock_timeout_ms: 2_000
    ]
  end

  defp legacy!(prefix) do
    q!("""
    CREATE TABLE "#{prefix}".ash_replicant_checkpoints (
      slot_name text PRIMARY KEY NOT NULL,
      commit_lsn bigint NOT NULL
    )
    """)

    q!("""
    CREATE UNIQUE INDEX ash_replicant_checkpoints_unique_slot_index
    ON "#{prefix}".ash_replicant_checkpoints (slot_name)
    """)
  end

  defp canonical_current!(prefix) do
    q!("""
    CREATE TABLE "#{prefix}".ash_replicant_checkpoints (
      source_system_id text NOT NULL,
      source_database text NOT NULL,
      slot_name text NOT NULL,
      source_timeline bigint,
      publication_contract bytea,
      publication_fingerprint bytea,
      commit_lsn bigint,
      snapshot_progress bytea,
      snapshot_state bytea,
      origin_floor bigint,
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      PRIMARY KEY (source_system_id, source_database, slot_name)
    )
    """)

    q!("""
    CREATE UNIQUE INDEX ash_replicant_checkpoints_source_slot_index
    ON "#{prefix}".ash_replicant_checkpoints (source_system_id, source_database, slot_name)
    """)

    q!("""
    CREATE UNIQUE INDEX ash_replicant_checkpoints_unique_slot_index
    ON "#{prefix}".ash_replicant_checkpoints (slot_name)
    """)
  end

  defp assert_cmd!(runtime, args, directory, env) do
    case System.cmd(runtime, args,
           cd: directory,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output

      {output, status} ->
        flunk("consumer command exited #{status}:\n#{output}")
    end
  end

  defp assert_redacted!(output) do
    for secret <- [
          "consumer-connection-secret-sentinel",
          "consumer-system-secret-sentinel",
          "consumer-database-secret-sentinel",
          "consumer_upgrade_slot"
        ] do
      refute output =~ secret
    end
  end

  defp source_digest(root) do
    ["config/**/*", "lib/**/*", "priv/repo/**/*", "priv/upgrade_snapshots/**/*"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params)
end
