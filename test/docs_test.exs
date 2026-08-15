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

  test "ADR-0007 records the source-bound checkpoint decision and is indexed" do
    assert File.exists?("docs/adr/0007-source-bound-checkpoint-effect-once.md")
    adr = File.read!("docs/adr/0007-source-bound-checkpoint-effect-once.md")
    assert adr =~ "source-bound"
    assert adr =~ "source_timeline"
    assert adr =~ ":checkpoint_unbound"

    index = File.read!("docs/adr/README.md")
    assert index =~ "0007-source-bound-checkpoint-effect-once.md"
  end

  test "ADR-0008 records the strict source-coverage decision and is indexed" do
    assert File.exists?("docs/adr/0008-strict-source-coverage.md")
    adr = File.read!("docs/adr/0008-strict-source-coverage.md")
    assert adr =~ "preflight"
    assert adr =~ "ignored_sources"
    assert adr =~ "REPLICA IDENTITY FULL"

    index = File.read!("docs/adr/README.md")
    assert index =~ "0008-strict-source-coverage.md"
  end

  test "the B4 caveat sentence is GONE and the amended rule is present" do
    agents = File.read!("AGENTS.md")
    refute agents =~ "Until roadmap B4 lands"
    assert agents =~ "activation preflight enforces"
  end

  test "ADR-0001 carries the B4 amendment (tri-modal halt + RIF + TOAST scoping)" do
    adr = File.read!("docs/adr/0001-fail-closed-multitenancy.md")
    assert adr =~ "tenant_resolution_failed"
    assert adr =~ "unchanged out-of-line"
  end

  test "AGENTS Critical Rule 6 carries the source-bound clause AND the surviving snapshot disclaimer" do
    agents = File.read!("AGENTS.md")

    # The amended watermark sentence (pinned by the B2 design note).
    assert agents =~ "of the source-bound checkpoint row"

    # The C3 snapshot disclaimer and the absent-callbacks enumeration survive
    # VERBATIM (weakening either while amending is the named drift class).
    assert agents =~ "snapshot-wide physical effect-once until C3 proves zero repeats"
    assert agents =~ "remain absent until C1–C4"
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
