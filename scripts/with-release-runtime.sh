#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "usage: with-release-runtime.sh COMMAND [ARGUMENT ...]" >&2
  exit 2
fi

# Select the reader's runtime with asdf when available; otherwise verify PATH.
root="$(cd "$(dirname "$0")/.." && pwd)"
pins="$("$root/scripts/toolchain.sh" "$root/.tool-versions")"
elixir_pin=""
erlang_pin=""
while IFS='=' read -r name version; do
  case "$name" in
    elixir) elixir_pin="$version" ;;
    otp) erlang_pin="$version" ;;
  esac
done <<< "$pins"
[[ -n "$elixir_pin" && -n "$erlang_pin" ]] || { echo 'runtime pins are missing' >&2; exit 1; }
if command -v asdf >/dev/null 2>&1; then
  erlang_root="$(asdf where erlang "$erlang_pin")"
  elixir_root="$(asdf where elixir "$elixir_pin")"
  export PATH="$erlang_root/bin:$elixir_root/bin:$PATH"
fi
"$root/scripts/toolchain.sh" --installed "elixir=$elixir_pin" "erlang=$erlang_pin"

exec "$@"
