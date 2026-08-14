defmodule AshReplicant.DocsTest do
  use ExUnit.Case, async: true

  @participant_example_start "<!-- ash-replicant-destination-participant-example:start -->"
  @participant_example_end "<!-- ash-replicant-destination-participant-example:end -->"

  test "the tracked family docs exist and carry the binding rules" do
    for f <-
          ~w(CLAUDE.md AGENTS.md README.md CHANGELOG.md usage-rules.md CONTRIBUTING.md LICENSE NOTICE) do
      assert File.exists?(f), "missing tracked doc: #{f}"
    end

    assert File.read!("AGENTS.md") =~ "tenant-blind"
    assert File.read!("AGENTS.md") =~ "value-free"
    assert File.exists?("docs/CHARTER.md")
  end

  test "published destination participant examples compile against the public API" do
    for path <- ["README.md", "usage-rules.md"] do
      source = extract_participant_example!(path)
      compiled = Code.compile_string(source, path)

      assert compiled != [], "destination participant example compiled no modules: #{path}"

      Enum.each(compiled, fn {module, _binary} ->
        :code.purge(module)
        :code.delete(module)
      end)
    end
  end

  defp extract_participant_example!(path) do
    content = File.read!(path)

    pattern =
      ~r/#{Regex.escape(@participant_example_start)}\s*```elixir\s*\n(?<source>.*?)\n```\s*#{Regex.escape(@participant_example_end)}/s

    case Regex.scan(pattern, content, capture: :all_names) do
      [[source]] ->
        source

      matches ->
        flunk("expected one destination participant example in #{path}, got #{length(matches)}")
    end
  end
end
