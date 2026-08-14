defmodule AshReplicant.AshOnetimeMigrationContract do
  @moduledoc false

  @filename "20260814000000_install_ash_onetime.exs"
  @partition_start ~D[2026-08-01]

  def run!(root) when is_binary(root) do
    migration_dir = Path.join([root, "priv", "repo", "migrations"])
    expected_path = Path.join(migration_dir, @filename)
    install_migrations = Path.wildcard(Path.join(migration_dir, "*_install_ash_onetime.exs"))

    unless Enum.map(install_migrations, &Path.basename/1) == [@filename] do
      raise "AshOnetime migration filename contract failed"
    end

    expected =
      Mix.Tasks.AshOnetime.Gen.Migrations.render(AshReplicant.TestRepo,
        partition_start: @partition_start
      )

    unless File.read!(expected_path) == expected do
      raise "AshOnetime migration content contract failed"
    end

    :ok
  rescue
    _error in [File.Error] -> raise "AshOnetime migration input is invalid"
  end
end
