defmodule AshReplicant.DocsTest do
  use ExUnit.Case, async: true

  @participant_example_start "<!-- ash-replicant-destination-participant-example:start -->"
  @participant_example_end "<!-- ash-replicant-destination-participant-example:end -->"

  @wrapper_example_start "<!-- ash-replicant-notifier-wrapper-example:start -->"
  @wrapper_example_end "<!-- ash-replicant-notifier-wrapper-example:end -->"

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

    # C2 moved message (C1) and sink-owned batch (C2) to LIVE; the enumeration
    # still names what is genuinely absent.
    assert agents =~ "incremental-progress and\nappend-log callbacks remain absent until C3–C4"
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

  test "the published notifier wrapper example compiles AND routes through verification" do
    source = extract_example!("usage-rules.md", @wrapper_example_start, @wrapper_example_end)
    compiled = Code.compile_string(source, "usage-rules.md")

    assert compiled != [], "notifier wrapper example compiled no modules"

    Enum.each(compiled, fn {module, _binary} ->
      # A published example that would itself fail admission is worse than no
      # example: it must satisfy both halves of the contract it documents.
      assert function_exported?(module, :load, 2), "the wrapper must define load/2"
      assert function_exported?(module, :destination_participants, 2)

      assert {[:total], true} =
               AshReplicant.Notifier.probe_load(module, __MODULE__, %{name: :create})

      :code.purge(module)
      :code.delete(module)
    end)
  end

  test "ADR-0010 states the notifier wrapper amendment LANDED (no stale 'pending')" do
    adr = File.read!("docs/adr/0010-host-action-contract.md")

    refute adr =~ "implementation pending"
    refute adr =~ "not\na claim about shipped behavior"
    assert adr =~ "AshReplicant.Notifier"
    assert adr =~ "destination_notifier_unwrapped"
    assert adr =~ "notifier_load_drift"

    agents = File.read!("AGENTS.md")
    assert agents =~ "AshReplicant.Notifier"
    assert agents =~ "destination_notifier_unwrapped"
  end

  defp extract_example!(path, start_marker, end_marker) do
    content = File.read!(path)

    pattern =
      ~r/#{Regex.escape(start_marker)}\s*```elixir\s*\n(?<source>.*?)\n```\s*#{Regex.escape(end_marker)}/s

    case Regex.scan(pattern, content, capture: :all_names) do
      [[source]] -> source
      matches -> flunk("expected one example in #{path}, got #{length(matches)}")
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

  test "ADR-0009/0010 exist, are indexed, and 0006 carries the seven-component amendment (U3)" do
    readme = File.read!("docs/adr/README.md")
    assert readme =~ "0009-classified-boundaries.md"
    assert readme =~ "0010-host-action-contract.md"

    adr9 = File.read!("docs/adr/0009-classified-boundaries.md")
    assert adr9 =~ "typed telemetry" or adr9 =~ "Typed telemetry"
    assert adr9 =~ "quote_identifier" or adr9 =~ "identifier quoting home"
    assert adr9 =~ "byte_size"

    adr10 = File.read!("docs/adr/0010-host-action-contract.md")
    assert adr10 =~ "invocation"
    assert adr10 =~ "SINGLE-INVOCATION"

    adr6 = File.read!("docs/adr/0006-destination-transaction-boundary.md")
    assert adr6 =~ "Amendment (roadmap B6 / U3"
    assert adr6 =~ "per-invocation label"
  end
end
