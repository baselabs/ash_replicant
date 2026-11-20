#!/usr/bin/env bash
# Render once with locked dependencies; inspect the archive and its release provenance.
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
tree="$work/source"
mkdir "$tree"
git -C "$root" archive HEAD | tar -x -C "$tree"
(
  cd "$tree"
  mix deps.get --check-locked
  mix docs --warnings-as-errors
)
version="$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$tree/mix.exs")"
commit="$(git -C "$root" rev-parse HEAD)"
[[ "$commit" == "${GITHUB_SHA:?}" ]] || exit 1
python3 - "$tree/doc/release.json" "$version" "$commit" <<'PROVENANCE'
import json
from pathlib import Path
import sys
path, version, commit = sys.argv[1:]
Path(path).write_text(json.dumps({"package": "ash_replicant", "version": version, "commit": commit}) + "\n")
PROVENANCE
(cd "$work" && mix run --no-mix-exs "$root/scripts/build-docs-archive.exs" \
  "$tree/doc" "$work/docs.tar.gz")
python3 -I "$root/scripts/check-docs-archive.py" "$work/docs.tar.gz" "$tree/doc" \
  --version "$version" --commit "$commit"
cp "$work/docs.tar.gz" "$output"
cp -R "$tree/doc" "$output.rendered"
complete=true
echo 'release docs: rendered once; archive contents and release provenance inspected'
