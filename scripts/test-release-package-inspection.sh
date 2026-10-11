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

# The staging rebind below must observe the checker's REAL generated
# text. A sed pattern that no longer matches silently leaves the LIVE
# `mix hex.build` in place and stages nothing — the run would execute a
# real package build instead of inspecting the fixture. Both guards fail
# the self-test on exactly that drift, so the extraction pattern moves
# with the shipped predicate or the check goes red.
selector_free_build='env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix hex.build --unpack --output "$package_dir"'

printf '%s\n' "$inspection" | grep -qF "$selector_free_build" || {
  echo "package inspection self-test: the shipped hex.build selector clearing changed shape" >&2
  exit 1
}

rebind_staging() {
  local staged
  staged="$(printf '%s\n' "$inspection" \
    | sed -e 's|^package_dir=\$(mktemp -d)$|package_dir="$ASH_REPLICANT_PACKAGE_FIXTURE"|' \
          -e "s|^${selector_free_build}\$|: # self-test staged fixture|")"

  if printf '%s\n' "$staged" | grep -q 'mix hex.build'; then
    echo "package inspection self-test: the staging rebind did not replace the hex.build line" >&2
    exit 1
  fi

  printf '%s\n' "$staged"
}

run_inspection() {
  ASH_REPLICANT_PACKAGE_FIXTURE="$1" bash -c "$(rebind_staging)"
}

# Inspect the real selector-free package, then mutate its actual unpacked files.
env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION \
  -u ASH_REPLICANT_ONETIME_VERSION mix hex.build --unpack --output "$fixture_root/baseline" >/dev/null

for defect in private unexpected missing symlink; do
  cp -R "$fixture_root/baseline" "$fixture_root/$defect"
  case "$defect" in
    private)
      mkdir -p "$fixture_root/$defect/priv/repo/migrations"
      touch "$fixture_root/$defect/priv/repo/migrations/leak.exs"
      reason='Package contains private migrations'
      ;;
    unexpected)
      touch "$fixture_root/$defect/README-unapproved.md"
      reason='Package files differ from the release allowlist'
      ;;
    missing)
      rm "$fixture_root/$defect/lib/ash_replicant/append.ex"
      reason='Package files differ from the release allowlist'
      ;;
    symlink)
      ln -s README.md "$fixture_root/$defect/README-unapproved.md"
      reason='Package files differ from the release allowlist'
      ;;
  esac
  if output="$(run_inspection "$fixture_root/$defect" 2>&1)"; then
    echo "package inspection accepted $defect" >&2
    exit 1
  fi
  [[ "$output" == *"$reason"* ]] || { echo "$output" >&2; exit 1; }
  echo "package inspection: RED — $reason"
done
cp -R "$fixture_root/baseline" "$fixture_root/clean"
run_inspection "$fixture_root/clean"
echo "package inspection self-test: PASS (real package matches allowlist)"
