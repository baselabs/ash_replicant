#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "usage: with-release-runtime.sh COMMAND [ARGUMENT ...]" >&2
  exit 2
fi

# With asdf, select the pinned release runtime explicitly. Without it (CI's
# setup-beam, or a Linux host using another installer), the runtime already on
# PATH must prove it is the pinned one before the command runs.
# Both read the pins from `.tool-versions`.
root="$(cd "$(dirname "$0")/.." && pwd)"
if command -v asdf >/dev/null 2>&1; then
  erlang_pin=""
  elixir_pin=""
  while read -r tool version; do
    case "$tool" in
      erlang) erlang_pin="$version" ;;
      elixir) elixir_pin="$version" ;;
    esac
  done < "$root/.tool-versions"
  erlang_root="$(asdf where erlang "$erlang_pin")"
  elixir_root="$(asdf where elixir "$elixir_pin")"
  export PATH="$erlang_root/bin:$elixir_root/bin:$PATH"
else
  "$(cd "$(dirname "$0")" && pwd)/assert-runtime-version.sh"
fi

exec "$@"
