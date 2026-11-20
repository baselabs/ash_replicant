#!/usr/bin/env bash
# bump-version NEW_VERSION — the routine release-surface bump in one command.
#
# Touches exactly the six version-bearing spots (verified against the
# release-contract pins: the contract pins dependency FOUNDATION text, never
# the package version, so a routine bump cannot trip it):
#
#   mix.exs   @version
#   CHANGELOG [Unreleased] -> [NEW] - today
#   README    status badge, install snippet, baseline line
#   notebook  the hex-package comment and the AshReplicant.version() output
#   CHARTER   the "latest published package" status line
#
# Dependency-foundation lines (Ash / Replicant / AshOnetime ranges and locks)
# are NEVER touched: the anchors below are exact strings, not a version sed.
# Next steps use AGENTS.md's CI-only Build and test route: qualify a topic
# commit, then give kimosabe-land a fresh SHA never pushed to kci beforehand.
# Infra asks an owner to dispatch Publish to Hex on main. A second dispatch
# finishes a held release only with identical package bytes, keeping served docs.
# Read-back validates served release.json against default-branch ancestry.
# Infra tags its published commit and creates the GitHub release from
# release-assets. The published consumer runs in CI after upload, without a
# key or environment. This repository then records the verified package digest.
set -euo pipefail

new_version="${1:?usage: bump-version.sh NEW_VERSION [--check] (e.g. 1.2.0)}"
[[ "$#" -eq 1 || ( "$#" -eq 2 && "$2" == --check ) ]] || exit 2
check=false
[[ "${2:-}" != --check ]] || check=true

[[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "bump-version: '$new_version' is not X.Y.Z" >&2
  exit 2
}

cd "$(dirname "$0")/.."

current="$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)"
[[ -n "$current" ]] || { echo "bump-version: could not read @version from mix.exs" >&2; exit 1; }
[[ "$new_version" != "$current" ]] || { echo "bump-version: already at $current" >&2; exit 1; }

today="$(date +%Y-%m-%d)"
charter_updated="$(grep -o '\*\*Updated:\*\* [0-9-]*' docs/CHARTER.md | cut -d' ' -f2)"

replace_once() {
  local file="$1" old="$2"
  local count
  count="$(grep -cF "$old" "$file")" || [[ $? -eq 1 ]]
  [[ "$count" -eq 1 ]] || {
    echo "bump-version: anchor in $file is not unique (found $count): $old" >&2
    exit 1
  }
  python3 - "$file" "$old" "$3" "$check" <<'EOF'
import sys
path, old, new, check = sys.argv[1:]
source = open(path).read()
assert source.count(old) == 1
if check != "true":
    open(path, "w").write(source.replace(old, new))
EOF
}

replace_once mix.exs "@version \"$current\"" "@version \"$new_version\""
# Fold [Unreleased] into the dated version AND seed the next [Unreleased] on
# top in the same move — a fold without the fresh section leaves the next
# change recording nowhere (1.6.0 shipped with the section added by hand;
# the routine now owns it).
replace_once CHANGELOG.md "## [Unreleased]" "## [Unreleased]

## [$new_version] - $today"
replace_once README.md "> **Status: v$current — stable public API (ADR-0023).**" \
  "> **Status: v$new_version — stable public API (ADR-0023).**"
replace_once README.md "{:ash_replicant, \"~> $current\"}" \
  "{:ash_replicant, \"~> $new_version\"}"
replace_once README.md "The current $current release baseline is built and tested with:" \
  "The current $new_version release baseline is built and tested with:"
replace_once notebooks/ash_replicant_tour.livemd "\`{:ash_replicant, \"~> $current\"}\`" \
  "\`{:ash_replicant, \"~> $new_version\"}\`"
replace_once notebooks/ash_replicant_tour.livemd "# => \"$current\"" "# => \"$new_version\""
# The charter carries the five-field status stamp; bump its version segment and
# its Updated field (the stamp line is the anchor, dated today).
replace_once docs/CHARTER.md "latest published package $current" \
  "latest published package $new_version"
replace_once docs/CHARTER.md "**Updated:** $charter_updated" \
  "**Updated:** $today"
# Bind the CHANGELOG link references: the [Unreleased] compare base moves to the
# new tag and the new version gains its tree link ahead of its predecessor's.
replace_once CHANGELOG.md "compare/v$current...HEAD" "compare/v$new_version...HEAD"
replace_once CHANGELOG.md "[$current]: https://github.com/baselabs/ash_replicant/tree/v$current" \
  "[$new_version]: https://github.com/baselabs/ash_replicant/tree/v$new_version
[$current]: https://github.com/baselabs/ash_replicant/tree/v$current"

echo "bump-version: $current -> $new_version"
if [[ "$check" == true ]]; then
  echo 'bump-version: anchors PASS (no files changed)'
  exit 0
fi
echo 'bump-version: next: commit with named paths; use AGENTS.md, Build and test (CI only).'
echo 'bump-version: kimosabe-land alone moves main; its head must never have been pushed to kci.'
echo 'bump-version: infra asks an owner to dispatch Publish to Hex on the landed main commit.'
echo 'bump-version: retry that same commit only after infra inspects an approved hold or interruption.'
echo "bump-version: after read-back, infra tags v$new_version at the served published_commit"
echo 'bump-version:   and creates the GitHub release from the downloaded served docs and package.'
echo 'bump-version:   from release-assets (served archives, SHA256SUMS and published-commit.txt).'
echo 'bump-version:   publish.yml exercises the published consumer without a key or environment.'
echo 'bump-version:   this repository records the verified digest through normal landing.'
