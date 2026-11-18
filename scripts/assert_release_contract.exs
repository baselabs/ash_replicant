defmodule AshReplicant.ReleaseContractError do
  defexception [:message]
end

defmodule AshReplicant.ReleaseContract do
  alias AshReplicant.ReleaseContractError
  alias Jason.DecodeError
  alias YamlElixir.ParsingError

  @fail_late "${{ !cancelled() && steps.compile.outcome == 'success' }}"
  @immutable_action ~r/\A[^@\s]+@[0-9a-f]{40}\z/
  @pg16_image "postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b"
  @ash_requirement ">= 3.37.3 and < 4.0.0-0"
  @replicant_requirement ">= 1.4.0 and < 2.0.0-0"
  @onetime_requirement ">= 1.3.2 and < 2.0.0-0"
  @cloak_requirement ">= 0.4.0 and < 1.0.0-0"
  @checkout "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
  @setup_beam "erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124"
  @participant_example_start "<!-- ash-replicant-destination-participant-example:start -->"
  @participant_example_end "<!-- ash-replicant-destination-participant-example:end -->"

  @setup_beam_inputs %{
    "version-file" => ".tool-versions",
    "version-type" => "strict"
  }

  @publish_owner_condition "contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.actor) && contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.triggering_actor)"
  @publish_package_inspection """
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION scripts/with-release-runtime.sh mix hex.build --output "$RUNNER_TEMP/package.tar"
  scripts/inspect-release-package.sh "$RUNNER_TEMP/package.tar"
  """

  @publish_unreleased_check ~S"""
  version="$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)"
  scripts/assert-release-tree.sh "$version" "v$version" --unreleased
  """

  @fixture_audit_script ~S"""
  #!/usr/bin/env bash
  set -euo pipefail

  root="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$root"

  # Match upgrade_checkpoint_test.exs: the real consumer inherits the root lock.
  fixture="$(mktemp -d "${RUNNER_TEMP:?}/ash-replicant-upgrade-audit.XXXXXX")"
  trap 'rm -rf "$fixture"' EXIT
  cp -R test/fixtures/upgrade_0_4_app/. "$fixture/"
  cp mix.lock "$fixture/mix.lock"
  export ASH_REPLICANT_PATH="$root"
  (cd "$fixture" && mix deps.get --check-locked && mix hex.audit)
  mix deps.audit --path "$fixture"
  """

  @release_tree_script ~S"""
  #!/usr/bin/env bash
  set -euo pipefail

  release_tree_fail() { echo "release tree: $1" >&2; exit 1; }

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
    local version="${1:?usage: assert-release-tree.sh VERSION TAG [--unreleased]}"
    local tag="${2:?usage: assert-release-tree.sh VERSION TAG [--unreleased]}"
    local mode="${3:-}" tag_sha result
    [[ "$#" -eq 2 || ( "$#" -eq 3 && "$mode" == --unreleased ) ]] || exit 2
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_tree_fail 'invalid release version'
    [[ "$tag" == "v$version" ]] || release_tree_fail 'tag must match version'
    [[ -z "$(git status --porcelain --untracked-files=all)" ]] || release_tree_fail 'dirty tree'

    if [[ "$mode" == --unreleased ]]; then
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
      assert_release_absent 'Hex release' "https://hex.pm/api/packages/ash_replicant/releases/$version"
      echo 'release tree: version is unpublished and untagged'
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
  """

  @upgrade_fixture_project """
  defmodule UpgradeFixture.MixProject do
    use Mix.Project

    def project do
      [
        app: :upgrade_fixture,
        version: "0.4.0",
        elixir: "~> 1.20",
        deps: deps(),
        # The inherited root lock has the same GCM-only policy. The source guard
        # covers this fixture too; it neither references nor configures AES-CTR.
        hex: [ignore_advisories: ["EEF-CVE-2026-95105"]]
      ]
    end

    def application do
      [extra_applications: [:logger], mod: {UpgradeFixture.Application, []}]
    end

    defp deps do
      [
        {:ash_replicant, path: System.fetch_env!("ASH_REPLICANT_PATH")},
        {:igniter, ">= 0.8.3 and < 1.0.0-0", runtime: false}
      ]
    end
  end
  """

  @github_target_lookup ~S"""
  target="$(gh api --hostname github.com "repos/baselabs/ash_replicant/releases/tags/$tag" --jq .target_commitish 2>/dev/null)" \
    || fail "GitHub release lookup failed"
  """

  @qualification_lookup ~S"""
          response = subprocess.run(
              [
                  "gh", "api", "--hostname", "github.com",
                  f"repos/{repository}/actions/runs/{run_id}/jobs"
                  f"?filter=latest&per_page=100&page={page}",
              ],
              check=True, capture_output=True, text=True, timeout=30,
          )
          body = json.loads(response.stdout)
  """

  @github_guard_tests ~S"""
  reject 'GitHub release already exists' assert_github_release_absent \
    repos/baselabs/ash_replicant/releases/tags/v1.6.3
  reject 'Hex release already exists' assert_release_absent 'Hex release' \
    https://hex.pm/api/packages/ash_replicant/releases/1.6.3
  assert_github_release_absent \
    repos/baselabs/ash_replicant/releases/tags/v999999.0.0
  without_github_token() (
    unset GH_TOKEN
    assert_github_release_absent "$@"
  )
  reject 'GitHub token is required' without_github_token \
    repos/baselabs/ash_replicant/releases/tags/v999999.0.0
  # A real invalid date query yields an HTTP error other than absence.
  reject 'GitHub release lookup failed' assert_github_release_absent \
    'repos/baselabs/ash_replicant/commits?since=not-a-date'
  """

  # The image ref rides the matrix (pg_image: the pinned digest ref per
  # cell); the digest pinning is enforced through the exact @matrix match.
  @postgres_run """
  docker run -d --name pg \\
    -e POSTGRES_HOST_AUTH_METHOD=trust \\
    -p 5432:5432 \\
    "$PG_IMAGE" \\
    -c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20
  scripts/wait-for-postgres.sh pg
  """

  @resolve_dependencies """
  if [[ "$LOCKFILE" != 'mix.lock' ]]; then
    cp "$LOCKFILE" mix.lock
  fi
  mix deps.get --check-locked
  mix deps ash
  mix deps replicant
  mix deps ash_onetime
  scripts/assert-dependency-version.sh ash "$ASH_REQUIREMENT"
  scripts/assert-dependency-version.sh replicant "$REPLICANT_REQUIREMENT"
  scripts/assert-dependency-version.sh ash_onetime "$ONETIME_REQUIREMENT"
  if [[ "$DEPENDENCY_LANE" == 'latest-compatible' ]]; then
    scripts/assert-dependency-version.sh --newest ash "$ASH_REQUIREMENT"
    scripts/assert-dependency-version.sh --newest replicant "$REPLICANT_REQUIREMENT"
    scripts/assert-dependency-version.sh --newest ash_onetime "$ONETIME_REQUIREMENT"
    scripts/assert-dependency-version.sh --newest ash_postgres '~> 2.13'
    scripts/assert-dependency-version.sh --newest spark '~> 2.7.0'
  fi
  """

  @create_database """
  mix ecto.create
  mix ecto.migrate
  """

  # New candidate refs have no prior push head. Fetch main;
  # an unavailable base or an evidence-machinery diff runs the full matrix.
  @mutation_gates_run """
  if git fetch --no-tags --quiet origin main; then
    scripts/run-mutation-gates.py --diff-base FETCH_HEAD
  else
    scripts/run-mutation-gates.py
  fi
  """

  @public_dependency_check """
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix run --no-start -e '
  deps = Mix.Project.config() |> Keyword.fetch!(:deps)

  expected = %{
    ash: ">= 3.37.3 and < 4.0.0-0",
    replicant: ">= 1.4.0 and < 2.0.0-0",
    ash_onetime: ">= 1.3.2 and < 2.0.0-0",
    ash_cloak: ">= 0.4.0 and < 1.0.0-0"
  }

  Enum.each(expected, fn {dependency, requirement} ->
    actual = deps |> List.keyfind!(dependency, 0) |> elem(1)
    unless actual == requirement, do: raise("unexpected public dependency requirement")
  end)
  '
  """

  @package_inspection """
  package_dir=$(mktemp -d)
  trap 'rm -rf "$package_dir"' EXIT
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix hex.build --unpack --output "$package_dir"

  for required in lib .formatter.exs mix.exs README.md LICENSE NOTICE CHANGELOG.md usage-rules.md \\
    lib/ash_replicant/upgrade.ex lib/ash_replicant/upgrade/checkpoint.ex \\
    lib/mix/tasks/ash_replicant.upgrade.ex; do
    test -e "$package_dir/$required" || {
      echo "::error::Missing package path: $required"
      exit 1
    }
  done

  if find "$package_dir" -type d \\( -name test -o -name .forge -o -name _build \\) -print -quit | grep -q .; then
    echo "::error::Package contains test, Forge, or build residue"
    exit 1
  fi

  if test -e "$package_dir/priv"; then
    echo "::error::Package contains private migrations"
    exit 1
  fi

  if find "$package_dir" -type f \\( -name '.env*' -o -name '*.pem' -o -name '*.key' \\) -print -quit | grep -q .; then
    echo "::error::Package contains a credential-shaped file"
    exit 1
  fi

  if ! diff -u scripts/release-package-files.txt <(cd "$package_dir" && find . \\( -type f -o -type l \\) | sed 's|^./||' | LC_ALL=C sort); then
    echo "::error::Package files differ from the release allowlist"
    exit 1
  fi
  """

  @job_env %{
    "no-database" => %{"MIX_ENV" => "test"},
    "compatibility" => %{
      "MIX_ENV" => "test",
      "ASH_REPLICANT_ASH_VERSION" => "${{ matrix.ash_selector }}",
      "ASH_REPLICANT_REPLICANT_VERSION" => "${{ matrix.replicant_selector }}",
      "ASH_REPLICANT_ONETIME_VERSION" => "${{ matrix.onetime_selector }}",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres@localhost:5432/postgres"
    },
    "release-artifact" => %{"MIX_ENV" => "dev"},
    "performance" => %{
      "MIX_ENV" => "test",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres@localhost:5432/postgres",
      "ASH_REPLICANT_PERFORMANCE" => "1"
    },
    "decoder-old-majors" => %{
      "MIX_ENV" => "test",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres@localhost:5432/postgres",
      "ASH_REPLICANT_PGOLD_URL" => "postgres://postgres@localhost:5433/postgres"
    }
  }

  # The dedicated performance job is not a matrix job — its PG16 step
  # carries the literal pinned digest (the parameterized @postgres_run
  # belongs to the compatibility cells).
  @performance_postgres_run """
  docker run -d --name pg \\
    -e POSTGRES_HOST_AUTH_METHOD=trust \\
    -p 5432:5432 \\
    #{@pg16_image} \\
    -c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20
  scripts/wait-for-postgres.sh pg
  """

  @decoder_postgres_run """
  # The old images' entrypoint never appends a `host replication`
  # pg_hba line (unlike 12+), so the walsender needs this file.
  printf 'local all all trust\\nhost all all all trust\\nhost replication all all trust\\n' > /tmp/pgold-hba.conf
  docker run -d --name pg \\
    -e POSTGRES_HOST_AUTH_METHOD=trust \\
    -p 5432:5432 \\
    #{@pg16_image} \\
    -c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20
  docker run -d --name pgold \\
    -e POSTGRES_HOST_AUTH_METHOD=trust \\
    -p 5433:5432 \\
    -v /tmp/pgold-hba.conf:/hba.conf:ro \\
    pgold-plugins:ci \\
    -c wal_level=logical -c max_wal_senders=20 -c max_replication_slots=20 \\
    -c shared_preload_libraries=pglogical -c hba_file=/hba.conf
  scripts/wait-for-postgres.sh pg
  scripts/wait-for-postgres.sh pgold
  """

  @pg17_image "postgres:17@sha256:e38411452a464af89e5adadb8d223bf53b898d47d6ef918b2d58c08707350449"
  @pg18_image "postgres:18@sha256:06cad38a5d9f5d24b4d83d86def30795d5e4b757fedbf5281172b576dedcd941"

  @matrix [
    %{
      "label" => "exact-floors",
      "lockfile" => "locks/exact-floors.lock",
      "ash_selector" => "3.37.3",
      "ash_requirement" => "== 3.37.3",
      "replicant_selector" => "1.4.0",
      "replicant_requirement" => "== 1.4.0",
      "onetime_selector" => "1.3.2",
      "onetime_requirement" => "== 1.3.2",
      "pg_major" => "16",
      "pg_image" => @pg16_image
    },
    %{
      "label" => "current-lock",
      "lockfile" => "mix.lock",
      "ash_selector" => "",
      "ash_requirement" => @ash_requirement,
      "replicant_selector" => "",
      "replicant_requirement" => @replicant_requirement,
      "onetime_selector" => "",
      "onetime_requirement" => @onetime_requirement,
      "pg_major" => "16",
      "pg_image" => @pg16_image
    },
    %{
      "label" => "latest-compatible",
      "lockfile" => "locks/latest-compatible.lock",
      "ash_selector" => "latest",
      "ash_requirement" => @ash_requirement,
      "replicant_selector" => "latest",
      "replicant_requirement" => @replicant_requirement,
      "onetime_selector" => "latest",
      "onetime_requirement" => @onetime_requirement,
      "pg_major" => "16",
      "pg_image" => @pg16_image
    },
    %{
      "label" => "current-lock-pg17",
      "lockfile" => "mix.lock",
      "ash_selector" => "",
      "ash_requirement" => @ash_requirement,
      "replicant_selector" => "",
      "replicant_requirement" => @replicant_requirement,
      "onetime_selector" => "",
      "onetime_requirement" => @onetime_requirement,
      "pg_major" => "17",
      "pg_image" => @pg17_image
    },
    %{
      "label" => "current-lock-pg18",
      "lockfile" => "mix.lock",
      "ash_selector" => "",
      "ash_requirement" => @ash_requirement,
      "replicant_selector" => "",
      "replicant_requirement" => @replicant_requirement,
      "onetime_selector" => "",
      "onetime_requirement" => @onetime_requirement,
      "pg_major" => "18",
      "pg_image" => @pg18_image
    }
  ]

  @job_keys %{
    "no-database" => ~w(env name permissions runs-on steps timeout-minutes),
    "compatibility" => ~w(env name runs-on steps strategy timeout-minutes),
    "release-artifact" => ~w(env name runs-on steps timeout-minutes),
    "performance" => ~w(env name runs-on steps timeout-minutes),
    "decoder-old-majors" => ~w(env name runs-on steps strategy timeout-minutes)
  }

  @job_steps %{
    "no-database" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @setup_beam, @setup_beam_inputs},
      {:run, "scripts/assert-runtime-version.sh"},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors", %{"id" => "compile"}},
      {:run, "mix format --check-formatted", %{"if" => @fail_late}},
      {:run, "elixir --version", %{"if" => @fail_late}},
      {:run, "scripts/test-release-checkers.sh", %{"if" => @fail_late}},
      {:run, "scripts/test-release-guards.sh",
       %{"if" => @fail_late, "env" => %{"GH_TOKEN" => "${{ github.token }}"}}},
      {:run, "scripts/test-release-contract.sh", %{"if" => @fail_late}},
      {:run, "python3 -B -m unittest discover -s scripts -p 'test_qualify.py'",
       %{"if" => @fail_late}},
      {:run, "mix credo --strict", %{"if" => @fail_late}},
      {:run, "mix deps.audit", %{"if" => @fail_late}},
      {:run, "scripts/audit-fixtures.sh", %{"if" => @fail_late}},
      {:run,
       "env -u ASH_REPLICANT_TEST_URL scripts/run-structural-tests.sh --allow-excluded --exclude integration",
       %{"if" => @fail_late}},
      {:run, String.trim(@mutation_gates_run), %{"if" => @fail_late}}
    ],
    "compatibility" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:run, String.trim(@postgres_run), %{"env" => %{"PG_IMAGE" => "${{ matrix.pg_image }}"}}},
      {:uses, @setup_beam, @setup_beam_inputs},
      {:run, "scripts/assert-runtime-version.sh"},
      {:run, String.trim(@resolve_dependencies),
       %{
         "env" => %{
           "LOCKFILE" => "${{ matrix.lockfile }}",
           "ASH_REQUIREMENT" => "${{ matrix.ash_requirement }}",
           "REPLICANT_REQUIREMENT" => "${{ matrix.replicant_requirement }}",
           "ONETIME_REQUIREMENT" => "${{ matrix.onetime_requirement }}",
           "DEPENDENCY_LANE" => "${{ matrix.label }}"
         }
       }},
      {:run, "mix deps.compile"},
      {:run, String.trim(@create_database)},
      {:run, "mix compile --warnings-as-errors", %{"id" => "compile"}},
      {:run, "elixir --version", %{"if" => @fail_late}},
      {:run, "scripts/test-release-checkers.sh", %{"if" => @fail_late}},
      {:run, "scripts/assert-release-contract.sh", %{"if" => @fail_late}},
      {:run, "mix deps.audit", %{"if" => @fail_late}},
      {:run, "scripts/test-migration-drift-gate.sh", %{"if" => @fail_late}},
      {:run, "scripts/run-structural-tests.sh --include integration", %{"if" => @fail_late}},
      {:run, "scripts/run-structural-tests.sh test/integration --include integration",
       %{"if" => @fail_late}},
      {:run, "mix dialyzer", %{"if" => @fail_late}}
    ],
    "performance" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:run, String.trim(@performance_postgres_run)},
      {:uses, @setup_beam, @setup_beam_inputs},
      {:run, "scripts/assert-runtime-version.sh"},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, String.trim(@create_database)},
      {:run,
       "scripts/run-structural-tests.sh test/integration/performance_bounds_test.exs --include integration"}
    ],
    "decoder-old-majors" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @setup_beam, @setup_beam_inputs},
      {:run, "scripts/assert-runtime-version.sh"},
      {:run,
       ~s(docker build -f test/support/pg_old.dockerfile --build-arg "BASE=$PG_BASE" -t pgold-plugins:ci .),
       %{"env" => %{"PG_BASE" => "${{ matrix.base }}"}}},
      {:run, String.trim(@decoder_postgres_run)},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, String.trim(@create_database)},
      {:run,
       "scripts/run-structural-tests.sh test/integration/decoder_admission_test.exs --include pgold"}
    ],
    "release-artifact" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @setup_beam, @setup_beam_inputs},
      {:run, "scripts/assert-runtime-version.sh"},
      {:run,
       "env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, "elixir --version"},
      {:run, "scripts/assert-release-contract.sh"},
      {:run, String.trim(@public_dependency_check)},
      {:run, "mix docs --warnings-as-errors"},
      {:run, String.trim(@package_inspection)}
    ]
  }

  @named_separator_entities ~w(
    af ApplyFunction emsp13 emsp14 emsp ensp hairsp ic InvisibleComma
    InvisibleTimes it lrm MediumSpace nbsp NegativeMediumSpace NegativeThickSpace
    NegativeThinSpace NegativeVeryThinSpace NewLine NoBreak NonBreakingSpace numsp
    puncsp rlm shy Tab ThickSpace thinsp ThinSpace VeryThinSpace ZeroWidthSpace zwj zwnj
  )

  @doc_contracts [
    {"README.md", "### Supported foundation",
     [
       "- Elixir 1.20.3 on Erlang/OTP 29;",
       "- Ash `#{@ash_requirement}` (current lock 3.37.3);",
       "- AshPostgres `~> 2.13` (current lock 2.15.2 with AshSql 0.8.8; the latest-compatible cell tests the newest 2.x);",
       "- Spark `~> 2.7.0` (effective floor 2.7.6 through Ash; current lock 2.7.9);",
       "- Replicant `#{@replicant_requirement}` (current lock 1.5.1)",
       "- AshOnetime `#{@onetime_requirement}` (current lock 1.5.0)",
       "- AshCloak `#{@cloak_requirement}` (current lock 0.4.0"
     ]},
    {"CONTRIBUTING.md", "## Prerequisites",
     [
       "- **Elixir 1.20.3** and **Erlang/OTP 29**",
       "- Ash `#{@ash_requirement}`; selector-free development uses this public range",
       "- Replicant `#{@replicant_requirement}` from Hex; the lock is 1.5.1.",
       "- AshCloak `#{@cloak_requirement}` from Hex; the current lock is 0.4.0 (the"
     ]},
    {"AGENTS.md", "## Development workflow",
     [
       "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
         "`#{@ash_requirement}` (current lock 3.37.3) and Replicant\n" <>
         "`#{@replicant_requirement}` (current lock 1.5.1), plus\n" <>
         "AshOnetime `#{@onetime_requirement}` (current lock 1.5.0) and AshCloak\n" <>
         "`#{@cloak_requirement}` (current lock 0.4.0; releases below 0.4.0 carry\n" <>
         "CVE-2026-81319 and CVE-2026-81322 and are not admitted)."
     ]}
  ]

  @b1_doc_contracts [
    {"README.md", "## Destination transaction boundary",
     [
       "Every admitted destination resource uses the sink's literal AshPostgres Repo and the same effective dynamic Repo.",
       "Declarations are trusted metadata; they do not prove an arbitrary Elixir body.",
       "AshOnetime one-time nonces are rejected for WAL replay.",
       "A Replicant v1 retry and incremental resume are physically effect-once for resources declaring `snapshot_provenance true`:"
     ]},
    {"usage-rules.md", "## Destination transaction boundary",
     [
       "Every admitted destination resource uses the sink's literal AshPostgres Repo and the same effective dynamic Repo.",
       "Declarations are trusted metadata; they do not prove an arbitrary Elixir body.",
       "AshOnetime one-time nonces are rejected for WAL replay.",
       "V1 retry and incremental resume are physically effect-once for opted-in resources:"
     ]},
    {"AGENTS.md", "## Critical rules",
     [
       "**6. Effect-once = one admitted destination graph, one transaction, watermark dedup.**",
       "A declaration is trusted metadata, not proof of an arbitrary body;",
       "Reject nonce, independent, external,"
     ]},
    {"docs/CHARTER.md", "## Destination and AshOnetime boundary for 1.0.0",
     [
       "The B1 implementation admits one recursive destination action graph before delivery.",
       "This verifies the declaration, not the truth of an arbitrary Elixir body",
       "Nonce and independent-commit modes are rejected for WAL retry."
     ]}
  ]

  @b1_contract_paths ["README.md", "usage-rules.md", "AGENTS.md", "docs/CHARTER.md"]
  @b1_forbidden_positive_claims [
    "Every mapped row action is protected by AshOnetime one_time_nonce.",
    "Replicant v1 snapshot retries are physically duplicate-free.",
    "DestinationParticipant proves arbitrary callback bodies contain no undeclared effects."
  ]

  @census_doc_contracts [
    {"README.md", "### 4. Start the pipeline",
     [
       "The owner continuously re-runs destination-generation, live contract,\n" <>
         "  durable checkpoint, and full source-coverage checks.",
       "Drift halts immediately; a checker fault or timeout\n" <>
         "  is never a pass and halts after the configured consecutive budget.",
       "one\n  owner never overlaps census work (ADR-0019)."
     ]},
    {"usage-rules.md", "### 4. Start the pipeline",
     [
       "Exact bounds are\n  `interval_ms: 50..86_400_000`, `jitter_ratio: 0.0..0.5`,\n" <>
         "  `timeout_ms: 1..60_000`, and `max_consecutive_faults: 1..1_000`."
     ]},
    {"usage-rules.md", "### Continuous invariant census",
     [
       "A run enters through the same admitted callback guard as\n" <>
         "delivery, including owner-liveness checks and dynamic-Repo pinning",
       "Any drift halts the temporary pipeline immediately and freezes checkpoint\nadvance.",
       "the exact configured consecutive fault\nhalts with `:census_unverifiable`."
     ]},
    {"AGENTS.md", "## Architecture (realized)",
     [
       "The same owner runs the C01 continuous invariant census through the admitted\n" <>
         "callback guard (never a second Replicant callback or lifecycle process)",
       "The next run is scheduled only after the\n" <>
         "current one settles, and pipeline/owner teardown kills any in-flight worker."
     ]}
  ]

  @census_source_contracts [
    {"lib/ash_replicant/census.ex", "@defaults %{\n"},
    {"lib/ash_replicant/census.ex", "    enabled?: true,\n"},
    {"lib/ash_replicant/census.ex", "    interval_ms: 60_000,\n"},
    {"lib/ash_replicant/census.ex", "    jitter_ratio: 0.1,\n"},
    {"lib/ash_replicant/census.ex", "    timeout_ms: 10_000,\n"},
    {"lib/ash_replicant/census.ex", "    max_consecutive_faults: 3\n"},
    {"lib/ash_replicant.ex", "{:ok, census} <- Census.options(opts),"},
    {"lib/ash_replicant.ex", "{:ok, Map.merge(admitted, %{sink: sink, census: census})}"},
    {"lib/ash_replicant/pipeline_owner.ex",
     "send(parent, {:census_result, token, Census.run(slot_name, sink)})"},
    {"lib/ash_replicant/pipeline_owner.ex",
     "schedule_next_census(%{state | consecutive_faults: 0, last_census: :healthy})"},
    {"lib/ash_replicant/pipeline_owner.ex",
     "halt_for_census(state, check, :census_unverifiable)"},
    {"lib/ash_replicant/telemetry.ex", "[:ash_replicant, :census, :passed],\n"},
    {"lib/ash_replicant/telemetry.ex", "[:ash_replicant, :census, :faulted],\n"},
    {"lib/ash_replicant/telemetry.ex", "[:ash_replicant, :census, :halted],\n"}
  ]

  @upgrade_doc_contracts [
    {"README.md", "### 1. Define the checkpoint resource",
     [
       "mix ash_replicant.upgrade 0.4.0 1.0.0",
       "It never infers ownership from a slot-only row."
     ]},
    {"usage-rules.md", "## Upgrading from the slot-only checkpoint",
     [
       "the 1.0.0 upgrader never infers ownership",
       "the generated migration\nrefuses without that explicit assertion",
       "restore from backup or remain on 1.0"
     ]},
    {"AGENTS.md", "## Critical rules",
     ["**10. The 0.4.0 to 1.0.0 upgrade never infers checkpoint ownership.**"]},
    {"docs/adr/0007-source-bound-checkpoint-effect-once.md", "## Decision",
     ["mix ash_replicant.upgrade 0.4.0 1.0.0", "checksummed rollback ledger"]},
    # CHANGELOG is matched whole-file, not by first-section extraction: an
    # [Unreleased] block legitimately carries its own `### Added` heading
    # ahead of the released section that owns this entry.
    {"CHANGELOG.md", nil, ["**Guarded 0.4.0 to 1.0.0 package upgrade and rollback.**"]}
  ]

  @upgrade_source_contracts [
    {"lib/ash_replicant/upgrade/checkpoint.ex", "def up(repo, opts)"},
    {"lib/ash_replicant/upgrade/checkpoint.ex", "def down(repo, opts)"},
    {"lib/ash_replicant/upgrade/checkpoint.ex", "pg_advisory_xact_lock"},
    {"lib/ash_replicant/upgrade/checkpoint.ex", "IN ACCESS EXCLUSIVE MODE"},
    {"lib/ash_replicant/upgrade/checkpoint.ex",
     "defp verify_rollback_state(repo, config, ledger)"},
    {"lib/ash_replicant/upgrade.ex", "def render_checkpoint_snapshot(repo)"},
    {"lib/mix/tasks/ash_replicant.upgrade.ex", "use Igniter.Mix.Task"},
    {"lib/mix/tasks/ash_replicant.upgrade.ex", "Mix.Task.run(\"compile\")"},
    {"lib/mix/tasks/ash_replicant.upgrade.ex", "Application.ensure_all_started(:postgrex)"},
    {"lib/mix/tasks/ash_replicant.upgrade.ex", "Checkpoint.check(plan.repo"}
  ]

  # The exact package-inspection bytes the contract enforces on the workflow.
  # The package-inspection self-test executes these bytes against staged
  # fixtures (leak + clean), so the shipped predicate is proven to REJECT, not
  # merely to exist as text.
  @doc false
  def package_inspection, do: @package_inspection

  def run(root) do
    workflow = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/qualification.yml"))
    landing = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/ci.yml"))

    publish = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/publish.yml"))

    assert_landing(landing)
    assert_publish(publish, root)
    assert_qualification(workflow)
    assert_workflow_runners(root)
    assert_ci_sources(root)
    assert_qualification_inventory(root, workflow)
    assert_runtime(workflow, root)
    assert_jobs(workflow)
    assert_compatibility(workflow)
    assert_mix_contract(root)
    assert_replicant_contract(root)
    assert_checker_wiring(root)
    assert_docs(root)
    assert_b1_docs(root)
    assert_b1_examples(root)
    assert_no_b1_positive_contradictions(root)
    assert_census_contract(root)
    assert_upgrade_contract(root)
    assert_b5_absence_scans(root)
  rescue
    _error in [ParsingError, File.Error, DecodeError] -> fail("release contract input is invalid")
  end

  # U3/B5 (D6): the durable effect ledger stays ABSENT from lib/. The only
  # permitted occurrences are the exact compile-only legacy marker, activation
  # refusal, and upgrade codemod surface. No secret-shaped literal ships in lib/.
  defp assert_b5_absence_scans(root) do
    lib =
      Path.wildcard(Path.join(root, "lib/*.ex")) ++
        Path.wildcard(Path.join(root, "lib/**/*.ex"))

    lib = lib |> Enum.uniq()

    ledger_hits =
      lib
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.flat_map(fn {line, ix} ->
          if String.contains?(line, "apply_ledger"),
            do: [{Path.expand(path), ix + 1, String.trim(line)}],
            else: []
        end)
      end)

    sink_path = root |> Path.join(Path.join(["lib", "ash_replicant", "sink.ex"])) |> Path.expand()
    root_path = root |> Path.join(Path.join(["lib", "ash_replicant.ex"])) |> Path.expand()

    task_path =
      root
      |> Path.join(Path.join(["lib", "mix", "tasks", "ash_replicant.upgrade.ex"]))
      |> Path.expand()

    allowed_hits =
      MapSet.new([
        {sink_path, "legacy_apply_ledger? = Keyword.has_key?(opts, :apply_ledger)"},
        {sink_path,
         "# removed `apply_ledger`) must surface as a compile-time failure on the host,"},
        {sink_path, ":apply_ledger"},
        {sink_path, "\"legacy :apply_ledger marker\""},
        {sink_path, "legacy_apply_ledger?: unquote(legacy_apply_ledger?)"},
        {root_path, "%{legacy_apply_ledger?: true} ->"},
        {task_path, "compile-only `apply_ledger` marker from each explicitly bound legacy sink."},
        {task_path, "{:ok, options} <- CodeKeyword.remove_keyword_key(options, :apply_ledger) do"}
      ])

    actual_hits = MapSet.new(ledger_hits, fn {path, _line, content} -> {path, content} end)

    assert(
      length(ledger_hits) == 8 and actual_hits == allowed_hits,
      "apply_ledger must appear ONLY in the exact compile-only upgrade compatibility surface, found: #{inspect(ledger_hits)}"
    )

    secret_hits =
      lib
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.flat_map(fn {line, ix} ->
          # Standard base64 (the +/ alphabet), plus the URL-safe alphabet
          # ONLY for runs containing a hyphen (cross-vendor finding: base64url
          # tokens) — a bare [A-Za-z0-9_-]{40,} run matches every long
          # snake_case identifier in the source, a false-positive class, not
          # a detector. This is a tripwire, not a secret scanner.
          if Regex.match?(~r|[A-Za-z0-9+/]{40,}={0,2}|, line) or
               Regex.match?(~r|[A-Za-z0-9_-]*-[A-Za-z0-9_-]{39,}={0,2}|, line),
             do: ["#{path}:#{ix + 1}"],
             else: []
        end)
      end)

    assert(
      secret_hits == [],
      "secret-shaped literals in lib/ are a classified-boundary violation, found: #{inspect(secret_hits)}"
    )
  rescue
    _error in [File.Error] -> fail("absence-scan input is invalid")
  end

  defp assert_checker_wiring(root) do
    source = root |> Path.join("scripts/test-release-checkers.sh") |> File.read!()

    count =
      source
      |> String.split("\n")
      |> Enum.count(
        &(String.trim(&1) == "scripts/test-ash-onetime-migration-checker.sh >/dev/null")
      )

    assert(count == 1, "AshOnetime migration checker wiring is incomplete")

    inspection_count =
      source
      |> String.split("\n")
      |> Enum.count(&(String.trim(&1) == "scripts/test-release-package-inspection.sh >/dev/null"))

    assert(inspection_count == 1, "package inspection checker wiring is incomplete")

    readiness_count =
      source
      |> String.split("\n")
      |> Enum.count(&(String.trim(&1) == "scripts/test-postgres-readiness.sh >/dev/null"))

    assert(readiness_count == 1, "PostgreSQL readiness checker wiring is incomplete")

    assert(
      not String.contains?(source, "scripts/test-release-guards.sh"),
      "live release guards must run only in their dedicated step"
    )
  rescue
    _error in [File.Error] -> fail("release checker wiring input is invalid")
  end

  def run_cli(root) do
    run(root)
  rescue
    error in ReleaseContractError ->
      IO.puts(:stderr, error.message)
      System.halt(1)
  end

  defp assert_landing(workflow) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(concurrency jobs name on permissions) and
        workflow["name"] == "CI" and workflow["permissions"] == %{"contents" => "read"} and
        workflow["concurrency"] ==
          %{"group" => "ci-${{ github.ref }}", "cancel-in-progress" => true},
      "CI landing workflow control is invalid"
    )

    assert(
      workflow["on"] == %{"push" => %{"branches" => ["kci/**"]}},
      "CI trigger must qualify only candidate branch pushes"
    )

    jobs = Map.get(workflow, "jobs", %{})

    assert(
      Enum.sort(Map.keys(jobs)) == ~w(qualification qualified),
      "CI landing jobs are invalid"
    )

    assert(
      jobs["qualification"] == %{"uses" => "./.github/workflows/qualification.yml"},
      "CI qualification caller is invalid"
    )

    assert(
      jobs["qualified"] == %{
        "name" => "qualified",
        "if" => "always()",
        "needs" => ["qualification"],
        "runs-on" => "ubuntu-24.04",
        "timeout-minutes" => 3,
        "permissions" => %{"actions" => "read", "contents" => "read"},
        "steps" => [
          %{"uses" => @checkout, "with" => %{"persist-credentials" => false}},
          %{
            "run" => "python3 scripts/qualify.py",
            "env" => %{
              "GH_TOKEN" => "${{ github.token }}",
              "QUALIFICATION_RESULT" => "${{ needs.qualification.result }}"
            }
          }
        ]
      },
      "CI qualified verdict job contract is invalid"
    )
  end

  defp assert_qualification(workflow) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(jobs name on permissions) and
        workflow["name"] == "Qualification" and
        workflow["permissions"] == %{"contents" => "read"},
      "qualification workflow control is invalid"
    )

    assert(
      workflow["on"] == %{"workflow_call" => nil},
      "qualification trigger must be workflow_call only"
    )
  end

  defp assert_publish(workflow, root) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(jobs name on permissions) and
        workflow["name"] == "Publish to Hex" and
        workflow["permissions"] == %{"contents" => "read"},
      "publish workflow control is invalid"
    )

    assert(
      workflow["on"] == %{"workflow_dispatch" => nil},
      "publish trigger must be workflow_dispatch only"
    )

    assert_runtime(workflow, root)

    # Exact workflow, job, and step maps keep HEX_API_KEY and secrets references
    # exclusively in the final publish step's environment.
    assert(
      workflow["jobs"] == %{
        "publish" => %{
          "name" => "Publish",
          "if" => @publish_owner_condition,
          "environment" => "publish",
          "runs-on" => "ubuntu-24.04",
          "timeout-minutes" => 4,
          "permissions" => %{"contents" => "read"},
          "env" => %{"MIX_ENV" => "dev"},
          "steps" => [
            %{
              "name" => "Refuse publishing outside the default branch",
              "run" => ~s(test "$GITHUB_REF" = "refs/heads/main")
            },
            %{"uses" => @checkout, "with" => %{"persist-credentials" => false}},
            %{
              "uses" => @setup_beam,
              "with" => @setup_beam_inputs
            },
            %{"run" => "scripts/assert-runtime-version.sh"},
            %{"run" => "mix local.hex --force"},
            %{"run" => "mix local.rebar --force"},
            %{"name" => "Fetch dependencies", "run" => "mix deps.get --check-locked"},
            %{"run" => "mix docs --warnings-as-errors"},
            %{
              "name" => "Build and inspect Hex package",
              "run" => @publish_package_inspection
            },
            %{
              "name" => "Refuse an already released version",
              "env" => %{"GH_TOKEN" => "${{ github.token }}"},
              "run" => @publish_unreleased_check
            },
            %{
              "name" => "Publish to hex.pm",
              "env" => %{"HEX_API_KEY" => "${{ secrets.HEX_API_KEY }}"},
              "run" =>
                "env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION scripts/with-release-runtime.sh mix hex.publish --yes"
            }
          ]
        }
      },
      "publish job contract is invalid"
    )
  end

  defp assert_workflow_runners(root) do
    root
    |> Path.join(".github/workflows/*.{yml,yaml}")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      workflow = YamlElixir.read_from_file!(path)
      assert_actions(workflow)
      assert_workflow_controls(workflow)

      Enum.each(Map.get(workflow, "jobs", %{}), fn {name, job} ->
        if Map.has_key?(job, "uses") do
          assert(not Map.has_key?(job, "runs-on"), "workflow caller cannot select a runner")
        else
          assert(job["runs-on"] == "ubuntu-24.04", "workflow job runner must be ubuntu-24.04")
          assert_timeout(path, name, job["timeout-minutes"])
        end

        Enum.each(Map.get(job, "steps", []), fn step ->
          if String.starts_with?(Map.get(step, "uses", ""), "actions/checkout@") do
            assert(
              get_in(step, ["with", "persist-credentials"]) == false,
              "checkout must disable persisted credentials"
            )
          end
        end)
      end)
    end)
  end

  defp assert_timeout(path, name, timeout) do
    pattern = ~r/^  #{Regex.escape(name)}:\n.*?(?=^  [a-z][a-z0-9-]+:\n|\z)/ms
    [block] = Regex.run(pattern, File.read!(path)) || fail("CI job source is missing")

    case Regex.run(~r/# Green run ([0-9]+):[^\n]*?([0-9]+)m([0-9]+)s/, block) do
      [_comment, run, minutes, seconds] ->
        measured = String.to_integer(minutes) * 60 + String.to_integer(seconds)
        expected = max(3, div(2 * measured + 59, 60))

        assert(
          run == "44214414813" and measured > 0 and is_integer(timeout) and timeout == expected,
          "CI timeout must follow its measured green run with 2x headroom and the 3-minute floor"
        )

      _missing ->
        fail("CI timeout needs its measured green run and duration comment")
    end
  end

  defp assert_ci_sources(root) do
    for {path, expected} <- [
          {"scripts/audit-fixtures.sh", @fixture_audit_script},
          {"scripts/assert-release-tree.sh", @release_tree_script},
          {"test/fixtures/upgrade_0_4_app/mix.exs", @upgrade_fixture_project}
        ] do
      assert(
        File.read!(Path.join(root, path)) == expected,
        "CI safety script contract is invalid"
      )
    end

    for {path, expected} <- [
          {"scripts/verify-release.sh", @github_target_lookup},
          {"scripts/qualify.py", @qualification_lookup},
          {"scripts/test-release-guards.sh", @github_guard_tests}
        ] do
      source = File.read!(Path.join(root, path))
      assert(String.contains?(source, expected), "GitHub API lookup contract is invalid")
    end

    for path <- ["scripts/verify-release.sh", "scripts/qualify.py"] do
      source = File.read!(Path.join(root, path))

      required =
        if String.ends_with?(path, ".py"),
          do: ~s|if not os.environ.get("GH_TOKEN"):|,
          else: ~s([[ -n "${GH_TOKEN:-}" ]] || fail "GitHub token is required")

      assert(
        String.contains?(source, required),
        "GitHub lookup must require its environment token"
      )
    end

    upgrade = File.read!(Path.join(root, "test/integration/upgrade_checkpoint_test.exs"))

    assert(
      String.contains?(
        upgrade,
        ~s|assert_cmd!(:deps_get, mix, ["deps.get", "--check-locked"], temp, env)|
      ),
      "upgrade consumer must fetch its inherited lock without changes"
    )

    checker = Path.join(root, "test/fixtures/release_checker")

    assert(
      not File.exists?(Path.join(checker, "mix.exs")) and
        not File.exists?(Path.join(checker, "mix.lock")) and
        File.regular?(Path.join(checker, "recorded.lock")),
      "release checker fixtures must be recorded data, never an Elixir project"
    )

    for label <- ["exact-floors", "latest-compatible"] do
      path = Path.join(root, "locks/#{label}.lock")
      assert(File.read!(path) != "", "compatibility lane needs a committed lock")
    end
  end

  defp assert_qualification_inventory(root, workflow) do
    expected =
      workflow
      |> Map.fetch!("jobs")
      |> Enum.flat_map(fn {_id, job} ->
        rows = get_in(job, ["strategy", "matrix", "include"]) || [%{}]
        Enum.map(rows, &qualification_check_name(job["name"], &1))
      end)
      |> Enum.sort()

    inventory =
      root
      |> Path.join("scripts/qualification-jobs.json")
      |> File.read!()
      |> Jason.decode!()

    assert(inventory == expected, "qualification check inventory differs from proof jobs")
  end

  defp qualification_check_name(name, row) do
    assert(is_binary(name), "qualification proof job name is missing")

    expanded =
      Regex.replace(~r/\$\{\{\s*matrix\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/, name, fn _match, key ->
        value = Map.get(row, key) || fail("qualification job matrix name is incomplete")
        to_string(value)
      end)

    assert(
      not String.contains?(expanded, "${{"),
      "qualification proof job name expression is invalid"
    )

    "qualification / " <> expanded
  end

  # Runtime installation reads .tool-versions directly; no workflow version copies.
  defp assert_runtime(workflow, root) do
    pinned_runtime(root)
    assert(not Map.has_key?(workflow, "env"), "CI runtime must come only from .tool-versions")

    for {_name, job} <- Map.get(workflow, "jobs", %{}),
        {step, index} <- Enum.with_index(Map.get(job, "steps", [])),
        String.starts_with?(Map.get(step, "uses", ""), "erlef/setup-beam@") do
      assert(step["with"] == @setup_beam_inputs, "CI runtime must read strict .tool-versions")

      assert(
        Enum.at(job["steps"], index + 1) == %{"run" => "scripts/assert-runtime-version.sh"},
        "CI runtime installation must immediately refuse a version mismatch"
      )
    end
  end

  defp pinned_runtime(root) do
    pins =
      root
      |> Path.join(".tool-versions")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split/1)

    case pins do
      [["elixir", elixir], ["erlang", otp]] ->
        case Regex.run(~r/\A(\d+\.\d+\.\d+)-otp-(\d+)\z/, elixir) do
          [_elixir, version, major] ->
            assert(
              Regex.match?(~r/\A#{major}(\.\d+)+\z/, otp),
              ".tool-versions Elixir and Erlang majors differ"
            )

            {version, otp}

          nil ->
            fail(".tool-versions Elixir pin is invalid")
        end

      _pins ->
        fail(".tool-versions must pin exactly elixir then erlang")
    end
  end

  defp assert_actions(workflow) do
    actions = semantic_uses(workflow)

    assert(actions != [], "CI Action contract is incomplete")

    assert(
      Enum.all?(actions, &(not String.starts_with?(String.downcase(&1), "actions/cache"))),
      "CI workflows must not use actions/cache"
    )

    assert(
      Enum.all?(actions, fn action ->
        is_binary(action) and
          (String.starts_with?(action, "./") or Regex.match?(@immutable_action, action))
      end),
      "CI contains a non-immutable Action reference"
    )
  end

  defp semantic_uses(workflow) do
    workflow
    |> Map.get("jobs", %{})
    |> Enum.flat_map(fn {_name, job} ->
      job_actions = if is_binary(job["uses"]), do: [job["uses"]], else: []
      step_actions = job |> Map.get("steps", []) |> Enum.map(&Map.get(&1, "uses"))
      job_actions ++ Enum.filter(step_actions, &is_binary/1)
    end)
  end

  defp assert_workflow_controls(workflow) do
    triggers = workflow["on"]
    events = if is_map(triggers), do: Map.keys(triggers), else: List.wrap(triggers)

    assert(
      Enum.all?(events, &(&1 not in ["pull_request", "pull_request_target"])),
      "CI must not run repository code from a pull request"
    )

    for {_name, job} <- Map.get(workflow, "jobs", %{}), step <- Map.get(job, "steps", []) do
      assert(
        not String.contains?(Map.get(step, "run", ""), "${{"),
        "workflow expressions must enter run scripts through step env"
      )
    end

    assert(not Map.has_key?(workflow, "defaults"), "CI workflow can override release shells")

    assert(
      Enum.all?(Map.get(workflow, "jobs", %{}), fn {_name, job} ->
        not Map.has_key?(job, "continue-on-error") and
          Enum.all?(Map.get(job, "steps", []), &(not Map.has_key?(&1, "continue-on-error")))
      end),
      "CI cannot continue on error"
    )
  end

  defp assert_jobs(workflow) do
    jobs = Map.get(workflow, "jobs", %{})

    assert(
      Enum.sort(Map.keys(jobs)) == Enum.sort(Map.keys(@job_steps)),
      "qualification proof job inventory is invalid"
    )

    Enum.each(@job_steps, fn {name, expected_steps} ->
      job = jobs[name] || fail("CI release jobs are incomplete")

      assert(
        Enum.sort(Map.keys(job)) == Enum.sort(@job_keys[name]),
        "CI release job control is invalid"
      )

      assert(job["runs-on"] == "ubuntu-24.04", "CI release runner is invalid")
      assert(job["env"] == @job_env[name], "CI release job environment is invalid")

      if name == "no-database" do
        assert(
          job["permissions"] == %{"contents" => "read"},
          "release guards need read-only contents"
        )
      end

      assert(
        Enum.map(Map.get(job, "steps", []), &step_signature/1) == expected_steps,
        "CI release step contract is invalid"
      )
    end)
  end

  defp step_signature(%{"run" => run} = step) when is_binary(run) do
    assert(
      Map.keys(step) -- ["name", "run", "id", "if", "env"] == [],
      "CI release run step control is invalid"
    )

    # Controls participate in the exact per-job signature, including the token
    # environment admitted only for the dedicated live release-guard step.
    case Map.take(step, ["id", "if", "env"]) do
      controls when map_size(controls) == 0 -> {:run, String.trim(run)}
      controls -> {:run, String.trim(run), controls}
    end
  end

  defp step_signature(%{"uses" => action} = step) when is_binary(action) do
    assert(
      Map.keys(step) -- ["name", "uses", "with"] == [],
      "CI release Action step control is invalid"
    )

    {:uses, action, Map.get(step, "with", :absent)}
  end

  defp step_signature(_step), do: fail("CI release step is invalid")

  defp assert_compatibility(workflow) do
    job = get_in(workflow, ["jobs", "compatibility"]) || fail("CI compatibility job is missing")

    assert(
      job["strategy"] == %{"fail-fast" => false, "matrix" => %{"include" => @matrix}},
      "CI Ash compatibility matrix is invalid"
    )
  end

  defp assert_mix_contract(root) do
    ast = root |> Path.join("mix.exs") |> File.read!() |> Code.string_to_quoted!()
    body = mix_project_body(ast)
    projects = find_definitions(body, :def, :project)
    dependency_lists = find_definitions(body, :defp, :deps)
    ash_requirements = find_module_attributes(body, :ash_requirement)
    replicant_requirements = find_module_attributes(body, :replicant_requirement)
    onetime_requirements = find_module_attributes(body, :onetime_requirement)

    assert(
      exact_project_contract?(projects) and exact_dependency_contract?(dependency_lists) and
        ash_requirements == [@ash_requirement] and
        replicant_requirements == [@replicant_requirement] and
        onetime_requirements == [@onetime_requirement],
      "Mix release contract is incomplete"
    )
  rescue
    _error in [SyntaxError, TokenMissingError] -> fail("Mix release contract is invalid")
  end

  defp mix_project_body(
         {:defmodule, _, [{:__aliases__, _, [:AshReplicant, :MixProject]}, [do: body]]}
       ),
       do: block_expressions(body)

  defp mix_project_body(_ast), do: fail("Mix release contract is incomplete")

  defp exact_project_contract?([project]) when is_list(project) do
    Keyword.get_values(project, :elixir) == ["~> 1.20.3"] and
      match?({:deps, _, []}, Keyword.get(project, :deps))
  end

  defp exact_project_contract?(_projects), do: false

  defp exact_dependency_contract?([dependencies]) when is_list(dependencies) do
    case Enum.filter(dependencies, fn
           {:ash, _requirement} -> true
           {:replicant, _requirement} -> true
           {:ash_onetime, _requirement} -> true
           {:ash_cloak, _requirement} -> true
           _dependency -> false
         end) do
      [
        {:ash, {:ash_requirement, _, []}},
        {:ash_onetime, {:onetime_requirement, _, []}},
        {:ash_cloak, @cloak_requirement},
        {:replicant, {:replicant_requirement, _, []}}
      ] ->
        true

      _dependencies ->
        false
    end
  end

  defp exact_dependency_contract?(_dependency_lists), do: false

  defp assert_replicant_contract(root) do
    lock = root |> Path.join("mix.lock") |> File.read!()

    assert_hex_lock(lock, "replicant", expected_replicant_lock_version(lock))
    assert_hex_lock(lock, "postgrex", "0.22.4")

    session_source = read_dependency_source!(root, "lib/replicant/session_identity.ex")
    sink_source = read_dependency_source!(root, "lib/replicant/sink.ex")
    connection_source = read_dependency_source!(root, "lib/replicant/connection.ex")

    assert(
      String.contains?(session_source, "defmodule Replicant.SessionIdentity"),
      "Replicant package contract is incomplete"
    )

    assert(
      String.contains?(sink_source, "@callback handle_session_identity"),
      "Replicant package contract is incomplete"
    )

    assert(
      String.contains?(sink_source, "@callback handle_slot_origin") and
        String.contains?(sink_source, "def notify_slot_origin"),
      "Replicant checkpoint/slot contract is incomplete"
    )

    assert_replicant_fixed_floor_contract(root, connection_source)

    assert(
      semantic_identity_gate?(connection_source),
      "Replicant actual-session ordering contract is incomplete"
    )
  rescue
    _error in [File.Error, SyntaxError, TokenMissingError] ->
      fail("Replicant package contract input is invalid")
  end

  defp assert_replicant_fixed_floor_contract(root, connection_source) do
    telemetry_source = read_dependency_source!(root, "lib/replicant/telemetry.ex")

    incremental_source =
      read_dependency_source!(root, "lib/replicant/snapshotter/incremental.ex")

    sink_source = read_dependency_source!(root, "lib/replicant/sink.ex")

    assert(
      String.contains?(connection_source, "reason: :checkpoint_unknown"),
      "Replicant checkpoint/slot contract is incomplete"
    )

    assert(
      Regex.match?(~r/^\s*@meta_shapes %\{$/m, telemetry_source) and
        String.contains?(telemetry_source, "def validate_measurements!") and
        String.contains?(
          telemetry_source,
          ~s|validate_shapes!(meta, @meta_shapes, "metadata")|
        ),
      "Replicant typed-telemetry contract is incomplete"
    )

    assert(
      Regex.match?(~r/^\s*@max_table_attempts 3\s*$/m, incremental_source) and
        Regex.match?(
          ~r/^\s*def keyed_retry_decision\(attempts, _qualified, :window_reset\)/m,
          incremental_source
        ) and
        String.contains?(incremental_source, "attempt >= @max_table_attempts"),
      "Replicant keyed-contention contract is incomplete"
    )

    assert(
      String.contains?(sink_source, "binary() | nil | :backfill_pending") and
        String.contains?(connection_source, "def classify_progress({:ok, :backfill_pending})") and
        String.contains?(
          incremental_source,
          "def classify_durable_progress(:backfill_pending, :sink_owned)"
        ),
      "Replicant pending-backfill contract is incomplete"
    )

    assert(
      String.contains?(
        connection_source,
        "Replicant.Sink.sink_kind(state.sink) != :append_log"
      ),
      "Replicant append idle-advance contract is incomplete"
    )
  end

  defp expected_replicant_lock_version(lock) do
    case System.get_env("ASH_REPLICANT_REPLICANT_VERSION") do
      value when value in [nil, ""] ->
        "1.5.1"

      "latest" ->
        lock
        |> hex_lock_version("replicant")
        |> validate_replicant_lock_version!()

      value ->
        validate_replicant_lock_version!(value)
    end
  end

  defp validate_replicant_lock_version!(value) do
    with true <- is_binary(value),
         {:ok, _version} <- Version.parse(value),
         true <- Version.match?(value, @replicant_requirement) do
      value
    else
      _other -> fail("Replicant dependency lock contract is incomplete")
    end
  end

  defp assert_hex_lock(lock, dependency, expected_version) do
    assert(
      hex_lock_version(lock, dependency) == expected_version,
      "Replicant dependency lock contract is incomplete"
    )
  end

  defp hex_lock_version(lock, dependency) do
    escaped_dependency = Regex.escape(dependency)

    pattern =
      Regex.compile!(
        "^\\s*\"#{escaped_dependency}\": \\{:hex, :#{escaped_dependency}, \"([^\"]+)\", " <>
          "\"[0-9a-f]{64}\", \\[[^\\n]*\\], \\[[^\\n]*\\], \"hexpm\", \"[0-9a-f]{64}\"\\},$",
        "m"
      )

    case Regex.run(pattern, lock) do
      [_entry, version] -> version
      _other -> fail("Replicant dependency lock contract is incomplete")
    end
  end

  defp read_dependency_source!(root, path),
    do: root |> Path.join("deps/replicant") |> Path.join(path) |> File.read!()

  defp semantic_identity_gate?(source) do
    ast = Code.string_to_quoted!(source)

    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:handle_result, _, _} = head, [do: body]]} = node, clauses ->
          {node, [{head, body} | clauses]}

        node, clauses ->
          {node, clauses}
      end)

    Enum.any?(clauses, fn {head, body} ->
      String.contains?(Macro.to_string(head), "step: :identity_check") and
        exact_identity_gate_body?(body)
    end)
  end

  defp exact_identity_gate_body?({:with, _, [first, second, [do: success, else: _failure]]}) do
    match?({:<-, _, [_, _]}, first) and
      match?({:<-, _, [_, _]}, second) and
      first |> generator_rhs() |> Macro.to_string() ==
        "Replicant.SessionIdentity.from_result(result)" and
      second
      |> generator_rhs()
      |> Macro.to_string()
      |> String.starts_with?("Replicant.Sink.accept_session_identity(state.sink, identity,") and
      Macro.to_string(success) == "begin_recovery(state)"
  end

  defp exact_identity_gate_body?(_body), do: false

  defp generator_rhs({:<-, _, [_pattern, rhs]}), do: rhs

  defp find_definitions(expressions, kind, name) do
    Enum.flat_map(expressions, fn
      {^kind, _, [{^name, _, context}, [do: body]]} when context in [nil, []] -> [body]
      _node -> []
    end)
  end

  defp find_module_attributes(expressions, name) do
    Enum.flat_map(expressions, fn
      {:@, _, [{^name, _, [value]}]} -> [value]
      _node -> []
    end)
  end

  defp block_expressions({:__block__, _, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp assert_docs(root) do
    Enum.each(@doc_contracts, fn {path, heading, required_texts} ->
      visible = root |> Path.join(path) |> File.read!() |> visible_markdown()
      section = section(visible, heading)

      assert(section != nil, "published runtime or dependency contract section is missing")
      normalized_section = normalize_markdown(section)

      assert(
        Enum.all?(required_texts, &String.contains?(normalized_section, normalize_markdown(&1))),
        "published runtime or dependency contract is incomplete"
      )

      assert(
        not Regex.match?(
          ~r/(?:unsupported release foundation|does(?:[\s\p{Cf}]+not|n't)[\s\p{Cf}]+support[\s\p{Cf}]*(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.33\.4|Replicant 1(?:\.x|\.\d+(?:\.\d+)?))|(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.33\.4|Replicant 1(?:\.x|\.\d+(?:\.\d+)?))[\s\p{Cf}]*(?:is[\s\p{Cf}]+)?not[\s\p{Cf}]+supported)/iu,
          visible
        ),
        "published runtime or dependency contract is contradictory"
      )
    end)
  end

  defp assert_b1_docs(root) do
    Enum.each(@b1_doc_contracts, fn {path, heading, required_texts} ->
      visible = root |> Path.join(path) |> File.read!() |> visible_markdown()
      section = section(visible, heading)

      assert(section != nil, "published destination boundary section is missing")
      normalized_section = normalize_markdown(section)

      assert(
        Enum.all?(required_texts, &String.contains?(normalized_section, normalize_markdown(&1))),
        "published destination boundary contract is incomplete"
      )
    end)
  end

  defp assert_b1_examples(root) do
    Enum.each(["README.md", "usage-rules.md"], fn path ->
      content = root |> Path.join(path) |> File.read!()

      pattern =
        Regex.compile!(
          Regex.escape(@participant_example_start) <>
            "\\s*```elixir\\s*\\n(?<source>.*?)\\n```\\s*" <>
            Regex.escape(@participant_example_end),
          "s"
        )

      case Regex.scan(pattern, content, capture: :all_names) do
        [[source]] -> compile_b1_example(source, path)
        _matches -> fail("published destination participant example count is invalid")
      end
    end)
  end

  defp compile_b1_example(source, path) do
    {result, diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          {:ok, Code.compile_string(source, path)}
        rescue
          _error -> :error
        catch
          _kind, _reason -> :error
        end
      end)

    compiled =
      case {result, diagnostics} do
        {{:ok, [_ | _] = compiled}, []} -> compiled
        _other -> fail("published destination participant example does not compile cleanly")
      end

    Enum.each(compiled, fn {module, _binary} ->
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp assert_no_b1_positive_contradictions(root) do
    visible =
      @b1_contract_paths
      |> Enum.map_join("\n", fn path ->
        root |> Path.join(path) |> File.read!() |> visible_markdown()
      end)
      |> normalize_markdown()
      |> String.downcase()

    assert(
      Enum.all?(@b1_forbidden_positive_claims, fn claim ->
        not String.contains?(visible, claim |> normalize_markdown() |> String.downcase())
      end),
      "published destination boundary contract contains a stale positive claim"
    )
  end

  defp assert_census_contract(root) do
    Enum.each(@census_doc_contracts, fn {path, heading, required_texts} ->
      content = root |> Path.join(path) |> File.read!() |> visible_markdown()
      section = section(content, heading)

      assert(section != nil, "published continuous-census contract section is missing")

      normalized_section = normalize_markdown(section)

      assert(
        Enum.all?(required_texts, &String.contains?(normalized_section, normalize_markdown(&1))),
        "published continuous-census contract is incomplete"
      )
    end)

    Enum.each(@census_source_contracts, fn {path, required} ->
      source = root |> Path.join(path) |> File.read!()

      assert(
        String.contains?(source, required),
        "continuous-census package contract is incomplete"
      )
    end)
  rescue
    _error in [File.Error] -> fail("continuous-census package contract input is invalid")
  end

  defp assert_upgrade_contract(root) do
    Enum.each(@upgrade_doc_contracts, fn {path, heading, required_texts} ->
      visible = root |> Path.join(path) |> File.read!() |> visible_markdown()

      if is_nil(heading) do
        # Whole-file pins: the entry must exist, wherever the changelog
        # structure places it.
        assert(
          Enum.all?(
            required_texts,
            &String.contains?(normalize_markdown(visible), normalize_markdown(&1))
          ),
          "published upgrade contract is incomplete"
        )
      else
        section = section(visible, heading)

        assert(section != nil, "published upgrade contract section is missing")
        normalized_section = normalize_markdown(section)

        assert(
          Enum.all?(
            required_texts,
            &String.contains?(normalized_section, normalize_markdown(&1))
          ),
          "published upgrade contract is incomplete"
        )
      end
    end)

    Enum.each(@upgrade_source_contracts, fn {path, required} ->
      source = root |> Path.join(path) |> File.read!()
      assert(String.contains?(source, required), "upgrade package contract is incomplete")
    end)
  rescue
    _error in [File.Error] -> fail("upgrade package contract input is invalid")
  end

  defp visible_markdown(content) do
    content
    |> then(&Regex.replace(~r/<!--.*?-->/s, &1, ""))
    |> String.split("\n")
    |> remove_code_lines()
    |> Enum.join("\n")
    |> decode_html_entities()
  end

  defp remove_code_lines(lines) do
    {visible, _fence} = Enum.reduce(lines, {[], nil}, &reduce_code_line/2)

    Enum.reverse(visible)
  end

  defp reduce_code_line(line, {visible, fence}) do
    case fence do
      nil ->
        case fence_marker(line) do
          nil -> reduce_visible_line(line, visible)
          marker -> {visible, marker}
        end

      marker ->
        if closing_fence?(line, marker), do: {visible, nil}, else: {visible, marker}
    end
  end

  defp reduce_visible_line(line, visible) do
    if String.starts_with?(line, "    ") or String.starts_with?(line, "\t"),
      do: {visible, nil},
      else: {[line | visible], nil}
  end

  defp fence_marker(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})/, line) do
      [_, marker] -> {String.first(marker), String.length(marker)}
      _ -> nil
    end
  end

  defp closing_fence?(line, {character, length}) do
    case Regex.run(~r/^ {0,3}(`+|~+)[ \t]*$/, line) do
      [_, marker] -> String.first(marker) == character and String.length(marker) >= length
      _ -> false
    end
  end

  defp decode_html_entities(content) do
    content
    |> then(
      &Regex.replace(~r/&#([0-9]+);/, &1, fn _, digits ->
        digits |> String.to_integer() |> List.wrap() |> List.to_string()
      end)
    )
    |> then(
      &Regex.replace(~r/&#x([0-9a-f]+);/i, &1, fn _, digits ->
        digits |> String.to_integer(16) |> List.wrap() |> List.to_string()
      end)
    )
    |> then(
      &Regex.replace(~r/&([A-Za-z][A-Za-z0-9]+);/, &1, fn entity, name ->
        if name in @named_separator_entities, do: " ", else: entity
      end)
    )
  rescue
    _error in [ArgumentError, UnicodeConversionError] ->
      fail("published contract entity is invalid")
  end

  defp normalize_markdown(content) do
    content
    |> String.replace(~r/[\s\p{Cf}]+/u, " ")
    |> String.trim()
  end

  defp section(content, heading) do
    lines = String.split(content, "\n")
    start = Enum.find_index(lines, &(&1 == heading))

    if start do
      level = heading |> String.split(" ", parts: 2) |> hd() |> String.length()

      lines
      |> Enum.drop(start)
      |> Enum.take_while(fn line ->
        line == heading or not heading_at_or_above?(line, level)
      end)
      |> Enum.join("\n")
    end
  end

  defp heading_at_or_above?(line, level) do
    case Regex.run(~r/^(#+)\s+/, line) do
      [_, marks] -> String.length(marks) <= level
      _ -> false
    end
  end

  defp assert(true, _message), do: :ok
  defp assert(false, message), do: fail(message)

  defp fail(message) do
    raise ReleaseContractError, message: message
  end
end
