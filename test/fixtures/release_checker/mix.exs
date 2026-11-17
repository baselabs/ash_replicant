defmodule ReleaseChecker.MixProject do
  use Mix.Project

  def project do
    [
      app: :release_checker,
      version: "0.1.0",
      # The lock is recorded audit input; this checker executes no dependencies.
      deps: [],
      # This historical lock is data, never executed (deps is empty and guarded).
      # These Ash findings therefore have no runtime exposure in this fixture.
      hex: [ignore_advisories: ["EEF-CVE-2026-96581", "EEF-CVE-2026-114214"]]
    ]
  end
end
