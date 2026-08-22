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

  test "AGENTS carries the source-bound clause, snapshot opt-in cost, and what is still absent" do
    agents = File.read!("AGENTS.md")

    # The amended watermark sentence (pinned by the B2 design note).
    assert agents =~ "of the source-bound checkpoint row"

    # S02 replaced the C3 disclaimer: whole-table retry IS effect-once now — but
    # only for a resource that OPTS IN. The cost of not opting in must stay
    # stated, because a reader who skips it inherits stale rows silently. This
    # pin is the successor to "do not claim snapshot-wide physical effect-once
    # until C3 proves zero repeats"; weakening it while amending is the named
    # drift class.
    assert agents =~ "Whole-table snapshot retry is effect-once for a resource that opts in"

    assert agents =~
             "A snapshot-backed resource that does NOT opt into `snapshot_provenance` keeps\nrows the source has dropped"

    # P01/ADR-0018: append-log delivery is LIVE. The pin moved from "still
    # absent" to the live claim, and the two clauses a reader most needs are
    # pinned with it — the exclusivity of the sink kind (a mixed set cannot be
    # represented by `sink_kind/0` at all) and the origin floor's completeness
    # limit. A doc that goes back to promising a state mirror's semantics for a
    # log, or drops the floor caveat, reds here.
    assert agents =~
             "incremental snapshot progress (`snapshot_progress/0`, ADR-0017), and append-log\ndelivery (`sink_kind/0` + `handle_slot_origin/2`, ADR-0018) are live."

    assert agents =~ "A generated sink is EXCLUSIVELY a state mirror or an append log"
    assert agents =~ "no completeness claim\ncovers data below it"
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

  test "the published docs carry the I01 install path and its manual equivalent" do
    readme = File.read!("README.md")

    assert readme =~ "mix igniter.install ash_replicant"
    assert readme =~ "mix ash_replicant.install"
    assert readme =~ "### Manual installation"

    # The tied-out block the installer's own test compares against. Exactly one,
    # both markers present — an unclosed or duplicated block would silently
    # narrow what the tie-out compares.
    assert length(String.split(readme, "<!-- ash-replicant-manual-install-modules:start -->")) ==
             2

    assert length(String.split(readme, "<!-- ash-replicant-manual-install-modules:end -->")) == 2

    # The refusals and the no-op-until-configured posture are the two facts an
    # adopter must not have to discover by running it.
    assert readme =~ "supervises *nothing* until you configure it"
    assert readme =~ "It stops rather than guess."
    assert readme =~ ~r/preserving\s+every existing formatter entry/

    usage = File.read!("usage-rules.md")
    assert usage =~ "## Installing"
    assert usage =~ "The installer refuses rather than guesses."

    agents = File.read!("AGENTS.md")
    assert agents =~ "The install path generates host-owned code and never guesses"

    changelog = File.read!("CHANGELOG.md")
    assert changelog =~ "Fresh-install Igniter path"
  end
end
