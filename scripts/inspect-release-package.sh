#!/usr/bin/env bash
set -euo pipefail
tarball="${1:?usage: inspect-release-package.sh TARBALL}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-publish-package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/outer" "$work/package"
tar -xf "$tarball" -C "$work/outer"
tar -xzf "$work/outer/contents.tar.gz" -C "$work/package"
# Match Hex's --unpack file set, including its wrapper metadata file.
cp "$work/outer/metadata.config" "$work/package/hex_metadata.config"
if ! diff -u "$root/scripts/release-package-files.txt" \
  <(cd "$work/package" && find . \( -type f -o -type l \) | sed 's|^./||' | LC_ALL=C sort); then
  echo 'publish-release: package files differ from the release allowlist' >&2
  exit 1
fi
echo 'publish-release: built package matches the release allowlist'
