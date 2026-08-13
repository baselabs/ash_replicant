#!/usr/bin/env bash
set -euo pipefail

expected_elixir="1.20.3"
expected_otp="29"

case "${1:-}" in
  "") ;;
  --self-test-elixir-mismatch)
    expected_elixir="0.0.0"
    ;;
  --self-test-otp-mismatch)
    expected_otp="0"
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
    actual_otp = :erlang.system_info(:otp_release) |> List.to_string()

    unless System.version() == expected_elixir and actual_otp == expected_otp do
      IO.puts(:stderr, "runtime identity does not match the release contract")
      System.halt(1)
    end

    IO.puts("runtime identity: Elixir #{System.version()}, OTP #{actual_otp}")
  '
