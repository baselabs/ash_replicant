#!/usr/bin/env bash
set -euo pipefail

# Defect-injection self-test for the release-artifact package-inspection
# predicate: the priv/ exclusion shipped in @package_inspection must REJECT a
# package that leaked private migrations — existing as workflow text is not
# proof. Executes the REAL predicate bytes from the checker (never a copy):
# only the mktemp/hex.build staging lines are rebound to the fixture.

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-package-inspection.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

inspection="$(MIX_ENV=test mix run --no-start --no-compile --no-deps-check -e '
  Code.require_file("scripts/assert_release_contract.exs")
  IO.write(AshReplicant.ReleaseContract.package_inspection())
')"

rebind_staging() {
  printf '%s\n' "$inspection" \
    | sed -e 's|^package_dir=\$(mktemp -d)$|package_dir="$ASH_REPLICANT_PACKAGE_FIXTURE"|' \
          -e 's|^env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION mix hex.build --unpack --output "\$package_dir"$|: # self-test staged fixture|'
}

run_inspection() {
  ASH_REPLICANT_PACKAGE_FIXTURE="$1" bash -c "$(rebind_staging)"
}

mkdir -p "$fixture_root/clean/lib"

for required in .formatter.exs mix.exs README.md LICENSE NOTICE CHANGELOG.md usage-rules.md; do
  touch "$fixture_root/clean/$required"
done

# A leaked private migration must be rejected by the shipped predicate bytes.
mkdir -p "$fixture_root/leaked/priv/repo/migrations" "$fixture_root/leaked/lib"
cp -R "$fixture_root/clean/." "$fixture_root/leaked/"
printf 'defmodule Leak do\nend\n' > "$fixture_root/leaked/priv/repo/migrations/20260814000000_leak.exs"

set +e
leaked_output="$(run_inspection "$fixture_root/leaked" 2>&1)"
leaked_exit=$?
set -e

if [[ "$leaked_exit" -eq 0 ]]; then
  echo "package inspection accepted a leaked private migration" >&2
  exit 1
fi

if [[ "$leaked_output" != *"Package contains private migrations"* ]]; then
  echo "package inspection rejected the leak through an unexpected branch" >&2
  exit 1
fi

set +e
clean_output="$(run_inspection "$fixture_root/clean" 2>&1)"
clean_exit=$?
set -e

if [[ "$clean_exit" -ne 0 ]]; then
  echo "package inspection rejected a clean fixture: $clean_output" >&2
  exit 1
fi

echo "package inspection self-test: PASS"
