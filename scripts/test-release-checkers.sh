#!/usr/bin/env bash
set -euo pipefail

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-checker-fixtures.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

printf 'Result: 2 passed\n' > "$fixture_dir/positive.txt"
scripts/assert-exunit-output.sh "$fixture_dir/positive.txt" >/dev/null

for fixture in zero excluded skipped failed masked missing; do
  case "$fixture" in
    zero) printf 'Result: 0 tests\n' > "$fixture_dir/$fixture.txt" ;;
    excluded) printf 'Result: 1 passed, 1 excluded\n' > "$fixture_dir/$fixture.txt" ;;
    skipped) printf 'Result: 1 passed, 1 skipped\n' > "$fixture_dir/$fixture.txt" ;;
    failed) printf 'Result: 1 passed, 1 failure\n' > "$fixture_dir/$fixture.txt" ;;
    masked) printf 'Result: 1 passed, 1 skipped\nResult: 1 passed\n' > "$fixture_dir/$fixture.txt" ;;
    missing) printf 'Finished without a result summary\n' > "$fixture_dir/$fixture.txt" ;;
  esac

  if scripts/assert-exunit-output.sh "$fixture_dir/$fixture.txt" >/dev/null 2>&1; then
    echo "ExUnit checker accepted a negative fixture" >&2
    exit 1
  fi
done

scripts/assert-dependency-version.sh ash '>= 3.31.3 and < 4.0.0-0' >/dev/null

if scripts/assert-dependency-version.sh ash '== 0.0.0' >/dev/null 2>&1; then
  echo "dependency checker accepted a nonmatching requirement" >&2
  exit 1
fi

requirement_sentinel="ASH_REPLICANT_REQUIREMENT_SENTINEL"
set +e
requirement_output="$(scripts/assert-dependency-version.sh ash "$requirement_sentinel" 2>&1)"
requirement_exit=$?
set -e

if [[ "$requirement_exit" -ne 2 ]] || [[ "$requirement_output" != *"assertion input is invalid"* ]] || [[ "$requirement_output" == *"$requirement_sentinel"* ]]; then
  echo "dependency checker did not reject malformed input structurally" >&2
  exit 1
fi

set +e
runtime_output="$(scripts/assert-runtime-version.sh --self-test-mismatch 2>&1)"
runtime_exit=$?
set -e

if [[ "$runtime_exit" -ne 1 ]] || [[ "$runtime_output" != "runtime identity does not match the release contract" ]]; then
  echo "runtime checker did not reject a forced mismatch" >&2
  exit 1
fi

env -u ASH_REPLICANT_TEST_URL MIX_ENV=test mix run --no-start -e '
  Application.put_env(:ash_replicant, :forbid_test_repo_start?, true)
  key = AshReplicant.TestRepo.start_attempt_key()
  :persistent_term.erase(key)

  _config = AshReplicant.TestRepo.config()

  if :persistent_term.get(key, false) do
    IO.puts(:stderr, "runtime configuration read counted as a Repo start")
    System.halt(1)
  end

  {:ok, []} = AshReplicant.TestRepo.init(:supervisor, [])

  unless :persistent_term.get(key, false) do
    IO.puts(:stderr, "supervisor initialization was not counted as a Repo start")
    System.halt(1)
  end
' >/dev/null

selector_sentinel="ASH_REPLICANT_SELECTOR_SENTINEL"
set +e
selector_output="$(ASH_REPLICANT_ASH_VERSION="$selector_sentinel" mix run --no-start -e ':ok' 2>&1)"
selector_exit=$?
set -e

if [[ "$selector_exit" -eq 0 ]] || [[ "$selector_output" != *"must be a semantic version matching"* ]] || [[ "$selector_output" == *"$selector_sentinel"* ]]; then
  echo "Ash selector guard did not fail structurally" >&2
  exit 1
fi

set +e
ash4_output="$(ASH_REPLICANT_ASH_VERSION='4.0.0-rc.0' mix run --no-start -e ':ok' 2>&1)"
ash4_exit=$?
set -e

if [[ "$ash4_exit" -eq 0 ]] || [[ "$ash4_output" != *"must be a semantic version matching"* ]] || [[ "$ash4_output" == *"because mix.lock"* ]]; then
  echo "Ash major guard did not reject before dependency resolution" >&2
  exit 1
fi

echo "release checker self-tests: PASS"
