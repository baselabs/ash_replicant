defmodule AshReplicant.DependencyRequirementsTest do
  use ExUnit.Case, async: true

  alias AshReplicant.DependencyRequirements
  alias AshReplicant.Doctor

  @mixfile Path.expand("../../mix.exs", __DIR__)

  test "Doctor embeds the public declarations even in a selector lane" do
    requirements = DependencyRequirements.read!(@mixfile)
    assert Doctor.replicant_requirement() == requirements.replicant
    assert Doctor.ash_requirement() == requirements.ash
    assert Doctor.db_connection_requirement() == requirements.db_connection
  end

  test "the public dependency set comes from deps, including new attributes" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ash-replicant-public-set-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "mix.exs")
    source = File.read!(@mixfile)

    with_attribute =
      source
      |> String.replace(
        "  use Mix.Project",
        "  use Mix.Project\n  @extra_public_requirement \"~> 7.8\""
      )
      |> String.replace(
        "      {:ash,",
        "      {:extra_public, @extra_public_requirement},\n      {:ash,"
      )

    with_attribute =
      String.replace(
        with_attribute,
        "  def project do",
        "  defp extra_public_requirement, do: \"~> 9.0\"\n\n  def project do"
      )

    File.write!(path, with_attribute)
    assert DependencyRequirements.read!(path).extra_public == "~> 7.8"

    for reference <- [~s("~> 7.8"), "@missing_requirement", "extra_public_requirement()"] do
      mutated =
        String.replace(
          with_attribute,
          "{:extra_public, @extra_public_requirement}",
          "{:extra_public, #{reference}}"
        )

      File.write!(path, mutated)

      assert_raise ArgumentError, "public dependency declarations are invalid", fn ->
        DependencyRequirements.read!(path)
      end
    end
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
          "@replicant_requirement \"invalid\"",
          "@missing_requirement \"~> 7.8\""
        ] do
      File.write!(path, String.replace(source, declaration, replacement))

      assert_raise ArgumentError, "public dependency declarations are invalid", fn ->
        DependencyRequirements.read!(path)
      end
    end
  end
end
