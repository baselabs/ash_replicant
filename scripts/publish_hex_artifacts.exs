# Upload inspected archives with Hex 2.7.0, without loading a Mix project.
# Usage: mix run --no-mix-exs scripts/publish_hex_artifacts.exs NAME VERSION ARCHIVE DOCS
# No builds, tasks, persisted authentication, response bodies, or credentials in output.
defmodule PublishHexArtifacts do
  @moduledoc false

  def main([name, version, archive, docs]) do
    if Mix.Project.get(), do: raise("publication must run without a Mix project")

    # Read BOTH inspected files before either upload can begin.
    package_bytes = File.read!(archive)
    docs_bytes = File.read!(docs)
    key = System.fetch_env!("HEX_API_KEY")
    if key == "", do: raise("HEX_API_KEY is empty; publication stopped")
    Hex.start()
    auth = [key: key]

    available!(name, version)
    package_state = accepted!(Hex.API.Release.publish(nil, package_bytes, auth), "Hex package")

    docs_state =
      accepted!(
        Hex.API.ReleaseDocs.publish(nil, name, version, docs_bytes, auth),
        "Hex docs"
      )

    if :staged in [package_state, docs_state] do
      raise "Hex approval pending; recover by hand with the inspected archives, do not redispatch"
    end
  end

  def main(_argv), do: raise("usage: publish_hex_artifacts.exs NAME VERSION ARCHIVE DOCS")

  # Public only so the keyless live self-test exercises the actual upload preconditions.
  def available!(name, version) do
    exists!(Hex.API.Package.get_anonymous(nil, name), name)
    absent!(Hex.API.Release.get(nil, name, version), name, version)
  end

  defp exists!({:ok, {200, _headers, _body}}, _name), do: :ok

  defp exists!({:ok, {404, _headers, _body}}, name) do
    raise "#{name} is not on Hex; first publication is the owner's decision"
  end

  defp exists!(_result, name) do
    raise "could not confirm #{name} exists on Hex; publication refused"
  end

  defp absent!({:ok, {404, _headers, _body}}, _name, _version), do: :ok

  defp absent!({:ok, {200, _headers, _body}}, name, version) do
    raise "Hex already has #{name} #{version}; publication refused"
  end

  defp absent!(_result, name, version) do
    raise "could not confirm #{name} #{version} is absent from Hex; publication refused"
  end

  defp accepted!({:ok, {code, _headers, body}}, label) when code in 200..299 do
    IO.puts("#{label}: archive accepted")
    if is_map(body) and body["status"] == "staged", do: :staged, else: :published
  end

  defp accepted!(_result, label) do
    raise "#{label} upload failed or occupied; manual recovery required, do not redispatch"
  end
end

PublishHexArtifacts.main(System.argv())
