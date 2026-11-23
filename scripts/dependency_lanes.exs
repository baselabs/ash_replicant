defmodule AshReplicant.DependencyLanes do
  @moduledoc false

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
