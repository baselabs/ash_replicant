defmodule AshReplicant.DependencyRequirements do
  @moduledoc false

  # Read declarations without evaluating Mix or its environment selectors. This
  # also works while this package is compiling inside an unrelated host project.
  def read!(mixfile) do
    {:defmodule, _, [{:__aliases__, _, [:AshReplicant, :MixProject]}, [do: body]]} =
      mixfile |> File.read!() |> Code.string_to_quoted!()

    expressions =
      case body do
        {:__block__, _, expressions} -> expressions
        expression -> [expression]
      end

    [dependencies] =
      for {:defp, _, [{:deps, _, arguments}, [do: dependencies]]} <- expressions,
          arguments in [nil, []],
          do: dependencies

    true = is_list(dependencies)

    declarations =
      Enum.flat_map(dependencies, fn dependency ->
        {name, reference, options} = dependency_parts!(dependency)

        if Keyword.has_key?(options, :only) do
          []
        else
          attribute = declaration_attribute!(reference)
          true = Atom.to_string(attribute) == "#{name}_requirement"
          [requirement] = for {:@, _, [{^attribute, _, [value]}]} <- expressions, do: value
          true = is_binary(requirement)
          {:ok, _parsed} = Version.parse_requirement(requirement)
          [{name, requirement}]
        end
      end)

    requirements = Map.new(declarations)
    true = map_size(requirements) == length(declarations)
    requirements
  rescue
    _ -> raise ArgumentError, "public dependency declarations are invalid"
  end

  defp dependency_parts!({name, reference}) when is_atom(name), do: {name, reference, []}

  defp dependency_parts!({:{}, _, [name, reference, options]})
       when is_atom(name) and is_list(options) do
    true = Keyword.keyword?(options)
    {name, reference, options}
  end

  defp declaration_attribute!({:@, _, [{name, _, _}]}), do: name
end
