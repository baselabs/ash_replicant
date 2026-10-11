Code.require_file("fresh_consumer_database.exs", __DIR__)

try do
  [channel_path, ready] = System.argv()

  AshReplicant.FreshConsumerDatabase.lease!(
    System.fetch_env!("ASH_REPLICANT_TEST_URL"),
    System.fetch_env!("ASH_REPLICANT_CONSUMER_DATABASE"),
    channel_path,
    ready
  )
rescue
  _error ->
    IO.puts(:stderr, "fresh-consumer: database lease failed")
    System.halt(1)
catch
  _kind, _reason ->
    IO.puts(:stderr, "fresh-consumer: database lease failed")
    System.halt(1)
end
