#!/usr/bin/env bash
set -euo pipefail

# The runtime on PATH must be exactly the one `.tool-versions` pins: the Elixir
# release and the full Erlang/OTP release, not just its major.
root="$(cd "$(dirname "$0")/.." && pwd)"
expected_elixir=""
expected_otp=""
while read -r tool version; do
  case "$tool" in
    elixir) expected_elixir="${version%-otp-*}" ;;
    erlang) expected_otp="$version" ;;
  esac
done < "$root/.tool-versions"

if [[ -z "$expected_elixir" || -z "$expected_otp" ]]; then
  echo "runtime pins are missing from .tool-versions" >&2
  exit 1
fi

case "${1:-}" in
  "") ;;
  --self-test-elixir-mismatch)
    expected_elixir="0.0.0"
    ;;
  --self-test-otp-mismatch)
    expected_otp="0.0.0"
    ;;
  *)
    echo "usage: assert-runtime-version.sh [--self-test-elixir-mismatch|--self-test-otp-mismatch]" >&2
    exit 2
    ;;
esac

ASH_REPLICANT_EXPECTED_ELIXIR="$expected_elixir" \
ASH_REPLICANT_EXPECTED_OTP="$expected_otp" \
  elixir -e '
    expected_elixir = System.fetch_env!("ASH_REPLICANT_EXPECTED_ELIXIR")
    expected_otp = System.fetch_env!("ASH_REPLICANT_EXPECTED_OTP")
    major = :erlang.system_info(:otp_release) |> List.to_string()

    actual_otp =
      case File.read(Path.join([:code.root_dir(), "releases", major, "OTP_VERSION"])) do
        {:ok, version} -> String.trim(version)
        {:error, _reason} -> major
      end

    unless System.version() == expected_elixir and actual_otp == expected_otp do
      IO.puts(:stderr, "runtime identity does not match the release contract")
      System.halt(1)
    end

    IO.puts("runtime identity: Elixir #{System.version()}, OTP #{actual_otp}")
  '
