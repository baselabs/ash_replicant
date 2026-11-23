Code.require_file(Path.expand("../lib/ash_replicant/dependency_requirements.ex", __DIR__))

Code.require_file(Path.join(__DIR__, "dependency_lanes.exs"))

alias AshReplicant.DependencyLanes
alias AshReplicant.DependencyRequirements

case System.argv() do
  ["--lanes", mixfile] ->
    mixfile
    |> DependencyRequirements.read!()
    |> DependencyLanes.lanes()
    |> JSON.encode!()
    |> IO.puts()

  [mode, dependency] when mode in ["--requirement", "--floor"] ->
    requirements = DependencyRequirements.read!(Path.expand("../mix.exs", __DIR__))

    {_name, requirement} =
      Enum.find(requirements, fn {name, _} -> to_string(name) == dependency end)

    IO.write(if mode == "--floor", do: DependencyLanes.floor!(requirement), else: requirement)
end
