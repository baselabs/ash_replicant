Code.require_file(Path.expand("../lib/ash_replicant/dependency_requirements.ex", __DIR__))

alias AshReplicant.DependencyRequirements

case System.argv() do
  ["--lanes", mixfile] ->
    mixfile
    |> DependencyRequirements.read!()
    |> DependencyRequirements.lanes()
    |> JSON.encode!()
    |> IO.puts()

  [mode, dependency] when mode in ["--requirement", "--floor"] ->
    requirements = DependencyRequirements.read!(Path.expand("../mix.exs", __DIR__))

    {_name, requirement} =
      Enum.find(requirements, fn {name, _} -> to_string(name) == dependency end)

    IO.write(if mode == "--floor", do: DependencyRequirements.floor!(requirement), else: requirement)
end
