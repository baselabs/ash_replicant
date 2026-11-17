#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-release-guards.XXXXXX")"
package="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-release-package.XXXXXX")"
trap 'rm -rf "$work" "$package"' EXIT
mkdir -p "$work/scripts"
cp "$root/scripts/verify-release.sh" "$root/scripts/assert-release-tree.sh" \
  "$root/scripts/with-release-runtime.sh" "$root/scripts/assert-runtime-version.sh" \
  "$root/scripts/inspect-release-package.sh" "$root/scripts/release-package-files.txt" \
  "$work/scripts/"
cd "$work"
git init -q
git config user.name 'Release checker'
git config user.email 'release-checker@example.invalid'
printf 'lib/ignored-release-file.txt\n' > .gitignore
# Use a real package source tree, with a fixed version as checker input.
while IFS= read -r file; do
  [[ "$file" != hex_metadata.config ]] || continue
  mkdir -p "$(dirname "$file")"
  cp "$root/$file" "$file"
done < scripts/release-package-files.txt
python3 - <<'PY'
from pathlib import Path
import re
p = Path("mix.exs")
p.write_text(re.sub(r'  @version "[^"]+"', '  @version "1.6.3"', p.read_text(), count=1))
PY
cp "$root/mix.lock" mix.lock
cp "$root/.tool-versions" .tool-versions
git add .gitignore .tool-versions mix.exs mix.lock lib .formatter.exs README.md LICENSE NOTICE CHANGELOG.md usage-rules.md scripts
git commit -qm 'Record release checker input'
git tag v1.6.3

# The publish workflow builds the package with the dependency selectors cleared and
# inspects it against the allowlist before any upload. Run that same pair here.
build_and_inspect() {
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION \
    -u ASH_REPLICANT_ONETIME_VERSION MIX_ENV=dev scripts/with-release-runtime.sh \
    mix hex.build --output "$package/package.tar" >/dev/null
  scripts/inspect-release-package.sh "$package/package.tar"
}
build_and_inspect
echo 'release guards: GREEN — the committed package tree matches the allowlist'

# A gitignored lib file passes the tree guard, but changes the real Hex tarball.
printf 'unexpected package payload\n' > lib/ignored-release-file.txt
if output="$(build_and_inspect 2>&1)"; then
  echo 'release guards: accepted a gitignored package file' >&2
  exit 1
fi
[[ "$output" == *'package files differ from the release allowlist'* ]] || { echo "$output" >&2; exit 1; }
echo 'release guards: RED — gitignored lib file rejected before upload'
rm lib/ignored-release-file.txt

reject() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    echo "release guards: accepted $expected" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || { echo "$output" >&2; exit 1; }
  echo "release guards: RED — $expected"
}

scripts/verify-release.sh 1.6.3 v1.6.3 --check
printf 'dirty\n' >> mix.exs
reject 'dirty tree' scripts/verify-release.sh 1.6.3 v1.6.3 --check
git restore mix.exs
touch unexpected-file
reject 'dirty tree' scripts/verify-release.sh 1.6.3 v1.6.3 --check
rm unexpected-file
printf '\n' >> mix.exs
git add mix.exs
reject 'dirty tree' scripts/verify-release.sh 1.6.3 v1.6.3 --check
git commit -qm 'Move checker head'
reject 'HEAD differs from tag' scripts/verify-release.sh 1.6.3 v1.6.3 --check
git checkout -q --detach v1.6.3
ASH_REPLICANT_ASH_VERSION=invalid ASH_REPLICANT_REPLICANT_VERSION=invalid \
  ASH_REPLICANT_ONETIME_VERSION=invalid scripts/verify-release.sh 1.6.3 v1.6.3 --check
echo 'release guards: GREEN — verify-release'
reject 'tag must match version' scripts/verify-release.sh 1.6.3 v1.6.2 --check
reject 'invalid release version' scripts/assert-release-tree.sh invalid vinvalid
reject 'tag cannot be resolved' scripts/assert-release-tree.sh 1.6.4 v1.6.4
git tag v1.6.4
reject 'project version differs' scripts/assert-release-tree.sh 1.6.4 v1.6.4
echo 'release guard self-tests: PASS'
