defmodule AshReplicant.FreshConsumerDatabase.Error do
  defexception [:reason]

  def message(%{reason: reason}), do: "fresh-consumer database lifecycle failed: #{reason}"
end

defmodule AshReplicant.FreshConsumerDatabase do
  alias AshReplicant.FreshConsumerDatabase.Error

  @name ~r/\Aash_replicant_consumer_[0-9]+_[0-9]+\z/
  @sql_name "^ash_replicant_consumer_[0-9]+_[0-9]+$"
  @lock "ash_replicant:fresh_consumer_reclaim"
  @timeout 5_000

  @slots """
  SELECT candidate.slot_name
  FROM pg_replication_slots AS candidate
  WHERE candidate.slot_name ~ $1
    AND candidate.slot_name <> $2
    AND NOT candidate.active
    AND NOT EXISTS (
      SELECT 1 FROM pg_stat_activity AS backend
      WHERE backend.application_name = candidate.slot_name
         OR backend.datname = candidate.database
    )
  """

  @databases """
  SELECT candidate.datname
  FROM pg_database AS candidate
  WHERE candidate.datname ~ $1
    AND candidate.datname <> $2
    AND NOT EXISTS (
      SELECT 1 FROM pg_stat_activity AS backend
      WHERE backend.application_name = candidate.datname
         OR backend.datname = candidate.datname
    )
  """

  def reclaim!(connection, own) do
    validate_name!(own)
    assert_activity_tracking!(connection)
    query!(connection, "SELECT pg_advisory_lock(hashtext($1))", [@lock])

    try do
      slots = reclaim_slots!(connection, own)
      databases = reclaim_databases!(connection, own)
      %{slots: slots, databases: databases}
    after
      query!(connection, "SELECT pg_advisory_unlock(hashtext($1))", [@lock])
    end
  end

  # The lease stays on the administrative database through every consumer Mix
  # child and the gaps between them. Reclaimers recognize its application_name
  # even while the consumer database has no connection of its own.
  def lease!(url, own, channel_path, ready) do
    validate_name!(own)
    {:ok, channel} = File.open(channel_path, [:read, :binary])

    reader =
      Task.async(fn ->
        case IO.binread(channel, 1) do
          :eof -> :closed
          _other -> raise Error, reason: :lease_channel_invalid
        end
      end)

    {:ok, _} = Application.ensure_all_started(:postgrex)

    connection =
      case Postgrex.start_link(connection_options(url, own)) do
        {:ok, connection} -> connection
        {:error, _error} -> raise Error, reason: :connection_unavailable
      end

    try do
      unless query!(connection, "SELECT current_setting('application_name') = $1", [own]).rows ==
               [[true]] do
        raise Error, reason: :lease_identity_invalid
      end

      reclaim!(connection, own)

      case Task.yield(reader, 0) do
        nil ->
          File.write!(ready, "ready\n")
          hold_lease(connection, reader)

        {:ok, :closed} ->
          :ok
      end

      :ok
    after
      File.rm(ready)
      if Process.alive?(connection), do: GenServer.stop(connection)
      Task.shutdown(reader, :brutal_kill)
      File.close(channel)
    end
  end

  defp connection_options(url, own) do
    uri = URI.parse(url)

    unless is_binary(uri.host) and uri.host != "" do
      raise Error, reason: :connection_config_invalid
    end

    [username | credentials] = String.split(uri.userinfo || "postgres", ":", parts: 2)
    password = if credentials == [], do: nil, else: URI.decode(hd(credentials))

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: URI.decode(username),
      password: password,
      database: "postgres",
      parameters: [application_name: own],
      sync_connect: true,
      connect_timeout: @timeout,
      backoff_type: :stop
    ]
  end

  defp assert_activity_tracking!(connection) do
    unless query!(connection, "SELECT current_setting('track_activities') = 'on'", []).rows ==
             [[true]] do
      raise Error, reason: :activity_tracking_required
    end
  end

  defp reclaim_slots!(connection, own) do
    query!(connection, @slots, [@sql_name, own]).rows
    |> Enum.reduce(0, fn [slot], count ->
      validate_name!(slot)

      statement =
        "SELECT pg_drop_replication_slot(candidate.slot_name) " <>
          "FROM pg_replication_slots AS candidate " <>
          "WHERE candidate.slot_name = $3 AND candidate.slot_name IN (#{@slots})"

      count + query!(connection, statement, [@sql_name, own, slot]).num_rows
    end)
  end

  defp reclaim_databases!(connection, own) do
    query!(connection, @databases, [@sql_name, own]).rows
    |> Enum.reduce(0, fn [database], count ->
      validate_name!(database)

      if query!(connection, @databases <> " AND candidate.datname = $3", [
           @sql_name,
           own,
           database
         ]).rows == [[database]] do
        query!(connection, ~s(DROP DATABASE "#{database}"), [])
        count + 1
      else
        count
      end
    end)
  end

  defp hold_lease(connection, reader) do
    case Task.yield(reader, 250) do
      nil ->
        query!(connection, "SELECT 1", [])
        hold_lease(connection, reader)

      {:ok, :closed} ->
        :ok
    end
  end

  defp validate_name!(name) do
    unless is_binary(name) and byte_size(name) <= 63 and Regex.match?(@name, name) do
      raise Error, reason: :resource_name_invalid
    end
  end

  defp query!(connection, statement, parameters) do
    Postgrex.query!(connection, statement, parameters, timeout: @timeout)
  end
end
