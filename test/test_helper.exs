if AshReplicant.Test.PG.enabled?() do
  {:ok, _} = AshReplicant.TestRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(AshReplicant.TestRepo, :manual)
  ExUnit.start()
else
  ExUnit.configure(exclude: [:integration])
  ExUnit.start()
end
