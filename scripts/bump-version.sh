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
# Next steps after this script: scripts/prepush.sh, commit, push, watch the
# CI battery, then tag + release + publish from the battery-green head.
set -euo pipefail

new_version="${1:?usage: bump-version.sh NEW_VERSION (e.g. 1.2.0)}"

[[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "bump-version: '$new_version' is not X.Y.Z" >&2
  exit 2
}

cd "$(dirname "$0")/.."

current="$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)"
[[ -n "$current" ]] || { echo "bump-version: could not read @version from mix.exs" >&2; exit 1; }
[[ "$new_version" != "$current" ]] || { echo "bump-version: already at $current" >&2; exit 1; }

today="$(date +%Y-%m-%d)"

replace_once() {
  local file="$1" old="$2"
  local count
  count="$(grep -cF "$old" "$file" || true)"
  [[ "$count" -eq 1 ]] || {
    echo "bump-version: anchor in $file is not unique (found $count): $old" >&2
    exit 1
  }
  python3 - "$file" "$old" "$3" <<'EOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
source = open(path).read()
assert source.count(old) == 1
open(path, "w").write(source.replace(old, new))
EOF
}

replace_once mix.exs "@version \"$current\"" "@version \"$new_version\""
replace_once CHANGELOG.md "## [Unreleased]" "## [$new_version] - $today"
replace_once README.md "> **Status: v$current — stable public API (ADR-0023).**" \
  "> **Status: v$new_version — stable public API (ADR-0023).**"
replace_once README.md "{:ash_replicant, \"~> $current\"}" \
  "{:ash_replicant, \"~> $new_version\"}"
replace_once README.md "The current $current release baseline is built and tested with:" \
  "The current $new_version release baseline is built and tested with:"
replace_once notebooks/ash_replicant_tour.livemd "\`{:ash_replicant, \"~> $current\"}\`" \
  "\`{:ash_replicant, \"~> $new_version\"}\`"
replace_once notebooks/ash_replicant_tour.livemd "# => \"$current\"" "# => \"$new_version\""
replace_once docs/CHARTER.md "**Status: realized, latest published package $current.**" \
  "**Status: realized, latest published package $new_version.**"

echo "bump-version: $current -> $new_version"
echo "bump-version: next — scripts/prepush.sh, commit, push, watch CI, then tag/release/publish from the green head"
