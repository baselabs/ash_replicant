defmodule ReleaseChecker.MixProject do
  use Mix.Project

  def project do
    [
      app: :release_checker,
      version: "0.1.0",
      # The lock is recorded audit input; this checker executes no dependencies.
      deps: []
    ]
  end
end
