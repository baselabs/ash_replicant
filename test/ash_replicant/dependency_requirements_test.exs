defmodule AshReplicant.DependencyRequirementsTest do
  use ExUnit.Case, async: true

  alias AshReplicant.DependencyRequirements
  alias AshReplicant.Doctor

  @mixfile Path.expand("../../mix.exs", __DIR__)

  test "Doctor embeds the public declarations even in a selector lane" do
    requirements = DependencyRequirements.read!(@mixfile)
    assert Doctor.replicant_requirement() == requirements.replicant
    assert Doctor.ash_requirement() == requirements.ash
  end

  test "reading declarations never evaluates the Mix project and refuses ambiguous values" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ash-replicant-requirements-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "mix.exs")
    source = File.read!(@mixfile)
    requirements = DependencyRequirements.read!(@mixfile)

    File.write!(path, String.replace(source, "  use Mix.Project", ~s(  raise "must not execute")))
    assert DependencyRequirements.read!(path) == requirements

    declaration = ~s(@replicant_requirement "#{requirements.replicant}")

    for replacement <- [
          "@replicant_requirement System.fetch_env!(\"UNTRUSTED\")",
          declaration <> "\n  " <> declaration,
          "@replicant_requirement \"invalid\""
        ] do
      File.write!(path, String.replace(source, declaration, replacement))

      assert_raise ArgumentError, "public dependency declarations are invalid", fn ->
        DependencyRequirements.read!(path)
      end
    end
  end
end
