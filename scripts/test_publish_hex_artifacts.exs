# Load the real uploader module, without executing its publication entrypoint.
if Mix.Project.get(), do: raise("upload preconditions must run without a Mix project")

path = Path.join(__DIR__, "publish_hex_artifacts.exs")
{:ok, {:__block__, _, [module, _entrypoint]}} = Code.string_to_quoted(File.read!(path))
Code.compile_quoted(module, path)
Hex.start()

defmodule PublishHexArtifactsSelfTest do
  def reject(expected, function) do
    function.()
    raise "upload preconditions accepted a forbidden release"
  rescue
    error in RuntimeError ->
      unless error.message == expected, do: reraise(error, __STACKTRACE__)
  end
end

PublishHexArtifacts.existing_package!(
  Hex.API.Package.get_anonymous(nil, "ash_replicant"),
  "ash_replicant"
)
:fresh =
  PublishHexArtifacts.release_state!(
    Hex.API.Release.get(nil, "ash_replicant", "999999.0.0"),
    "999999.0.0",
    String.duplicate("0", 64)
  )

# A dot cannot occur in a Hex package name, so this real lookup cannot name a package.
PublishHexArtifactsSelfTest.reject(
  "the name ash_replicant.invalid is not on Hex; a first publication is the owner's decision",
  fn ->
    PublishHexArtifacts.existing_package!(
      Hex.API.Package.get_anonymous(nil, "ash_replicant.invalid"),
      "ash_replicant.invalid"
    )
  end
)

{:ok, {200, _, metadata}} = Hex.API.Release.get(nil, "ash_replicant", "1.6.3")
{:held, true} =
  PublishHexArtifacts.release_state!({:ok, {200, [], metadata}}, "1.6.3", metadata["checksum"])
:ok =
  PublishHexArtifacts.package_read_back!(
    Hex.Repo.get_tarball("hexpm", "ash_replicant", "1.6.3"),
    metadata["checksum"]
  )

PublishHexArtifactsSelfTest.reject(
  "Hex release identity does not match the built package; publication refused",
  fn ->
    PublishHexArtifacts.release_state!(
      {:ok, {200, [], metadata}},
      "1.6.3",
      String.duplicate("0", 64)
    )
  end
)

IO.puts("upload preconditions: live Hex self-tests PASS (no upload or key)")
