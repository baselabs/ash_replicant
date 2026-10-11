#!/usr/bin/env bash
set -euo pipefail
version="${1:?usage: assert-release-tree.sh VERSION TAG}"
tag="${2:?usage: assert-release-tree.sh VERSION TAG}"
fail() { echo "release tree: $1" >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'invalid release version'
[[ "$tag" == "v$version" ]] || fail 'tag must match version'
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'dirty tree'
tag_sha="$(git rev-parse --verify "refs/tags/$tag^{commit}")" || fail 'tag cannot be resolved'
[[ "$(git rev-parse HEAD)" == "$tag_sha" ]] || fail 'HEAD differs from tag'
[[ "$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)" == "$version" ]] \
  || fail 'project version differs from release version'
echo "$tag_sha"
