defmodule AshReplicant.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/baselabs/ash_replicant"

  def project do
    [
      app: :ash_replicant,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_local_path: "priv/plts"],
      package: package(),
      docs: docs(),
      name: "AshReplicant",
      source_url: @source_url,
      description:
        "An Ash-native Replicant.Sink adapter: effect-once CDC mirroring into AshPostgres resources."
    ]
  end

  def cli, do: [preferred_envs: [credo: :test, dialyzer: :test]]

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.11"},
      {:ash_postgres, "~> 2.6"},
      {:ash_cloak, "~> 0.1"},
      {:replicant, path: "../replicant"},
      {:spark, ">= 2.3.3 and < 3.0.0-0"},
      {:splode, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:simple_sat, "~> 0.1"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict", "dialyzer"],
      "deps.audit": ["deps.unlock --check-unused", "hex.audit", "deps.audit"]
    ]
  end

  defp package do
    [
      maintainers: ["rjpalermo"],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* usage-rules.md),
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "usage-rules.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"]
    ]
  end
end
