defmodule AshReplicant.DependencyRequirements do
  @moduledoc false

  # Read declarations without evaluating Mix or its environment selectors. This
  # also works while this package is compiling inside an unrelated host project.
  @attributes [
    ash: :ash_requirement,
    replicant: :replicant_requirement,
    ash_onetime: :onetime_requirement,
    ash_cloak: :cloak_requirement,
    ash_postgres: :ash_postgres_requirement,
    igniter: :igniter_requirement,
    spark: :spark_requirement,
    splode: :splode_requirement,
    jason: :jason_requirement,
    telemetry: :telemetry_requirement,
    postgrex: :postgrex_requirement,
    ymlr: :ymlr_requirement,
    simple_sat: :simple_sat_requirement
  ]

  def attributes, do: @attributes

  def read!(mixfile) do
    {:defmodule, _, [{:__aliases__, _, [:AshReplicant, :MixProject]}, [do: body]]} =
      mixfile |> File.read!() |> Code.string_to_quoted!()

    expressions =
      case body do
        {:__block__, _, expressions} -> expressions
        expression -> [expression]
      end

    Map.new(@attributes, fn {dependency, attribute} ->
      [requirement] = for {:@, _, [{^attribute, _, [value]}]} <- expressions, do: value
      true = is_binary(requirement)
      {:ok, _parsed} = Version.parse_requirement(requirement)
      {dependency, requirement}
    end)
  rescue
    _ -> raise ArgumentError, "public dependency declarations are invalid"
  end

  def floor!(requirement) do
    [_, version] =
      Regex.run(~r/\A(?:>=|~>|==) ([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?: and < \S+)?\z/, requirement)

    version = if length(String.split(version, ".")) == 2, do: version <> ".0", else: version
    true = Version.match?(version, requirement)
    version
  rescue
    _ -> raise ArgumentError, "public dependency lower bound is invalid"
  end

  def lanes(requirements) do
    for {label, lockfile, mode} <- [
          {"exact-floors", "locks/exact-floors.lock", :floor},
          {"current-lock", "mix.lock", ""},
          {"latest-compatible", "locks/latest-compatible.lock", "latest"}
        ] do
      Enum.reduce(
        [ash: :ash, replicant: :replicant, onetime: :ash_onetime],
        %{"label" => label, "lockfile" => lockfile},
        fn {prefix, dependency}, row ->
          requirement = Map.fetch!(requirements, dependency)
          selector = if mode == :floor, do: floor!(requirement), else: mode
          selected = if mode == :floor, do: "== " <> selector, else: requirement

          row
          |> Map.put("#{prefix}_selector", selector)
          |> Map.put("#{prefix}_requirement", selected)
        end
      )
    end
  end
end
