#!/usr/bin/env bash
set -euo pipefail

dependency="${1:?usage: assert-dependency-version.sh DEPENDENCY REQUIREMENT}"
requirement="${2:?usage: assert-dependency-version.sh DEPENDENCY REQUIREMENT}"

if [[ ! "$dependency" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "invalid dependency name: $dependency" >&2
  exit 2
fi

dependency_output="$(mix deps "$dependency")"
version="$(awk '$1 == "locked" && $2 == "at" { print $3; exit }' <<<"$dependency_output")"

if [[ -z "$version" ]]; then
  echo "could not resolve locked version for dependency: $dependency" >&2
  exit 1
fi

ASH_REPLICANT_ASSERTED_VERSION="$version" \
ASH_REPLICANT_ASSERTED_REQUIREMENT="$requirement" \
  elixir -e '
    version = System.fetch_env!("ASH_REPLICANT_ASSERTED_VERSION")
    requirement = System.fetch_env!("ASH_REPLICANT_ASSERTED_REQUIREMENT")

    with {:ok, parsed_version} <- Version.parse(version),
         {:ok, parsed_requirement} <- Version.parse_requirement(requirement),
         true <- Version.match?(parsed_version, parsed_requirement) do
      :ok
    else
      :error ->
        IO.puts(:stderr, "dependency version assertion input is invalid")
        System.halt(2)

      false ->
        IO.puts(:stderr, "dependency version does not satisfy requirement")
        System.halt(1)
    end
  '

echo "$dependency=$version satisfies $requirement"
