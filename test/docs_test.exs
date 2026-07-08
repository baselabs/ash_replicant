defmodule AshReplicant.DocsTest do
  use ExUnit.Case, async: true

  test "the tracked family docs exist and carry the binding rules" do
    for f <-
          ~w(CLAUDE.md AGENTS.md README.md CHANGELOG.md usage-rules.md CONTRIBUTING.md LICENSE NOTICE) do
      assert File.exists?(f), "missing tracked doc: #{f}"
    end

    assert File.read!("AGENTS.md") =~ "tenant-blind"
    assert File.read!("AGENTS.md") =~ "value-free"
    assert File.exists?("docs/CHARTER.md")
  end
end
