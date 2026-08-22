defmodule UpgradeFixture.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      UpgradeFixture.Repo,
      {AshReplicant,
       sink: UpgradeFixture.LegacySink,
       connection: [
         hostname: "source.invalid",
         password: "consumer-connection-secret-sentinel"
       ],
       publication: "consumer_publication",
       go_forward_only: true,
       snapshot: false}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
