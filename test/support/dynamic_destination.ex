defmodule AshReplicant.Test.DynamicDestination do
  @moduledoc false
  # The dynamic-repo destination fixture (cross-vendor REL02 finding: the
  # tombstone and horizon paths must bind the ADMITTED dynamic repo, not the
  # static module). A second, owned instance of the test repo is started
  # against a DEDICATED database on the same server, so which instance an Ash
  # call routed to is observable by which database the row lands in: routing
  # drift is invisible when every instance shares one database.
  #
  # The instance is owned (Ecto.Repo.Registry ownership — exactly what
  # Destination.dynamic_repo_owned_by/2 admits at activation), runs its own
  # non-sandbox pool, and the dedicated database is migrated on first use.

  alias AshReplicant.TestRepo

  @database "ash_replicant_test_dyn"

  @doc """
  Start a dynamic instance of the test repo against the dedicated
  `#{@database}` database (created and migrated on demand).

  Returns `{:ok, name}` — `name` is a valid `data_layer: %{repo: name}`
  binding and a valid `put_dynamic_repo/1` argument. Idempotent per name.
  The instance is linked to the caller.
  """
  def start!(name) when is_atom(name) do
    bootstrap_database!()

    {:ok, _pid} =
      TestRepo.start_link(
        name: name,
        url: dyn_url(),
        pool: DBConnection.ConnectionPool,
        pool_size: 2,
        priv: "priv/repo"
      )

    previous = TestRepo.put_dynamic_repo(name)

    try do
      Ecto.Migrator.run(TestRepo, :up, all: true)
    after
      TestRepo.put_dynamic_repo(previous)
    end

    {:ok, name}
  end

  @doc "The dedicated database name (for explicit row cleanup)."
  def database, do: @database

  @doc """
  Query the dedicated database directly (bypassing every repo binding) —
  the routing oracle: a row visible here was written through the dynamic
  instance; a row visible only in the shared test database was not.
  """
  def query!(sql, params \\ []) do
    uri = server_uri()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: uri.host,
        port: uri.port || 5432,
        username: uri.userinfo || "postgres",
        database: @database
      )

    try do
      Postgrex.query!(conn, sql, params)
    after
      GenServer.stop(conn)
    end
  end

  defp bootstrap_database! do
    uri = server_uri()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: uri.host,
        port: uri.port || 5432,
        username: uri.userinfo || "postgres",
        database: "postgres"
      )

    try do
      Postgrex.query!(conn, "CREATE DATABASE #{@database}", [])
    rescue
      # already exists — idempotent bootstrap
      error in Postgrex.Error ->
        unless error.postgres.code == :duplicate_database, do: reraise(error, __STACKTRACE__)
    after
      GenServer.stop(conn)
    end
  end

  defp dyn_url do
    server_uri() |> Map.put(:path, "/" <> @database) |> URI.to_string()
  end

  defp server_uri do
    "ASH_REPLICANT_TEST_URL"
    |> System.get_env("postgres://postgres@localhost:5599")
    |> URI.parse()
  end
end
