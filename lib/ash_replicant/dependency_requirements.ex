defmodule AshReplicant.DependencyRequirements do
  @moduledoc false

  # Read declarations without evaluating Mix or its environment selectors. This
  # also works while this package is compiling inside an unrelated host project.
  @attributes [
    ash: :ash_requirement,
    replicant: :replicant_requirement,
    ash_onetime: :ash_onetime_requirement,
    ash_cloak: :ash_cloak_requirement,
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
end
