#!/usr/bin/env bash
# Keyless registry read-back: retain served docs and report their published commit.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?usage: read-release-assets.sh VERSION PACKAGE_ARCHIVE ASSET_DIRECTORY}"
package="${2:?}"
assets="${3:?}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && ! -e "$assets" ]] || exit 2
work="$(mktemp -d "${RUNNER_TEMP:?}/ash-replicant-readback.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# Refresh the actual default branch; missing or shallow history fails inspection.
git -C "$root" fetch --no-tags origin refs/heads/main:refs/remotes/origin/main
fetch_archive() {
  local url="$1" output="$2" status
  status="$(curl --silent --show-error --connect-timeout 10 --max-time 60 \
    --output "$output" --write-out '%{http_code}' "$url")"
  [[ "$status" == 200 ]] || { echo 'Hex archive read-back is unavailable' >&2; exit 1; }
}
fetch_archive "https://repo.hex.pm/tarballs/ash_replicant-$version.tar" "$work/package.tar"
cmp "$package" "$work/package.tar"
fetch_archive "https://repo.hex.pm/docs/ash_replicant-$version.tar.gz" "$work/docs.tar.gz"
python3 -I "$root/scripts/check-docs-archive.py" "$work/docs.tar.gz" \
  --version "$version" --commit "${GITHUB_SHA:?}" --repository "$root" \
  --commit-output "$work/published-commit" --assets "$assets" --package-archive "$work/package.tar"
published_commit="$(cat "$work/published-commit")"
printf 'published_commit=%s\n' "$published_commit" >> "${GITHUB_OUTPUT:?}"
echo "Release read-back: published commit $published_commit"
