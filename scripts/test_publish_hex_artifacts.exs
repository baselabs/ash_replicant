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

PublishHexArtifacts.available!("ash_replicant", "999999.0.0")

# A dot cannot occur in a Hex package name, so this real lookup cannot name a package.
PublishHexArtifactsSelfTest.reject(
  "ash_replicant.invalid is not on Hex; first publication is the owner's decision",
  fn -> PublishHexArtifacts.available!("ash_replicant.invalid", "999999.0.0") end
)

PublishHexArtifactsSelfTest.reject(
  "Hex already has ash_replicant 1.6.3; publication refused",
  fn -> PublishHexArtifacts.available!("ash_replicant", "1.6.3") end
)

IO.puts("upload preconditions: live Hex self-tests PASS (no upload or key)")
