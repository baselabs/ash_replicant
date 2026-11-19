#!/usr/bin/env bash
set -euo pipefail

release_tree_fail() { echo "release tree: $1" >&2; exit 1; }

# Publication may add a version, never a package name. Read anonymously first.
assert_hex_package_exists() {
  local name="$1" url="$2" code
  code="$(curl --silent --show-error --max-time 30 --output /dev/null \
    --write-out '%{http_code}' "$url")" || release_tree_fail "$name package lookup failed"
  case "$code" in
    200) ;;
    404) release_tree_fail "$name is not on Hex; first publication is the owner's decision" ;;
    *) release_tree_fail "$name package lookup failed" ;;
  esac
}

# Only an HTTP 404 proves absence. A transport error, redirect, or any other
# response refuses publication. GitHub uses the caller's read-only job token.
assert_release_absent() {
  local label="$1" url="$2" code
  code="$(curl --silent --show-error --max-time 30 --output /dev/null \
    --write-out '%{http_code}' "$url")" || release_tree_fail "$label lookup failed"
  case "$code" in
    404) ;;
    200) release_tree_fail "$label already exists" ;;
    *) release_tree_fail "$label lookup failed" ;;
  esac
}

# gh exits 1 for HTTP errors, including the 404 that proves absence. Inspect
# the first status line and the exit code; never print the response or stderr.
assert_github_release_absent() {
  local path="$1" response protocol code result=0
  [[ -n "${GH_TOKEN:-}" ]] || release_tree_fail 'GitHub token is required'
  response="$(gh api --hostname github.com -i "$path" 2>/dev/null)" || result=$?
  read -r protocol code _ <<< "$response"
  [[ "$protocol" == HTTP/* ]] || release_tree_fail 'GitHub release lookup failed'
  case "$code:$result" in
    404:1) ;;
    200:0) release_tree_fail 'GitHub release already exists' ;;
    *) release_tree_fail 'GitHub release lookup failed' ;;
  esac
}

release_tree_main() {
  local version="${1:?usage: assert-release-tree.sh VERSION TAG [--unreleased [PACKAGE DOCS]]}"
  local tag="${2:?usage: assert-release-tree.sh VERSION TAG [--unreleased [PACKAGE DOCS]]}"
  local mode="${3:-}" tag_sha result tree_status
  [[ "$#" -eq 2 || ( ( "$#" -eq 3 || "$#" -eq 5 ) && "$mode" == --unreleased ) ]] || exit 2
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_tree_fail 'invalid release version'
  [[ "$tag" == "v$version" ]] || release_tree_fail 'tag must match version'
  tree_status="$(git status --porcelain --untracked-files=all)" || release_tree_fail 'git status failed'
  [[ -z "$tree_status" ]] || release_tree_fail 'dirty tree'

  if [[ "$mode" == --unreleased ]]; then
    assert_hex_package_exists ash_replicant https://hex.pm/api/packages/ash_replicant
    [[ "$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)" == "$version" ]] \
      || release_tree_fail 'project version differs from release version'
    result=0
    git show-ref --verify --quiet "refs/tags/$tag" || result=$?
    case "$result" in
      0) release_tree_fail 'local tag already exists' ;;
      1) ;;
      *) release_tree_fail 'local tag lookup failed' ;;
    esac
    result=0
    GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || result=$?
    case "$result" in
      0) release_tree_fail 'remote tag already exists' ;;
      2) ;;
      *) release_tree_fail 'remote tag lookup failed' ;;
    esac
    assert_github_release_absent "repos/baselabs/ash_replicant/releases/tags/$tag"
    elixir "$(dirname "${BASH_SOURCE[0]}")/release_identity.exs" "$version" "${@:4}"
    echo 'release tree: version is untagged and its Hex identity is admissible'
    return
  fi

  tag_sha="$(git rev-parse --verify "refs/tags/$tag^{commit}")" || release_tree_fail 'tag cannot be resolved'
  [[ "$(git rev-parse HEAD)" == "$tag_sha" ]] || release_tree_fail 'HEAD differs from tag'
  [[ "$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)" == "$version" ]] \
    || release_tree_fail 'project version differs from release version'
  echo "$tag_sha"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  release_tree_main "$@"
fi
