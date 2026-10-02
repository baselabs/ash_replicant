#!/usr/bin/env bash
# verify-release NEW_VERSION TAG — prove the PUBLIC state of a shipped release.
#
# A green publish command proves nothing about what hex.pm and GitHub now
# serve. This script is the post-publish gate for the three public facts a
# release must carry, every one checked against the live service, never the
# local build's own claims:
#
#   1. hex.pm serves the version, and its outer checksum equals a FRESH
#      package build from the CURRENT tree — the caller runs this from the
#      tagged, battery-green checkout, so checksum equality proves the served
#      bytes are the verified bytes.
#   2. The release carries docs (has_docs: true — hex.publish uploads them
#      from this same tree by default; has_docs: false is an INCOMPLETE
#      release by contract) and https://ash-replicant.hexdocs.pm/NEW_VERSION
#      answers 200.
#   3. The GitHub release's target_commitish equals the TAG's commit sha —
#      a release created after main moved past the tag targets the BRANCH
#      head instead and the contract rejects it (this exact failure hit
#      replicant's 1.4.1: PATCH the target to the sha).
#
# Usage: scripts/verify-release.sh 1.6.0 v1.6.0
# Exit: 0 only when every fact holds; a miss names the failed fact.
set -euo pipefail

version="${1:?usage: verify-release.sh NEW_VERSION TAG (e.g. 1.6.0 v1.6.0)}"
tag="${2:?usage: verify-release.sh NEW_VERSION TAG (e.g. 1.6.0 v1.6.0)}"

cd "$(dirname "$0")/.."

fail() {
  echo "verify-release: $1" >&2
  exit 1
}

command -v curl >/dev/null || fail "curl is required"
command -v gh >/dev/null || fail "gh is required (the GitHub release target check)"

# --- 1. the served artifact is the verified tree ---------------------------
# A fresh build from THIS checkout; the publish itself must have run from the
# same tree, so the served checksum must equal this one.
local_checksum="$(
  env MIX_ENV=dev scripts/with-release-runtime.sh mix hex.build 2>/dev/null |
    sed -n 's/^Package checksum: //p'
)"
[[ -n "$local_checksum" ]] || fail "could not build a package to compare (mix hex.build)"

api="$(curl -fsSL "https://hex.pm/api/packages/ash_replicant")" \
  || fail "hex.pm API unreachable for ash_replicant"

release_json="$(
  printf '%s' "$api" | python3 - "$version" <<'EOF'
import json, sys
version = sys.argv[1]
for release in json.load(sys.stdin)["releases"]:
    if release["version"] == version:
        print(json.dumps(release))
        break
EOF
)"
[[ -n "$release_json" ]] || fail "hex.pm does not serve version $version"

served_checksum="$(printf '%s' "$release_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["checksum"])')"
has_docs="$(printf '%s' "$release_json" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["has_docs"]).lower())')"

[[ "$served_checksum" == "$local_checksum" ]] \
  || fail "served checksum $served_checksum != this tree's build $local_checksum — hex serves bytes this tree did not verify"
echo "verify-release: hex.pm serves $version (checksum $served_checksum, equal to this tree's build)"

# --- 2. the release carries docs -------------------------------------------
[[ "$has_docs" == "true" ]] \
  || fail "has_docs is false — an incomplete release by contract; publish the docs from the exact released tree"
docs_code="$(curl -s -o /dev/null -w '%{http_code}' "https://ash-replicant.hexdocs.pm/$version/")"
[[ "$docs_code" == "200" ]] || fail "hexdocs for $version answered $docs_code, not 200"
echo "verify-release: hexdocs $version answers 200"

# --- 3. the GitHub release targets the TAG's commit ------------------------
tag_sha="$(git rev-parse "$tag^{commit}")" || fail "cannot resolve $tag locally"
target="$(gh api "repos/baselabs/ash_replicant/releases/tags/$tag" --jq .target_commitish)" \
  || fail "no GitHub release found for $tag"
[[ "$target" == "$tag_sha" ]] \
  || fail "GitHub release $tag targets $target, not the tag's commit $tag_sha — PATCH the release's target_commitish to the sha"
echo "verify-release: GitHub release $tag targets the tag's commit $tag_sha"

echo "verify-release: PASS — $version is publicly the verified bytes, documented, and correctly targeted"
