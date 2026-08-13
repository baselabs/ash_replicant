if AshReplicant.Test.PG.enabled?() do
  {:ok, _} = AshReplicant.TestRepo.start_link()

  # Bring the bundled checkpoint (and, in later tasks, mirror) schema up before the
  # suite. In :auto mode the Sandbox pool behaves like a normal pool — migrations
  # check out real connections and COMMIT, so every per-test Sandbox transaction sees
  # the tables. Switch to :manual for the isolated, rolled-back per-test transactions.
  Ecto.Adapters.SQL.Sandbox.mode(AshReplicant.TestRepo, :auto)
  Ecto.Migrator.run(AshReplicant.TestRepo, :up, all: true)
  Ecto.Adapters.SQL.Sandbox.mode(AshReplicant.TestRepo, :manual)

  ExUnit.start()
else
  Application.put_env(:ash_replicant, :forbid_test_repo_start?, true)
  :persistent_term.erase(AshReplicant.TestRepo.start_attempt_key())
  ExUnit.configure(exclude: [:integration])
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
