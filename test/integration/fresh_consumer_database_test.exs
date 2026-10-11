Code.require_file("../../scripts/fresh_consumer_database.exs", __DIR__)

defmodule AshReplicant.FreshConsumerDatabaseTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshReplicant.FreshConsumerDatabase

  @connection_key {__MODULE__, :connections}

  # The test kills a lease holder and its linked connections on purpose; their
  # termination reports are expected and stay out of the structural log.
  @tag capture_log: true
  test "reclaims abandoned resources while retaining its own run, live backends, and live leases" do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    url = System.fetch_env!("ASH_REPLICANT_TEST_URL")
    run = System.system_time(:microsecond)
    own = "ash_replicant_consumer_#{run}_1"
    abandoned = "ash_replicant_consumer_#{run}_2"
    live = "ash_replicant_consumer_#{run}_3"
    leased = "ash_replicant_consumer_#{run}_4"
    unrelated = "ash_replicant_retained_#{run}_5"
    databases = [own, abandoned, live, leased, unrelated]
    seeded_slots = [own, abandoned, leased, unrelated] |> Enum.sort()
    ready = Path.join(System.tmp_dir!(), "ash-replicant-consumer-lease-#{run}")
    channel = ready <> ".fifo"
    {_output, 0} = System.cmd("mkfifo", ["-m", "600", channel])
    admin = connect(url, "postgres", own)

    owner =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", ~s(exec 9>"$1"; exec sleep 60), "consumer-owner", channel]
      ])

    {:os_pid, owner_pid} = Port.info(owner, :os_pid)
    Process.put(@connection_key, [admin])

    try do
      FreshConsumerDatabase.reclaim!(admin, own)

      Enum.each(databases, fn database ->
        Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}"), [])
      end)

      Enum.each(seeded_slots, &create_inactive_slot!(url, &1))
      live_connection = tracked_connect(url, live, "ash_replicant_reclaim_test")
      assert Process.alive?(live_connection)

      assert names(admin, "SELECT datname FROM pg_database WHERE datname = ANY($1)", databases) ==
               Enum.sort(databases)

      assert names(
               admin,
               "SELECT slot_name FROM pg_replication_slots WHERE slot_name = ANY($1)",
               databases
             ) == seeded_slots

      lease =
        Task.async(fn ->
          FreshConsumerDatabase.lease!(url, leased, channel, ready)
        end)

      try do
        eventually(fn -> File.exists?(ready) end)

        assert [[1]] ==
                 Postgrex.query!(
                   admin,
                   "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1 AND datname = 'postgres'",
                   [leased]
                 ).rows

        assert [[0]] ==
                 Postgrex.query!(
                   admin,
                   "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
                   [leased]
                 ).rows

        retained = [own, live, leased, unrelated] |> Enum.sort()

        assert names(admin, "SELECT datname FROM pg_database WHERE datname = ANY($1)", databases) ==
                 retained

        assert names(
                 admin,
                 "SELECT slot_name FROM pg_replication_slots WHERE slot_name = ANY($1)",
                 databases
               ) == Enum.sort([own, leased, unrelated])

        # Reuse the capacity freed by startup reclamation for the live-backend
        # protection rather than requiring a fifth simultaneous slot.
        create_slot!(live_connection, live)

        assert names(
                 admin,
                 "SELECT slot_name FROM pg_replication_slots WHERE slot_name = ANY($1)",
                 databases
               ) == retained

        FreshConsumerDatabase.reclaim!(admin, own)

        assert names(admin, "SELECT datname FROM pg_database WHERE datname = ANY($1)", databases) ==
                 retained

        assert names(
                 admin,
                 "SELECT slot_name FROM pg_replication_slots WHERE slot_name = ANY($1)",
                 databases
               ) == retained

        {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(owner_pid)])
        assert :ok == Task.await(lease, 5_000)
        eventually(fn -> not File.exists?(ready) end)

        FreshConsumerDatabase.reclaim!(admin, own)
        retained = [own, live, unrelated] |> Enum.sort()

        assert names(admin, "SELECT datname FROM pg_database WHERE datname = ANY($1)", databases) ==
                 retained

        assert names(
                 admin,
                 "SELECT slot_name FROM pg_replication_slots WHERE slot_name = ANY($1)",
                 databases
               ) == retained
      after
        Task.shutdown(lease, :brutal_kill)
      end
    after
      System.cmd("kill", ["-KILL", Integer.to_string(owner_pid)], stderr_to_stdout: true)

      try do
        Port.close(owner)
      rescue
        ArgumentError -> :ok
      end

      File.rm(ready)
      File.rm(channel)

      Enum.each(Process.get(@connection_key, []), fn connection ->
        if connection != admin and Process.alive?(connection), do: GenServer.stop(connection)
      end)

      Enum.each(databases, fn database ->
        Postgrex.query!(
          admin,
          "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = $1 AND NOT active",
          [database]
        )

        Postgrex.query!(admin, ~s(DROP DATABASE IF EXISTS "#{database}"), [])
      end)

      if Process.alive?(admin), do: GenServer.stop(admin)
      Process.delete(@connection_key)
    end
  end

  defp connect(url, database, application_name) do
    uri = URI.parse(url)
    [username | rest] = String.split(uri.userinfo || "postgres", ":", parts: 2)
    password = if rest == [], do: nil, else: URI.decode(hd(rest))

    {:ok, connection} =
      Postgrex.start_link(
        hostname: uri.host,
        port: uri.port || 5432,
        username: URI.decode(username),
        password: password,
        database: database,
        parameters: [application_name: application_name],
        sync_connect: true
      )

    connection
  end

  defp tracked_connect(url, database, application_name) do
    connection = connect(url, database, application_name)
    Process.put(@connection_key, [connection | Process.get(@connection_key, [])])
    connection
  end

  defp create_inactive_slot!(url, database) do
    connection = tracked_connect(url, database, "ash_replicant_reclaim_test")
    create_slot!(connection, database)
    GenServer.stop(connection)
  end

  defp create_slot!(connection, slot) do
    Postgrex.query!(connection, "SELECT pg_create_logical_replication_slot($1, 'pgoutput')", [
      slot
    ])
  end

  defp names(connection, statement, names) do
    Postgrex.query!(connection, statement, [names]).rows |> List.flatten() |> Enum.sort()
  end

  defp eventually(check, attempts \\ 200)

  defp eventually(check, attempts) when attempts > 0 do
    if check.() do
      :ok
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end

  defp eventually(_check, 0), do: flunk("consumer lease lifecycle did not settle")
end
