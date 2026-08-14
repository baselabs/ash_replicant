#!/usr/bin/env bash
set -euo pipefail

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-checker-fixtures.XXXXXX")"
fixture_test="test/.release_checker_fixture_$$.exs"
trap 'rm -rf "$fixture_dir"; rm -f "$fixture_test"' EXIT

printf 'Result: 2 passed\n' > "$fixture_dir/positive.txt"
scripts/assert-exunit-output.sh "$fixture_dir/positive.txt" >/dev/null

printf 'Result: 2 passed, 1 excluded\n' > "$fixture_dir/intentional-exclusion.txt"
scripts/assert-exunit-output.sh "$fixture_dir/intentional-exclusion.txt" --allow-excluded >/dev/null

for fixture in zero excluded skipped failed invalid masked masked_reverse missing; do
  case "$fixture" in
    zero) printf 'Result: \n' > "$fixture_dir/$fixture.txt" ;;
    excluded) printf 'Result: 1 passed, 1 excluded\n' > "$fixture_dir/$fixture.txt" ;;
    skipped) printf 'Result: 1 passed, 1 skipped\n' > "$fixture_dir/$fixture.txt" ;;
    failed) printf 'Result: 1 passed, 1 failed\n' > "$fixture_dir/$fixture.txt" ;;
    invalid) printf 'Result: 1 passed, 1 invalid\n' > "$fixture_dir/$fixture.txt" ;;
    masked) printf 'Result: 1 passed, 1 skipped\nResult: 1 passed\n' > "$fixture_dir/$fixture.txt" ;;
    masked_reverse) printf 'Result: 1 passed\nResult: 1 passed, 1 skipped\n' > "$fixture_dir/$fixture.txt" ;;
    missing) printf 'Finished without a result summary\n' > "$fixture_dir/$fixture.txt" ;;
  esac

  if scripts/assert-exunit-output.sh "$fixture_dir/$fixture.txt" >/dev/null 2>&1; then
    echo "ExUnit checker accepted a negative fixture" >&2
    exit 1
  fi

  if [[ "$fixture" != "excluded" ]] && \
    scripts/assert-exunit-output.sh "$fixture_dir/$fixture.txt" --allow-excluded >/dev/null 2>&1; then
    echo "ExUnit checker accepted a negative fixture with exclusions authorized" >&2
    exit 1
  fi
done

if scripts/assert-exunit-output.sh "$fixture_dir/intentional-exclusion.txt" >/dev/null 2>&1; then
  echo "ExUnit evidence checker accepted an exclusion without explicit authorization" >&2
  exit 1
fi

scripts/assert-dependency-version.sh ash '>= 3.31.3 and < 4.0.0-0' >/dev/null
scripts/assert-dependency-version.sh replicant '>= 1.0.0 and < 2.0.0-0' >/dev/null

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

for mismatch in elixir otp; do
  set +e
  runtime_output="$(scripts/assert-runtime-version.sh "--self-test-${mismatch}-mismatch" 2>&1)"
  runtime_exit=$?
  set -e

  if [[ "$runtime_exit" -ne 1 ]] || [[ "$runtime_output" != "runtime identity does not match the release contract" ]]; then
    echo "runtime checker did not reject a single-axis mismatch" >&2
    exit 1
  fi
done

env -u ASH_REPLICANT_TEST_URL MIX_ENV=test mix run --no-start --no-compile --no-deps-check -e '
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
selector_output="$(ASH_REPLICANT_ASH_VERSION="$selector_sentinel" mix run --no-start --no-compile --no-deps-check -e ':ok' 2>&1)"
selector_exit=$?
set -e

if [[ "$selector_exit" -eq 0 ]] || [[ "$selector_output" != *"must be a semantic version matching"* ]] || [[ "$selector_output" == *"$selector_sentinel"* ]]; then
  echo "Ash selector guard did not fail structurally" >&2
  exit 1
fi

set +e
ash4_output="$(ASH_REPLICANT_ASH_VERSION='4.0.0-rc.0' mix run --no-start --no-compile --no-deps-check -e ':ok' 2>&1)"
ash4_exit=$?
set -e

if [[ "$ash4_exit" -eq 0 ]] || [[ "$ash4_output" != *"must be a semantic version matching"* ]] || [[ "$ash4_output" == *"because mix.lock"* ]]; then
  echo "Ash major guard did not reject before dependency resolution" >&2
  exit 1
fi

public_requirement=">= 3.31.3 and < 4.0.0-0"

for selector in unset empty latest; do
  case "$selector" in
    unset)
      selected_requirement="$(env -u ASH_REPLICANT_ASH_VERSION mix run --no-start --no-compile --no-deps-check -e '
        Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind!(:ash, 0) |> elem(1) |> IO.write()')"
      ;;
    empty)
      selected_requirement="$(ASH_REPLICANT_ASH_VERSION='' mix run --no-start --no-compile --no-deps-check -e '
        Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind!(:ash, 0) |> elem(1) |> IO.write()')"
      ;;
    latest)
      selected_requirement="$(ASH_REPLICANT_ASH_VERSION=latest mix run --no-start --no-compile --no-deps-check -e '
        Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind!(:ash, 0) |> elem(1) |> IO.write()')"
      ;;
  esac

  if [[ "$selected_requirement" != "$public_requirement" ]]; then
    echo "public Ash selector mode changed its requirement" >&2
    exit 1
  fi
done

floor_requirement="$(ASH_REPLICANT_ASH_VERSION=3.31.3 mix run --no-start --no-compile --no-deps-check -e '
  Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind!(:ash, 0) |> elem(1) |> IO.write()')"

if [[ "$floor_requirement" != "== 3.31.3" ]]; then
  echo "exact Ash floor selector did not produce an exact requirement" >&2
  exit 1
fi

set +e
replicant_selector_output="$(ASH_REPLICANT_REPLICANT_VERSION="$selector_sentinel" mix run --no-start --no-compile --no-deps-check -e ':ok' 2>&1)"
replicant_selector_exit=$?
set -e

if [[ "$replicant_selector_exit" -eq 0 ]] || [[ "$replicant_selector_output" != *"must be a semantic version matching"* ]] || [[ "$replicant_selector_output" == *"$selector_sentinel"* ]]; then
  echo "Replicant selector guard did not fail structurally" >&2
  exit 1
fi

set +e
replicant_major_output="$(ASH_REPLICANT_REPLICANT_VERSION='2.0.0-rc.0' mix run --no-start --no-compile --no-deps-check -e ':ok' 2>&1)"
replicant_major_exit=$?
set -e

if [[ "$replicant_major_exit" -eq 0 ]] || [[ "$replicant_major_output" != *"must be a semantic version matching"* ]] || [[ "$replicant_major_output" == *"because mix.lock"* ]]; then
  echo "Replicant major guard did not reject before dependency resolution" >&2
  exit 1
fi

set +e
replicant_old_output="$(ASH_REPLICANT_REPLICANT_VERSION='0.3.1' mix run --no-start --no-compile --no-deps-check -e ':ok' 2>&1)"
replicant_old_exit=$?
set -e

if [[ "$replicant_old_exit" -eq 0 ]] || [[ "$replicant_old_output" != *"must be a semantic version matching"* ]] || [[ "$replicant_old_output" == *"because mix.lock"* ]]; then
  echo "Replicant legacy guard did not reject before dependency resolution" >&2
  exit 1
fi

replicant_public_requirement=">= 1.0.0 and < 2.0.0-0"

for selector in unset empty latest; do
  case "$selector" in
    unset)
      selected_requirement="$(env -u ASH_REPLICANT_REPLICANT_VERSION mix run --no-start --no-compile --no-deps-check -e '
        Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind!(:replicant, 0) |> elem(1) |> IO.write()')"
      ;;
    empty)
      selected_requirement="$(ASH_REPLICANT_REPLICANT_VERSION='' mix run --no-start --no-compile --no-deps-check -e '
        Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind!(:replicant, 0) |> elem(1) |> IO.write()')"
      ;;
    latest)
      selected_requirement="$(ASH_REPLICANT_REPLICANT_VERSION=latest mix run --no-start --no-compile --no-deps-check -e '
        Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind!(:replicant, 0) |> elem(1) |> IO.write()')"
      ;;
  esac

  if [[ "$selected_requirement" != "$replicant_public_requirement" ]]; then
    echo "public Replicant selector mode changed its requirement" >&2
    exit 1
  fi
done

replicant_floor_requirement="$(ASH_REPLICANT_REPLICANT_VERSION=1.0.0 mix run --no-start --no-compile --no-deps-check -e '
  Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind!(:replicant, 0) |> elem(1) |> IO.write()')"

if [[ "$replicant_floor_requirement" != "== 1.0.0" ]]; then
  echo "exact Replicant floor selector did not produce an exact requirement" >&2
  exit 1
fi

scripts/test-ash-onetime-migration-checker.sh >/dev/null

printf '%s\n' \
  'defmodule AshReplicant.ReleaseCheckerFixtureTest do' \
  '  use ExUnit.Case, async: false' \
  '  test "background crashes stay structural" do' \
  '    spawn(fn -> raise "ASH_REPLICANT_BACKGROUND_SENTINEL" end)' \
  '    Process.sleep(100)' \
  '    assert true' \
  '  end' \
  'end' > "$fixture_test"

set +e
structural_output="$(env -u ASH_REPLICANT_TEST_URL scripts/run-structural-tests.sh "$fixture_test" 2>&1)"
structural_exit=$?
set -e

rm -f "$fixture_test"

if [[ "$structural_exit" -eq 0 ]] || [[ "$structural_output" == *"ASH_REPLICANT_BACKGROUND_SENTINEL"* ]]; then
  echo "uncontrolled process crash was not rejected structurally" >&2
  exit 1
fi

printf '%s\n' \
  'defmodule AshReplicant.ReleaseCheckerFixtureTest do' \
  '  use ExUnit.Case, async: false' \
  '  test "assertion failures stay structural" do' \
  '    assert "ASH_REPLICANT_ASSERTION_SENTINEL" == "different"' \
  '  end' \
  'end' > "$fixture_test"

set +e
structural_output="$(env -u ASH_REPLICANT_TEST_URL scripts/run-structural-tests.sh "$fixture_test" 2>&1)"
structural_exit=$?
set -e

rm -f "$fixture_test"

if [[ "$structural_exit" -eq 0 ]] || [[ "$structural_output" == *"ASH_REPLICANT_ASSERTION_SENTINEL"* ]] || [[ "$structural_output" == *"different"* ]]; then
  echo "assertion failure was not rejected structurally" >&2
  exit 1
fi

echo "release checker self-tests: PASS"
