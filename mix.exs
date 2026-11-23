defmodule AshReplicant.MixProject do
  use Mix.Project

  @version "1.6.4"
  @source_url "https://github.com/baselabs/ash_replicant"
  @ash_requirement ">= 3.37.3 and < 4.0.0-0"
  @replicant_requirement ">= 1.6.0 and < 2.0.0-0"
  @ash_onetime_requirement ">= 1.3.2 and < 2.0.0-0"

  @ash_postgres_requirement "~> 2.13"
  @ash_cloak_requirement ">= 0.4.0 and < 1.0.0-0"
  @igniter_requirement ">= 0.8.4 and < 1.0.0-0"
  @spark_requirement "~> 2.7.0"
  @splode_requirement "~> 0.3"
  @jason_requirement "~> 1.4"
  @telemetry_requirement "~> 1.4.0"
  @postgrex_requirement "~> 0.23"
  @ymlr_requirement "~> 5.1.6"
  @simple_sat_requirement "~> 0.1"

  def project do
    [
      app: :ash_replicant,
      version: @version,
      elixir: "~> 1.20.3",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps() |> select_requirements(),
      # EEF-CVE-2026-95105 affects only Cloak's AES-CTR cipher; ash_replicant configures
      # AES-GCM only, enforced by test/cloak_cipher_guard_test.exs.
      # Cloak has no fixed release yet; remove this entry and upgrade when it ships.
      hex: [ignore_advisories: ["EEF-CVE-2026-95105"]],
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

  def application, do: [mod: {AshReplicant.Application, []}, extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, @ash_requirement},
      # The committed test migrations match the reviewed compatibility lock's
      # generator. The drift report checks newer upstream releases separately.
      {:ash_postgres, @ash_postgres_requirement},
      {:ash_onetime, @ash_onetime_requirement},
      # Security floor: EEF-CVE-2026-81319 and EEF-CVE-2026-81322 affect
      # every ash_cloak release below 0.4.0; a consumer must not be able
      # to resolve to a vulnerable one.
      {:ash_cloak, @ash_cloak_requirement},
      {:replicant, @replicant_requirement},
      # The install codemod surface (I01). OPTIONAL for consumers and at
      # runtime: `mix ash_replicant.install` compiles to an actionable stub when
      # Igniter is absent, so no shipped library code depends on it.
      {:igniter, @igniter_requirement, optional: true},
      {:spark, @spark_requirement},
      {:splode, @splode_requirement},
      {:jason, @jason_requirement},
      {:telemetry, @telemetry_requirement},
      {:postgrex, @postgrex_requirement},
      {:ymlr, @ymlr_requirement},
      {:simple_sat, @simple_sat_requirement},
      {:ex_doc, "== 0.40.4", only: :dev, runtime: false},
      {:cloak, "~> 1.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp select_requirements(dependencies) do
    selectors = %{
      ash: "ASH_REPLICANT_ASH_VERSION",
      replicant: "ASH_REPLICANT_REPLICANT_VERSION",
      ash_onetime: "ASH_REPLICANT_ONETIME_VERSION"
    }

    Enum.map(dependencies, fn dependency ->
      selector = selectors[elem(dependency, 0)]
      requirement = elem(dependency, 1)

      case selector && System.get_env(selector) do
        value when value in [nil, "", "latest"] ->
          dependency

        value ->
          with {:ok, _version} <- Version.parse(value),
               true <- Version.match?(value, requirement) do
            put_elem(dependency, 1, "== #{value}")
          else
            _ -> raise "#{selector} must be a semantic version matching #{requirement}"
          end
      end
    end)
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
      # EPUB embeds build time; HTML and Markdown are reproducible.
      formatters: ["html", "markdown"],
      source_ref: "v#{@version}",
      extras: ["README.md", "usage-rules.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"]
    ]
  end
end
