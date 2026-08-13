#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/ash-replicant-release-contract.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

prepare_fixture() {
  rm -rf "$fixture_root/.github"
  mkdir -p "$fixture_root/.github/workflows"
  cp .github/workflows/ci.yml "$fixture_root/.github/workflows/ci.yml"
  cp README.md CONTRIBUTING.md AGENTS.md mix.exs "$fixture_root/"
}

assert_fixture_rejected() {
  if scripts/assert-release-contract.sh "$fixture_root" >/dev/null 2>&1; then
    echo "release contract checker accepted a negative fixture" >&2
    exit 1
  fi
}

scripts/assert-release-contract.sh >/dev/null

prepare_fixture
sed -i.bak 's#actions/checkout@11d5960a326750d5838078e36cf38b85af677262#actions/checkout@v4#' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
perl -0pi -e 's/actions\/checkout\@11d5960a326750d5838078e36cf38b85af677262/actions\/checkout\@v4.2.2/' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
perl -0pi -e 's/- uses: actions\/checkout\@11d5960a326750d5838078e36cf38b85af677262 # v4/- "uses": actions\/checkout\@v4 # mutable/' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
perl -0pi -e 's/- uses: actions\/checkout\@11d5960a326750d5838078e36cf38b85af677262 # v4/- {uses: actions\/checkout\@v4}/' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
sed -i.bak 's#postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b#postgres:16#' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
sed -i.bak '/mix deps.audit/d' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
sed -i.bak "s/run: mix deps.audit/run: echo 'mix deps.audit'/" "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
sed -i.bak '/label: latest-3.x/d' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
sed -i.bak '/scripts\/test-release-contract.sh/d; /scripts\/assert-release-contract.sh/d' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
sed -i.bak '/mix compile --warnings-as-errors/d' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
perl -0pi -e 's/run: mix compile --warnings-as-errors/run: echo mix compile --warnings-as-errors/g; s/^          scripts\/test-release-checkers\.sh$/          echo scripts\/test-release-checkers.sh/gm; s/^          scripts\/test-release-contract\.sh$/          echo scripts\/test-release-contract.sh/gm; s/^          scripts\/assert-runtime-version\.sh$/          echo scripts\/assert-runtime-version.sh/gm; s/^          scripts\/assert-release-contract\.sh$/          echo scripts\/assert-release-contract.sh/gm' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
perl -0pi -e 's/^      - run: mix compile --warnings-as-errors$/      # run: mix compile --warnings-as-errors/gm; s/^          scripts\/test-release-checkers\.sh$/          # scripts\/test-release-checkers.sh/gm; s/^          scripts\/test-release-contract\.sh$/          # scripts\/test-release-contract.sh/gm; s/^          scripts\/assert-release-contract\.sh$/          # scripts\/assert-release-contract.sh/gm' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
perl -0pi -e 's/(label: current-lock\n\s+selector:) ""\n\s+unlock: false/$1 latest\n            unlock: true/' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
perl -0pi -e 's/^      ASH_REPLICANT_ASH_VERSION:.*\n//m; s/^            mix deps\.unlock ash$/            :/m; s/^          scripts\/assert-dependency-version\.sh ash .*$/          :/m' "$fixture_root/.github/workflows/ci.yml"
assert_fixture_rejected

prepare_fixture
sed -i.bak 's/Elixir 1.20.3/Elixir 1.19.5/' "$fixture_root/README.md"
assert_fixture_rejected

prepare_fixture
sed -i.bak '/Elixir 1\.20\.3 on Erlang\/OTP 29/d' "$fixture_root/README.md"
assert_fixture_rejected

prepare_fixture
sed -i.bak 's/The supported release foundation is/The unsupported release foundation is/' "$fixture_root/AGENTS.md"
assert_fixture_rejected

echo "release contract self-tests: PASS"
