defmodule UpgradeFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :upgrade_fixture,
      version: "0.4.0",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {UpgradeFixture.Application, []}]
  end

  defp deps do
    [
      {:ash_replicant, path: System.fetch_env!("ASH_REPLICANT_PATH")},
      {:igniter, ">= 0.8.3 and < 1.0.0-0", runtime: false}
    ]
  end
end
