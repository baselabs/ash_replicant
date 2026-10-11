#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-release-guards.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts"
cp "$root/scripts/publish-release.sh" "$root/scripts/verify-release.sh" \
  "$root/scripts/assert-release-tree.sh" "$root/scripts/with-release-runtime.sh" \
  "$root/scripts/inspect-release-package.sh" "$root/scripts/release-package-files.txt" "$work/scripts/"
cd "$work"
git init -q
git config user.name 'Release checker'
git config user.email 'release-checker@example.invalid'
printf '.env\nscripts/.publish-command.sh\nlib/ignored-release-file.txt\n' > .gitignore
# Inspect a real package tree, with a fixed version as checker input.
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
# Parser input only; --check never authenticates or publishes.
printf 'HEX_API_KEY=release-checker-secret-sentinel\n' > .env
git add .gitignore mix.exs mix.lock lib .formatter.exs README.md LICENSE NOTICE CHANGELOG.md usage-rules.md scripts
git commit -qm 'Record release checker input'
git tag v1.6.3

# Trace the real expanded env invocation with a sentinel credential, never a real key.
# Enable tracing only after .env loading, in an ignored disposable script.
awk '/^env -u ASH_REPLICANT_ASH_VERSION/ {print "set -x"} {print}' \
  scripts/publish-release.sh > scripts/.publish-command.sh
command_output="$(bash scripts/.publish-command.sh 1.6.3 --check 2>&1)"
if [[ "$command_output" == *release-checker-secret-sentinel* ]]; then
  echo 'release guards: publish command line contains the key sentinel' >&2
  exit 1
fi
[[ "$command_output" == *'+ env -u ASH_REPLICANT_ASH_VERSION'* ]] || exit 1
echo 'release guards: GREEN — publish command line excludes the key sentinel'

# A gitignored lib file passes the tree guard, but changes the real Hex tarball.
printf 'unexpected package payload\n' > lib/ignored-release-file.txt
if output="$(scripts/publish-release.sh 1.6.3 --check 2>&1)"; then
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
  [[ "$output" != *release-checker-secret-sentinel* ]] || exit 1
  echo "release guards: RED — $expected"
}

for script in publish-release verify-release; do
  args=(1.6.3)
  [[ "$script" == verify-release ]] && args+=(v1.6.3)
  scripts/"$script".sh "${args[@]}" --check
  printf 'dirty\n' >> mix.exs
  reject 'dirty tree' scripts/"$script".sh "${args[@]}" --check
  git restore mix.exs
  touch unexpected-file
  reject 'dirty tree' scripts/"$script".sh "${args[@]}" --check
  rm unexpected-file
  printf '\n' >> mix.exs
  git add mix.exs
  reject 'dirty tree' scripts/"$script".sh "${args[@]}" --check
  git commit -qm 'Move checker head'
  reject 'HEAD differs from tag' scripts/"$script".sh "${args[@]}" --check
  git checkout -q --detach v1.6.3
  ASH_REPLICANT_ASH_VERSION=invalid ASH_REPLICANT_REPLICANT_VERSION=invalid \
    ASH_REPLICANT_ONETIME_VERSION=invalid scripts/"$script".sh "${args[@]}" --check
  echo "release guards: GREEN — $script"
done
rm .env
reject 'repo-root .env' scripts/publish-release.sh 1.6.3 --check
printf 'UNRELATED_KEY=input\n' > .env
reject 'HEX_API_KEY' scripts/publish-release.sh 1.6.3 --check
reject 'tag must match version' scripts/verify-release.sh 1.6.3 v1.6.2 --check
reject 'invalid release version' scripts/assert-release-tree.sh invalid vinvalid
reject 'tag cannot be resolved' scripts/assert-release-tree.sh 1.6.4 v1.6.4
git tag v1.6.4
reject 'project version differs' scripts/assert-release-tree.sh 1.6.4 v1.6.4
echo 'release guard self-tests: PASS'
