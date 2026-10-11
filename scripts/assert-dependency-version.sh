#!/usr/bin/env bash
set -euo pipefail

newest=false
hex_response=""
if [[ "${1:-}" == --newest ]]; then
  newest=true
  shift
fi
if [[ "${1:-}" == --hex-response ]]; then
  [[ "$newest" == true ]] || exit 2
  hex_response="${2:?--hex-response requires a recorded Hex body}"
  shift 2
fi
dependency="${1:?usage: assert-dependency-version.sh [--newest] DEPENDENCY REQUIREMENT}"
requirement="${2:?usage: assert-dependency-version.sh [--newest] DEPENDENCY REQUIREMENT}"
[[ "$#" -eq 2 ]] || exit 2

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

if [[ "$newest" == true ]]; then
  parser="$(cd "$(dirname "$0")" && pwd)/hex-release-candidates.py"
  if [[ -n "$hex_response" ]]; then
    # Explicit replay of a checked-in provider response for offline self-tests.
    candidates="$(python3 "$parser" "$hex_response" 0 200)"
  else
    response="$(mktemp "${TMPDIR:-/tmp}/ash-replicant-hex-releases.XXXXXX")"
    trap 'rm -f "$response"' EXIT
    transport=0
    status="$(curl -sSL --max-time 30 --retry 2 --write-out '%{http_code}' \
      "https://hex.pm/api/packages/$dependency" -o "$response")" || transport=$?
    candidates="$(python3 "$parser" "$response" "$transport" "$status")"
  fi
  ASH_REPLICANT_ASSERTED_VERSION="$version" \
  ASH_REPLICANT_ASSERTED_REQUIREMENT="$requirement" \
  ASH_REPLICANT_HEX_CANDIDATES="$candidates" elixir -e '
    requirement = System.fetch_env!("ASH_REPLICANT_ASSERTED_REQUIREMENT")
    versions =
      System.fetch_env!("ASH_REPLICANT_HEX_CANDIDATES")
      |> String.split("\n", trim: true)
      |> Enum.map(&Version.parse!/1)
      |> Enum.filter(&(&1.pre == [] and Version.match?(&1, requirement)))
      |> Enum.sort({:desc, Version})
    case versions do
      [newest | _] ->
        locked = System.fetch_env!("ASH_REPLICANT_ASSERTED_VERSION")
        unless Version.compare(locked, newest) == :eq do
          IO.puts(:stderr, "locked #{locked} differs from newest compatible Hex release #{newest}")
          System.halt(1)
        end
      [] ->
        IO.puts(:stderr, "Hex returned no non-retired stable release matching the requirement")
        System.halt(1)
    end
  '
  echo "$dependency=$version is the newest non-retired stable Hex release satisfying $requirement"
  exit 0
fi

echo "$dependency=$version satisfies $requirement"
