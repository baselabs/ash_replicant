#!/usr/bin/env bash
set -euo pipefail
version="${1:?usage: publish-release.sh VERSION [--check]}"
[[ "$#" -eq 1 || ( "$#" -eq 2 && "$2" == --check ) ]] || exit 2
cd "$(dirname "$0")/.."
scripts/assert-release-tree.sh "$version" "v$version" >/dev/null
fail() { echo "publish-release: $1" >&2; exit 1; }
[[ -f .env ]] || fail 'repo-root .env is required'
# Do not expose the credential even if the caller enabled shell tracing.
set +x
unset HEX_API_KEY
source .env >/dev/null 2>&1 || fail 'could not load repo-root .env'
[[ -n "${HEX_API_KEY:-}" ]] || fail 'HEX_API_KEY is required in repo-root .env'
export HEX_API_KEY
export MIX_ENV=dev
work="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-publish.XXXXXX")"
trap 'rm -rf "$work"' EXIT
env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION \
  -u ASH_REPLICANT_ONETIME_VERSION scripts/with-release-runtime.sh \
  mix hex.build --output "$work/package.tar" >/dev/null
scripts/inspect-release-package.sh "$work/package.tar"
command=(scripts/with-release-runtime.sh mix hex.publish --yes)
if [[ "${2:-}" == --check ]]; then
  command=(bash -c '
    for key in ASH_REPLICANT_ASH_VERSION ASH_REPLICANT_REPLICANT_VERSION ASH_REPLICANT_ONETIME_VERSION; do
      [[ -z "${!key+x}" ]] || exit 1
    done
    [[ -n "${HEX_API_KEY:-}" ]] || exit 1
    echo "publish-release: preconditions PASS (no publish requested)"
  ')
fi
env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION \
  -u ASH_REPLICANT_ONETIME_VERSION "${command[@]}"
