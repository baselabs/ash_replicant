#!/usr/bin/env bash
# Two independent source trees, locked dependencies, and byte-identical rendered docs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?usage: build-release-docs.sh ABSOLUTE_ARCHIVE_PATH}"
[[ "$output" == /* && ! -e "$output" && ! -e "$output.rendered" ]] || exit 2
work="$(mktemp -d "${RUNNER_TEMP:?}/ash-replicant-docs.XXXXXX")"
complete=false
cleanup() {
  rm -rf "$work"
  if [[ "$complete" != true ]]; then
    rm -rf "$output" "$output.rendered"
  fi
}
trap cleanup EXIT
unset ASH_REPLICANT_ASH_VERSION ASH_REPLICANT_REPLICANT_VERSION ASH_REPLICANT_ONETIME_VERSION
export MIX_ENV=dev
for build in first second; do
  tree="$work/$build"
  mkdir "$tree"
  git -C "$root" archive HEAD | tar -x -C "$tree"
  (
    cd "$tree"
    mix deps.get --check-locked
    mix docs --warnings-as-errors
  )
  (cd "$work" && mix run --no-mix-exs "$root/scripts/build-docs-archive.exs" \
    "$tree/doc" "$work/$build.tar.gz")
  python3 -I "$root/scripts/check-docs-archive.py" "$work/$build.tar.gz" "$tree/doc"
done
cmp "$work/first.tar.gz" "$work/second.tar.gz"
cp "$work/first.tar.gz" "$output"
cp -R "$work/first/doc" "$output.rendered"
complete=true
echo 'release docs: independent renders and archives are byte-identical'
