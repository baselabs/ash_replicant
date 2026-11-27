alias AshReplicant.Test.{DecoderSource, PG}

decoder_excludes =
  cond do
    DecoderSource.enabled?() ->
      unless PG.enabled?(), do: raise("decoder source requires a destination")

      DecoderSource.release!()
      []

    System.get_env("EXPECTED_PG_SOURCE_MAJOR") != nil ->
      raise "decoder source lane requires a source URL"

    true ->
      [:decoder_source]
  end

if PG.enabled?() do
  {:ok, _} = AshReplicant.TestRepo.start_link()

  # Bring the bundled checkpoint (and, in later tasks, mirror) schema up before the
  # suite. In :auto mode the Sandbox pool behaves like a normal pool — migrations
  # check out real connections and COMMIT, so every per-test Sandbox transaction sees
  # the tables. Switch to :manual for the isolated, rolled-back per-test transactions.
  Ecto.Adapters.SQL.Sandbox.mode(AshReplicant.TestRepo, :auto)

  [[release]] =
    AshReplicant.TestRepo.query!("SELECT current_setting('server_version_num')::int").rows

  PG.assert_major!(release, "EXPECTED_PG_MAJOR")
  Ecto.Migrator.run(AshReplicant.TestRepo, :up, all: true)
  Ecto.Adapters.SQL.Sandbox.mode(AshReplicant.TestRepo, :manual)

  ExUnit.configure(exclude: [:performance] ++ decoder_excludes)
  ExUnit.start()
else
  Application.put_env(:ash_replicant, :forbid_test_repo_start?, true)
  :persistent_term.erase(AshReplicant.TestRepo.start_attempt_key())

  ExUnit.configure(exclude: [:integration, :performance] ++ decoder_excludes)
  ExUnit.start()

  ExUnit.after_suite(fn _result ->
    if :persistent_term.get(AshReplicant.TestRepo.start_attempt_key(), false) do
      IO.puts(:stderr, "TestRepo start attempt detected")
      System.halt(1)
    else
      IO.puts("TestRepo start attempts: 0")
    end
  end)
end
