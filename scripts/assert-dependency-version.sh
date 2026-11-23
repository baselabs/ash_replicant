#!/usr/bin/env bash
set -euo pipefail

newest=false
hex_response=""
lockfile="$(cd "$(dirname "$0")/.." && pwd)/mix.lock"
usage='usage: assert-dependency-version.sh [--lock PATH] [--newest [--hex-response PATH]] DEPENDENCY [REQUIREMENT]'
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --lock)
      [[ "$#" -ge 2 && -n "$2" ]] || { echo "$usage" >&2; exit 2; }
      lockfile="$2"
      shift 2
      ;;
    --newest)
      newest=true
      shift
      ;;
    --hex-response)
      [[ "$#" -ge 2 && -n "$2" ]] || { echo "$usage" >&2; exit 2; }
      hex_response="$2"
      shift 2
      ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
[[ "$#" -eq 1 || "$#" -eq 2 ]] || { echo "$usage" >&2; exit 2; }
[[ -z "$hex_response" || "$newest" == true ]] || exit 2
dependency="$1"
if [[ ! "$dependency" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "dependency assertion name is invalid" >&2
  exit 2
fi

if [[ "$#" -eq 2 ]]; then
  requirement="$2"
else
  requirement="$(elixir "$(dirname "$0")/dependency-requirements.exs" --requirement "$dependency")"
fi


# Read the lock as recorded input, independently of declared or fetched deps.
# Recorded checker fixtures are data, never an Elixir project.
version="$(ASH_REPLICANT_ASSERTED_DEPENDENCY="$dependency" \
  ASH_REPLICANT_ASSERTED_LOCK="$lockfile" elixir -e '
  Mix.start()
  dependency = System.fetch_env!("ASH_REPLICANT_ASSERTED_DEPENDENCY")

  entry =
    System.fetch_env!("ASH_REPLICANT_ASSERTED_LOCK")
    |> Mix.Dep.Lock.read()
    |> Enum.find(fn {name, _lock} -> to_string(name) == dependency end)

  case entry do
    {_name, {:hex, _package, version, _checksum, _managers, _deps, _repo, _outer}}
    when is_binary(version) ->
      IO.write(version)

    _ ->
      IO.puts(:stderr, "could not resolve the locked dependency version")
      System.halt(1)
  end
')"

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
          IO.puts(:stderr, "locked dependency differs from newest compatible Hex release")
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
