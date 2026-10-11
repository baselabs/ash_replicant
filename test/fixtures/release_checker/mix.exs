defmodule ReleaseChecker.MixProject do
  use Mix.Project

  def project do
    [
      app: :release_checker,
      version: "0.1.0",
      deps: [{:ash, ">= 3.34.6 and < 4.0.0-0"}, {:replicant, ">= 1.4.0 and < 2.0.0-0"}]
    ]
  end
end
