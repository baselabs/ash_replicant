defmodule AshReplicant.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/baselabs/ash_replicant"
  @ash_requirement ">= 3.31.3 and < 4.0.0-0"
  @replicant_requirement ">= 1.2.2 and < 2.0.0-0"

  def project do
    [
      app: :ash_replicant,
      version: @version,
      elixir: "~> 1.20.3",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # `:cloak` is a `runtime: false` dep, so it is absent from the default PLT
      # application tree. Without it in the PLT, dialyzer has no type info for the
      # `Cloak.Vault` module and emits `unknown_function` warnings against cloak's
      # own `use Cloak.Vault` macro body (surfaced via our test vaults). Adding it
      # to `plt_add_apps` pre-analyzes cloak so those external warnings resolve.
      dialyzer: [plt_add_apps: [:mix, :ex_unit, :cloak], plt_local_path: "priv/plts"],
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
      {:ash, ash_requirement()},
      {:ash_postgres, "~> 2.11.0"},
      {:ash_onetime, "~> 0.6.0"},
      {:ash_cloak, "~> 0.1"},
      {:replicant, replicant_requirement()},
      {:spark, "~> 2.7.0"},
      {:splode, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4.0"},
      {:postgrex, "~> 0.22.4"},
      {:ymlr, "~> 5.1.6"},
      {:simple_sat, "~> 0.1"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:cloak, "~> 1.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp ash_requirement do
    case System.get_env("ASH_REPLICANT_ASH_VERSION") do
      value when value in [nil, "", "latest"] ->
        @ash_requirement

      value ->
        with {:ok, _version} <- Version.parse(value),
             true <- Version.match?(value, @ash_requirement) do
          "== #{value}"
        else
          _ ->
            raise "ASH_REPLICANT_ASH_VERSION must be a semantic version matching #{@ash_requirement}"
        end
    end
  end

  defp replicant_requirement do
    case System.get_env("ASH_REPLICANT_REPLICANT_VERSION") do
      value when value in [nil, "", "latest"] ->
        @replicant_requirement

      value ->
        with {:ok, _version} <- Version.parse(value),
             true <- Version.match?(value, @replicant_requirement) do
          "== #{value}"
        else
          _ ->
            raise "ASH_REPLICANT_REPLICANT_VERSION must be a semantic version matching #{@replicant_requirement}"
        end
    end
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
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* NOTICE* CHANGELOG* usage-rules.md),
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
