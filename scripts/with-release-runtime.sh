#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "usage: with-release-runtime.sh COMMAND [ARGUMENT ...]" >&2
  exit 2
fi

erlang_root="$(asdf where erlang 29.0.3)"
elixir_root="$(asdf where elixir 1.20.3-otp-29)"

export PATH="$erlang_root/bin:$elixir_root/bin:$PATH"
exec "$@"
