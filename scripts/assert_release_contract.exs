unless Code.ensure_loaded?(AshReplicant.DependencyRequirements) do
  Code.require_file(Path.expand("../lib/ash_replicant/dependency_requirements.ex", __DIR__))
end

Code.require_file(Path.join(__DIR__, "dependency_lanes.exs"))

defmodule AshReplicant.ReleaseContractError do
  defexception [:message]
end

defmodule AshReplicant.ReleaseContract do
  alias AshReplicant.DependencyLanes
  alias AshReplicant.DependencyRequirements
  alias AshReplicant.ReleaseContractError
  alias Jason.DecodeError
  alias YamlElixir.ParsingError

  @fail_late "${{ !cancelled() && steps.compile.outcome == 'success' }}"
  @report_if "${{ !cancelled() && steps.runtime.outcome == 'success' }}"
  @immutable_action ~r/\A[^@\s]+@[0-9a-f]{40}\z/
  @postgres_action "./.github/actions/postgres"

  @public_engine_check ~S"""
  engine="$(cat .github/postgres.ref)"
  [[ "$engine" =~ ^ghcr\.io/baselabs/postgres:[0-9]+\.[0-9]+-inputs-[0-9a-f]{64}@sha256:[0-9a-f]{64}$ ]]
  current_digest="$(python3 - <<'PY'
  import json, re, time, urllib.error, urllib.request
  host, path = 'ghcr.io', 'baselabs/postgres'
  def read(request, answer):
      for attempt in range(3):
          try:
              with urllib.request.urlopen(request, timeout=30) as response:
                  return answer(response)
          except urllib.error.HTTPError as error:
              if (error.code != 429 and error.code < 500) or attempt == 2:
                  raise
          except OSError:
              if attempt == 2:
                  raise
          time.sleep(10 * (attempt + 1))
  token = read(f'https://{host}/token?scope=repository:{path}:pull', lambda response: json.load(response)['token'])
  request = urllib.request.Request(f'https://{host}/v2/{path}/manifests/current', method='HEAD', headers={
      'Authorization': 'Bearer ' + token,
      'Accept': ', '.join(('application/vnd.oci.image.index.v1+json', 'application/vnd.oci.image.manifest.v1+json',
                           'application/vnd.docker.distribution.manifest.list.v2+json',
                           'application/vnd.docker.distribution.manifest.v2+json'))})
  digest = read(request, lambda response: response.headers.get('Docker-Content-Digest', ''))
  if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
      raise SystemExit('ghcr.io/baselabs/postgres:current: registry named no digest')
  print(digest)
  PY
  )"
  if [ "${engine##*@}" != "$current_digest" ]; then
    echo 'checked PostgreSQL digest differs from ghcr.io/baselabs/postgres:current' >&2; exit 1
  fi
  docker pull "$engine"
  """

  @postgres_manage ~S"""
  set -euo pipefail
  [[ "$CONTAINER" =~ ^[a-z][a-z0-9-]*$ && "$PORT" =~ ^[1-9][0-9]{3,4}$ ]]
  hba="${RUNNER_TEMP:?}/postgres-$CONTAINER-hba.conf"
  case "$MODE" in
    stop)
      cleanup_status=0
      if docker container inspect "$CONTAINER" > /dev/null 2>&1; then
        docker logs "$CONTAINER" || cleanup_status=1
        docker rm -f -v "$CONTAINER" || cleanup_status=1
      fi
      rm -f "$hba"
      exit "$cleanup_status"
      ;;
    start) ;;
    *) echo 'mode must be start or stop' >&2; exit 1 ;;
  esac
  settings=(-c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20)
  if [[ -z "$IMAGE" ]]; then
    [[ "$DECODER_SOURCE" == false ]]
    engine="$(cat .github/postgres.ref)"
    docker run --detach --pull=never --name "$CONTAINER" \
      --publish "127.0.0.1:$PORT:5432" \
      --tmpfs /var/lib/pg:uid=26,gid=26,mode=0750 --tmpfs /tmp \
      --env TEST_PG_USER --env TEST_PG_PASSWORD --env TEST_PG_DATABASE \
      --entrypoint baselabs-test-postgres "$engine" "${settings[@]}"
  else
    mounts=()
    case "$DECODER_SOURCE" in
      true)
        [[ "$IMAGE" =~ ^sha256:[0-9a-f]{64}$ ]]
        # Peer for entrypoint initialization; all host logins require a password.
        settings+=(-c output_plugin_libraries=pgoutput,pglogical_output)
        printf 'local all all peer\nhost all all all scram-sha-256\nhost replication all all scram-sha-256\n' > "$hba"
        mounts=(--volume "$hba:/hba.conf:ro")
        settings+=(-c shared_preload_libraries=pglogical -c hba_file=/hba.conf)
        ;;
      false)
        [[ "$IMAGE" =~ ^postgres:[0-9][a-z0-9.-]*@sha256:[0-9a-f]{64}$ ]]
        docker pull "$IMAGE"
        ;;
      *) echo 'decoder-source must be true or false' >&2; exit 1 ;;
    esac
    docker run --detach --pull=never --name "$CONTAINER" \
      --publish "127.0.0.1:$PORT:5432" \
      --env POSTGRES_USER --env POSTGRES_PASSWORD --env POSTGRES_DB \
      "${mounts[@]}" "$IMAGE" "${settings[@]}"
  fi
  ready=false
  for ((attempt=0; attempt<60; attempt++)); do
    if docker exec "$CONTAINER" pg_isready -h 127.0.0.1 -U "$TEST_PG_USER" -d "$TEST_PG_DATABASE"; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    docker logs "$CONTAINER"
    echo 'PostgreSQL did not become ready within 60 attempts' >&2
    exit 1
  fi
  """

  @checkout "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
  @setup_beam "erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124"
  @participant_example_start "<!-- ash-replicant-destination-participant-example:start -->"
  @participant_example_end "<!-- ash-replicant-destination-participant-example:end -->"

  @toolchain_action "./.github/actions/toolchain"
  @beam_action "./.github/actions/beam"
  @runtime_inputs %{
    "elixir" => "${{ steps.toolchain.outputs.elixir }}",
    "otp" => "${{ steps.toolchain.outputs.otp }}"
  }
  @toolchain_sha256 "25bbfa023b7f031256428b498fe300fcc460988fea81277072355e4c0d933764"

  @hex_action "baselabs/.github/.github/actions/hex-publish@654fcd0ef63daf8e3f79dfeb4ca900adffd0d4e2"
  @download_artifact "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333"
  @upload_artifact "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"
  @hex_identity %{"package" => "ash_replicant", "package-directory" => "."}
  @release_commit "${{ inputs.release_commit }}"

  @publish_ref_guard ~S"""
  [[ "$GITHUB_REF" == "refs/heads/$DEFAULT_BRANCH" ]]
  [[ "$RELEASE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
  """

  @publish_runtime_reader ~S"""
  reader="$RUNNER_TEMP/hex-release-toolchain.sh"
  git show HEAD:scripts/toolchain.sh > "$reader"
  printf '%s  %s\n' 25bbfa023b7f031256428b498fe300fcc460988fea81277072355e4c0d933764 "$reader" | sha256sum --check --status
  git show HEAD:.tool-versions > "$RUNNER_TEMP/hex-release-tool-versions"
  pins="$(bash "$reader" "$RUNNER_TEMP/hex-release-tool-versions")"
  elixir="$(awk -F= '$1 == "elixir" { print $2 }' <<< "$pins")"
  otp="$(awk -F= '$1 == "otp" { print $2 }' <<< "$pins")"
  [[ "$elixir" =~ ^[0-9]+\.[0-9]+\.[0-9]+-otp-[0-9]+$ ]]
  [[ "$otp" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  printf 'elixir=%s\notp=%s\n' "$elixir" "$otp" >> "$GITHUB_OUTPUT"
  """

  @publish_runtime_install ~S"""
  bash "$RUNNER_TEMP/hex-release-toolchain.sh" --installed "elixir=$WANT_ELIXIR" "erlang=$WANT_OTP"
  test ! -e mix.exs
  hex_version="$(curl --fail --silent --show-error --max-time 30 'https://raw.githubusercontent.com/baselabs/.github/654fcd0ef63daf8e3f79dfeb4ca900adffd0d4e2/.github/actions/hex-publish/hex-version')"
  [[ "$hex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  mix local.hex "$hex_version" --force
  """

  @install_hex ~S"""
  test ! -e mix.exs
  hex_version="$(curl --fail --silent --show-error --max-time 30 'https://raw.githubusercontent.com/baselabs/.github/654fcd0ef63daf8e3f79dfeb4ca900adffd0d4e2/.github/actions/hex-publish/hex-version')"
  [[ "$hex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  mix local.hex "$hex_version" --force
  installed=$(mix hex.info | awk '$1 == "Hex:" {print $2}')
  if [ "$installed" != "$hex_version" ]; then
    echo "::error::Installed Hex $installed; expected $hex_version."
    exit 1
  fi
  echo "Hex $installed, as pinned"
  """

  @publish_owner_condition "contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.actor) && contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.triggering_actor)"

  @fresh_consumer_audits ~S"""
  consumer_mix deps.get >/dev/null
  consumer_mix hex.audit
  (cd "$root" && mix deps.audit --path "$consumer")
  consumer_mix deps.compile >/dev/null
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
  """

  @drift_refusal ~S"""
  if [[ "$GITHUB_REF" != "refs/heads/$DEFAULT_BRANCH" ]]; then
    echo 'Drift reports run only on the default branch.' >&2
    exit 1
  fi
  """

  @drift_newest_checks [
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest ash",
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest replicant",
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest ash_onetime",
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest ash_postgres",
    "scripts/assert-dependency-version.sh --lock locks/latest-compatible.lock --newest spark"
  ]

  @drift_resolution """
  rm mix.lock
  mix deps.get
  """

  @drift_versions ~S"""
  mix run --no-mix-exs --no-start -e '
  workspace = System.fetch_env!("GITHUB_WORKSPACE")

  versions = fn path ->
    path = Path.join(workspace, path)
    unless File.regular?(path), do: raise("dependency resolution lock is missing")

    Map.new(Mix.Dep.Lock.read(path), fn
      {name, {:hex, _, version, _, _, _, _, _}} -> {name, version}
    end)
  end

  locked = versions.("locks/latest-compatible.lock")
  resolved = versions.("mix.lock")

  (Map.keys(locked) ++ Map.keys(resolved))
  |> Enum.uniq()
  |> Enum.sort()
  |> Enum.each(fn name ->
    IO.puts("#{name}: committed=#{locked[name] || "absent"} resolved=#{resolved[name] || "absent"}")
  end)
  '
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

  @command_status_guards [
    {"scripts/with-release-runtime.sh",
     ~S"""
     pins="$("$root/scripts/toolchain.sh" "$root/.tool-versions")"
     """},
    {"scripts/with-release-runtime.sh",
     ~S"""
     "$root/scripts/toolchain.sh" --installed "elixir=$elixir_pin" "erlang=$erlang_pin"
     """},
    {"config/config.exs",
     ~S"""
     {output, status} = System.cmd(reader, [Path.join(root, ".tool-versions")], stderr_to_stdout: true)
     """},
    {"config/config.exs",
     ~S"""
     actual_elixir = System.version() <> "-otp-" <> System.build_info()[:otp_release]
     """},
    {"scripts/run-structural-tests.sh",
     ~S"""
     logger_error_count="$(grep -Ec '(^|[[:space:]])\[error\]' "$raw_output")" || [[ $? -eq 1 ]]
     exception_banner_count="$(grep -Ec '\*\* \(' "$raw_output")" || [[ $? -eq 1 ]]
     """},
    {"scripts/assert-exunit-output.sh",
     ~S"""
     result_count="$(grep -c '^Result: ' "$output_file")" || [[ $? -eq 1 ]]
     """},
    {"scripts/bump-version.sh",
     ~S"""
     charter_updated="$(grep -o '\*\*Updated:\*\* [0-9-]*' docs/CHARTER.md | cut -d' ' -f2)"
     """},
    {"scripts/bump-version.sh",
     ~S"""
       count="$(grep -cF "$old" "$file")" || [[ $? -eq 1 ]]
     """}
  ]

  @job_env %{
    "postgres-lanes" => nil,
    "no-database" => %{
      "MIX_ENV" => "test",
      "EXPECTED_PG_MAJOR" => "${{ needs.postgres-lanes.outputs.engine_major }}"
    },
    "compatibility" => %{
      "EXPECTED_PG_MAJOR" => "${{ matrix.pg_major }}",
      "MIX_ENV" => "test",
      "ASH_REPLICANT_ASH_VERSION" => "${{ matrix.ash_selector }}",
      "ASH_REPLICANT_REPLICANT_VERSION" => "${{ matrix.replicant_selector }}",
      "ASH_REPLICANT_ONETIME_VERSION" => "${{ matrix.onetime_selector }}",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test"
    },
    "release-artifact" => %{"MIX_ENV" => "dev"},
    "fresh-consumer" => %{
      "EXPECTED_PG_MAJOR" => "${{ needs.postgres-lanes.outputs.engine_major }}",
      "MIX_ENV" => "dev",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test"
    },
    "performance" => %{
      "EXPECTED_PG_MAJOR" => "${{ needs.postgres-lanes.outputs.engine_major }}",
      "MIX_ENV" => "test",
      "ASH_REPLICANT_TEST_URL" =>
        "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test",
      "ASH_REPLICANT_PERFORMANCE" => "1"
    },
    "decoder-sources" => %{
      "EXPECTED_PG_SOURCE_MAJOR" => "${{ matrix.pg_major }}",
      "EXPECTED_PG_MAJOR" => "${{ needs.postgres-lanes.outputs.engine_major }}",
      "MIX_ENV" => "test",
      "ASH_REPLICANT_TEST_URL" =>
        "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test",
      "ASH_REPLICANT_DECODER_SOURCE_URL" =>
        "postgres://postgres:postgres@127.0.0.1:5433/ash_replicant_test"
    }
  }

  @job_keys %{
    "postgres-lanes" => ~w(name outputs runs-on steps timeout-minutes),
    "no-database" => ~w(env name permissions runs-on steps timeout-minutes needs),
    "compatibility" => ~w(env name runs-on steps strategy timeout-minutes needs),
    "release-artifact" => ~w(env name runs-on steps timeout-minutes),
    "fresh-consumer" => ~w(env name permissions runs-on steps timeout-minutes needs),
    "performance" => ~w(env name runs-on steps timeout-minutes needs),
    "decoder-sources" => ~w(env name runs-on steps strategy timeout-minutes needs)
  }

  @job_steps %{
    "postgres-lanes" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, "scripts/ci/postgres-lanes.sh", %{"id" => "lanes"}},
      {:run, "python3 -B -m unittest discover -s scripts -p 'test_postgres_lanes.py'"}
    ],
    "no-database" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors", %{"id" => "compile"}},
      {:run, "mix format --check-formatted", %{"if" => @fail_late}},
      {:run, "elixir --version", %{"if" => @fail_late}},
      {:run, "scripts/test-prepush.sh", %{"if" => @fail_late}},
      {:run, "scripts/test-release-checkers.sh", %{"if" => @fail_late}},
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
      {:uses, @postgres_action, %{"image" => "${{ matrix.pg_image }}"}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, String.trim(@resolve_dependencies),
       %{
         "env" => %{
           "LOCKFILE" => "${{ matrix.lockfile }}",
           "ASH_REQUIREMENT" => "${{ matrix.ash_requirement }}",
           "REPLICANT_REQUIREMENT" => "${{ matrix.replicant_requirement }}",
           "ONETIME_REQUIREMENT" => "${{ matrix.onetime_requirement }}"
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
      {:run, "mix dialyzer", %{"if" => @fail_late}},
      {:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}}
    ],
    "performance" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @postgres_action, :absent},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, String.trim(@create_database)},
      {:run,
       "scripts/run-structural-tests.sh test/integration/performance_bounds_test.exs --include integration"},
      {:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}}
    ],
    "decoder-sources" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run,
       ~S"""
       docker build -f test/support/pglogical.dockerfile --build-arg "BASE=$PG_BASE" \
         -t decoder-source-plugins:ci .
       image="$(docker image inspect --format '{{.Id}}' decoder-source-plugins:ci)"
       printf 'image=%s\n' "$image" >> "$GITHUB_OUTPUT"
       """
       |> String.trim(),
       %{
         "id" => "plugins",
         "env" => %{"PG_BASE" => "${{ matrix.base }}"}
       }},
      {:uses, @postgres_action, :absent},
      {:uses, @postgres_action,
       %{
         "name" => "decoder-source",
         "port" => "5433",
         "image" => "${{ steps.plugins.outputs.image }}",
         "decoder-source" => "true"
       }},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, String.trim(@create_database)},
      {:run, "scripts/run-structural-tests.sh test/integration/decoder_admission_test.exs"},
      {:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}},
      {:uses, @postgres_action, %{"mode" => "stop", "name" => "decoder-source", "port" => "5433"},
       %{"if" => "always()"}}
    ],
    "fresh-consumer" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:run, "mix deps.get --check-locked"},
      {:run, "mix deps.compile"},
      {:uses, @postgres_action, :absent},
      {:uses, @download_artifact,
       %{"name" => "hex-hexpm-ash_replicant", "path" => "${{ runner.temp }}/qualified-hex"}},
      {:run, ~s(scripts/test-fresh-consumer.sh "$RUNNER_TEMP/qualified-hex/package.tar")},
      {:run, ~s(rm -rf "$RUNNER_TEMP/qualified-hex"), %{"if" => "always()"}},
      {:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}}
    ],
    "release-artifact" => [
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs},
      {:uses, @hex_action, Map.put(@hex_identity, "operation", "qualify")}
    ]
  }

  @named_separator_entities ~w(
    af ApplyFunction emsp13 emsp14 emsp ensp hairsp ic InvisibleComma
    InvisibleTimes it lrm MediumSpace nbsp NegativeMediumSpace NegativeThickSpace
    NegativeThinSpace NegativeVeryThinSpace NewLine NoBreak NonBreakingSpace numsp
    puncsp rlm shy Tab ThickSpace thinsp ThinSpace VeryThinSpace ZeroWidthSpace zwj zwnj
  )

  defp doc_contracts(root) do
    requirements = public_requirements(root)

    [
      {"README.md", "### Supported foundation",
       [
         "- Elixir 1.20.3 on Erlang/OTP 29;",
         "- Ash `#{requirements.ash}` (current lock 3.38.1);",
         "- AshPostgres `#{requirements.ash_postgres}` (current lock 2.15.2 with AshSql 0.8.8; qualification tests the reviewed compatibility lock);",
         "- Spark `#{requirements.spark}` (effective floor 2.7.6 through Ash; current lock 2.7.9);",
         "- Replicant `#{requirements.replicant}` (current lock 2.0.0)",
         "- Postgrex `#{requirements.postgrex}` (current lock 0.23.0);",
         "- DBConnection `#{requirements.db_connection}` (current lock 2.10.3).",
         "- AshOnetime `#{requirements.ash_onetime}` (current lock 1.5.0)",
         "- AshCloak `#{requirements.ash_cloak}` (current lock 0.4.0"
       ]},
      {"CONTRIBUTING.md", "## Prerequisites",
       [
         "- **Elixir 1.20.3** and **Erlang/OTP 29**",
         "- Ash `#{requirements.ash}`; selector-free development uses this public range",
         "- Replicant `#{requirements.replicant}` from Hex; the lock is 2.0.0.",
         "- Postgrex `#{requirements.postgrex}` from Hex; the lock is 0.23.0.",
         "- DBConnection `#{requirements.db_connection}` from Hex. The lock is 2.10.3.",
         "- AshCloak `#{requirements.ash_cloak}` from Hex; the current lock is 0.4.0 (the"
       ]},
      {"AGENTS.md", "## Development workflow",
       [
         "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
           "`#{requirements.ash}` (current lock 3.38.1) and Replicant\n" <>
           "`#{requirements.replicant}` (current lock 2.0.0), plus\n" <>
           "AshOnetime `#{requirements.ash_onetime}` (current lock 1.5.0) and AshCloak\n" <>
           "`#{requirements.ash_cloak}` (current lock 0.4.0; releases below 0.4.0 carry\n" <>
           "CVE-2026-81319 and CVE-2026-81322 and are not admitted).",
         "Postgrex requires `#{requirements.postgrex}` (current lock 0.23.0)",
         "DBConnection requires `#{requirements.db_connection}` (current lock 2.10.3)."
       ]},
      {"docs/adr/0002-supported-runtime-and-dependencies.md", nil,
       [
         "Postgrex is declared `#{requirements.postgrex}`",
         "Replicant `#{requirements.replicant}`:",
         "DBConnection is declared `#{requirements.db_connection}`"
       ]},
      {"docs/adr/0005-replicant-coordination.md", nil,
       ["The public dependency is `#{requirements.replicant}`"]}
    ]
  end

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
       "The same owner schedules the C01 continuous invariant census through the admitted\n" <>
         "callback guard (never a second Replicant callback)",
       "The next run is scheduled only after the\n" <>
         "current one settles. Graceful owner/application teardown drains admitted work;"
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
    {"lib/ash_replicant/pipeline_guard.ex",
     "send(owner, {:census_result, token, Census.run(slot, sink)})"},
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
  def run(root) do
    workflow = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/qualification.yml"))
    landing = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/ci.yml"))
    drift = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/drift-report.yml"))

    publish = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/publish.yml"))

    assert_landing(landing)
    assert_publish(publish)
    assert_hex_declaration(root)
    assert_qualification(workflow, root)
    assert_drift_report(drift, root)
    assert_workflow_runners(root)
    assert_ci_sources(root)
    assert_postgres(root)
    assert_qualification_inventory(root, workflow)
    assert_runtime(workflow, root)
    assert_jobs(workflow)
    assert_compatibility(workflow)
    assert_mix_contract(root)
    assert_replicant_contract(root)
    assert_checker_wiring(root)
    assert_fresh_consumer(root)
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

    lanes_count =
      source
      |> String.split("\n")
      |> Enum.count(
        &(String.trim(&1) ==
            "python3 -B -m unittest discover -s scripts -p 'test_postgres_lanes.py' >/dev/null")
      )

    assert(lanes_count == 1, "PostgreSQL lane checker wiring is incomplete")
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

  defp assert_fresh_consumer(root) do
    source = File.read!(Path.join(root, "scripts/test-fresh-consumer.sh"))

    assert(
      String.contains?(source, "export MIX_ENV=dev\n") and
        String.contains?(source, @fresh_consumer_audits),
      "fresh consumer must audit its resolved lock from the dev repository root"
    )
  end

  defp assert_landing(workflow) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(concurrency defaults jobs name on permissions) and
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
        "if" => "always()",
        "needs" => ["qualification"],
        "runs-on" => "ubuntu-24.04",
        "timeout-minutes" => 5,
        "permissions" => %{"actions" => "read", "contents" => "read"},
        "steps" => [
          %{"uses" => @checkout, "with" => %{"persist-credentials" => false}},
          %{
            "run" => "python3 scripts/qualify.py",
            "env" => %{
              "GH_TOKEN" => "${{ github.token }}",
              "QUALIFICATION_RESULT" => "${{ needs.qualification.result }}",
              "EXPECTED_CHECKS" => "${{ needs.qualification.outputs.checks }}"
            }
          }
        ]
      },
      "CI qualified verdict job contract is invalid"
    )
  end

  defp assert_qualification(workflow, root) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(defaults jobs name on permissions) and
        workflow["name"] == "Qualification" and
        workflow["permissions"] == %{"contents" => "read"},
      "qualification workflow control is invalid"
    )

    assert(
      workflow["on"] == %{
        "workflow_call" => %{
          "outputs" => %{
            "checks" => %{
              "description" => "Expected qualification check inventory",
              "value" => "${{ jobs.postgres-lanes.outputs.checks }}"
            }
          }
        }
      },
      "qualification must expose its check inventory through workflow_call only"
    )

    source = File.read!(Path.join(root, ".github/workflows/qualification.yml"))
    freshness_queries = ["--newest", "hex.pm/api/packages", "hex-release-candidates"]

    assert(
      not String.contains?(source, freshness_queries) and
        not Regex.match?(~r/\bmix\s+hex\.(?:outdated|info)\b/, source),
      "qualification must not query newest upstream releases"
    )
  end

  defp assert_drift_report(workflow, root) do
    assert(
      Enum.sort(Map.keys(workflow)) == ~w(defaults jobs name on permissions) and
        workflow["name"] == "Dependency drift report" and
        workflow["permissions"] == %{"contents" => "read"} and
        workflow["on"] == %{
          "schedule" => [%{"cron" => "23 6 * * *"}],
          "workflow_dispatch" => nil
        },
      "drift report must be read-only and scheduled or dispatched only"
    )

    jobs = workflow["jobs"] || %{}
    assert(Map.keys(jobs) == ["report"], "drift report cannot supply a qualification verdict")
    job = jobs["report"]

    assert(
      Enum.sort(Map.keys(job)) == ~w(env name runs-on steps timeout-minutes) and
        job["name"] == "Upstream dependencies" and
        job["runs-on"] == "ubuntu-24.04" and job["timeout-minutes"] == 24 and
        job["env"] == %{
          "MIX_ENV" => "test",
          "ASH_REPLICANT_TEST_URL" =>
            "postgres://postgres:postgres@127.0.0.1:5432/ash_replicant_test"
        },
      "drift report job cannot hold secrets, an environment, a cache, or write permissions"
    )

    admission = [
      {:run, String.trim(@drift_refusal),
       %{"env" => %{"DEFAULT_BRANCH" => "${{ github.event.repository.default_branch }}"}}},
      {:uses, @checkout, %{"persist-credentials" => false}},
      {:uses, @toolchain_action, :absent, %{"id" => "toolchain"}},
      {:uses, @beam_action, @runtime_inputs, %{"id" => "runtime"}}
    ]

    reports =
      @drift_newest_checks ++
        [
          String.trim(@drift_resolution),
          {String.trim(@drift_versions), %{"working-directory" => "${{ runner.temp }}"}},
          "mix hex.audit",
          "mix deps.audit",
          "mix deps.compile",
          String.trim(@create_database),
          "mix compile --warnings-as-errors",
          "scripts/run-structural-tests.sh --include integration",
          "scripts/run-structural-tests.sh test/integration --include integration"
        ]

    admission =
      admission ++
        [
          {:run,
           ~S"""
           declarations="$(scripts/ci/postgres-lanes.sh --json)"
           major="$(jq -r .engine_major <<< "$declarations")"
           printf 'EXPECTED_PG_MAJOR=%s\n' "$major" >> "$GITHUB_ENV"
           """
           |> String.trim(), %{"if" => @report_if}}
        ]

    report_steps =
      Enum.map(reports, fn
        {run, controls} -> {:run, run, Map.put(controls, "if", @report_if)}
        run -> {:run, run, %{"if" => @report_if}}
      end)

    expected =
      admission ++
        List.insert_at(
          report_steps,
          10,
          {:uses, @postgres_action, :absent, %{"if" => @report_if}}
        ) ++
        [{:uses, @postgres_action, %{"mode" => "stop"}, %{"if" => "always()"}}]

    assert(
      Enum.map(Map.get(job, "steps", []), &step_signature/1) == expected,
      "drift report must refuse other refs first and report every upstream check independently"
    )

    source = File.read!(Path.join(root, ".github/workflows/drift-report.yml"))
    assert(not String.contains?(source, "secrets."), "drift report must not read any secret")
    assert_runtime(workflow, root, %{"id" => "runtime"})
  end

  defp assert_publish(workflow) do
    common_steps = [
      {:run, String.trim(@publish_ref_guard),
       %{
         "env" => %{
           "DEFAULT_BRANCH" => "${{ github.event.repository.default_branch }}",
           "RELEASE_COMMIT" => @release_commit
         }
       }},
      {:uses, @checkout,
       %{"ref" => @release_commit, "fetch-depth" => 0, "persist-credentials" => false}},
      {:run, String.trim(@publish_runtime_reader), %{"id" => "toolchain"}},
      {:uses, @setup_beam,
       %{
         "elixir-version" => @runtime_inputs["elixir"],
         "otp-version" => @runtime_inputs["otp"],
         "version-type" => "strict",
         "install-hex" => false,
         "install-rebar" => false
       }},
      {:run, String.trim(@publish_runtime_install),
       %{
         "working-directory" => "${{ runner.temp }}",
         "env" => %{
           "WANT_ELIXIR" => @runtime_inputs["elixir"],
           "WANT_OTP" => @runtime_inputs["otp"]
         }
       }}
    ]

    hex_inputs = Map.put(@hex_identity, "release-commit", @release_commit)

    upload_inputs =
      Map.merge(hex_inputs, %{
        "operation" => "upload",
        "organization-read-key" => "${{ secrets.HEX_ORG_KEY_PUBLISH_API_READ }}"
      })

    read_back_inputs =
      Map.merge(hex_inputs, %{
        "operation" => "read-back",
        "qualification-run" => "${{ needs.upload.outputs.qualification-run }}",
        "qualification-sha256" => "${{ needs.upload.outputs.qualification-sha256 }}",
        "release-assets-directory" => "${{ runner.temp }}/release-assets"
      })

    read_permissions = %{"contents" => "read", "actions" => "read"}

    common_job = %{
      "if" => @publish_owner_condition,
      "runs-on" => "ubuntu-24.04",
      "timeout-minutes" => 90
    }

    upload =
      Map.merge(common_job, %{
        "environment" => "publish",
        "permissions" => Map.put(read_permissions, "id-token", "write"),
        "outputs" => %{
          "qualification-run" => "${{ steps.hex.outputs.qualification-run }}",
          "qualification-sha256" => "${{ steps.hex.outputs.qualification-sha256 }}"
        },
        "steps" =>
          common_steps ++
            [
              {:uses, @hex_action, upload_inputs, %{"id" => "hex"}},
              {:run,
               ~s(rm -f "$RUNNER_TEMP/hex-release-toolchain.sh" "$RUNNER_TEMP/hex-release-tool-versions"),
               %{"if" => "always()"}}
            ]
      })

    read_back =
      Map.merge(common_job, %{
        "needs" => "upload",
        "permissions" => read_permissions,
        "outputs" => %{"commit" => "${{ steps.hex.outputs.commit }}"},
        "steps" =>
          common_steps ++
            [
              {:uses, @hex_action, read_back_inputs, %{"id" => "hex"}},
              {:uses, @upload_artifact,
               %{
                 "name" => "release-assets",
                 "path" => "${{ runner.temp }}/release-assets/",
                 "if-no-files-found" => "error",
                 "compression-level" => 0,
                 "retention-days" => 7
               }},
              {:run,
               ~s(rm -rf "$RUNNER_TEMP/hex-release-toolchain.sh" "$RUNNER_TEMP/hex-release-tool-versions" "$RUNNER_TEMP/release-assets"),
               %{"if" => "always()"}}
            ]
      })

    jobs =
      Map.new(workflow["jobs"], fn {id, job} ->
        steps = Enum.map(Map.get(job, "steps", []), &step_signature/1)
        {id, Map.put(job, "steps", steps)}
      end)

    assert(
      jobs == %{"upload" => upload, "read-back" => read_back},
      "publish job contract is invalid"
    )

    assert(
      Map.delete(workflow, "jobs") == %{
        "name" => "Publish to Hex",
        "defaults" => %{"run" => %{"shell" => "bash"}},
        "permissions" => %{"contents" => "read"},
        "concurrency" => %{"group" => "publish", "cancel-in-progress" => false},
        "on" => %{
          "workflow_dispatch" => %{
            "inputs" => %{
              "release_commit" => %{
                "description" => "Full SHA of the landed release commit",
                "required" => true,
                "type" => "string"
              }
            }
          }
        }
      },
      "publish must dispatch on one full release commit"
    )
  end

  defp assert_hex_declaration(root) do
    declaration =
      root |> Path.join(".github/hex-packages.json") |> File.read!() |> Jason.decode!()

    requirements =
      Map.new(public_requirements(root), fn {app, requirement} ->
        name = Atom.to_string(app)

        {name,
         %{
           "app" => name,
           "optional" => app == :igniter,
           "requirement" => requirement,
           "repository" => "hexpm"
         }}
      end)

    assert(
      match?(
        %{
          "ash_replicant" => %{
            "app" => "ash_replicant",
            "directory" => ".",
            "files" => [_ | _],
            "requirements" => ^requirements
          }
        },
        declaration
      ) and
        "docs/adr/0027-postgresql-server-support.md" in declaration["ash_replicant"]["files"] and
        File.regular?(Path.join(root, "docs/adr/0027-postgresql-server-support.md")),
      "Hex package declaration must match the public Mix dependencies and include the server support ADR"
    )
  end

  defp assert_workflow_runners(root) do
    root
    |> Path.join(".github/workflows/*.{yml,yaml}")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      workflow = YamlElixir.read_from_file!(path)
      assert_actions(workflow)
      controls = if Path.basename(path) == "drift-report.yml", do: %{"id" => "runtime"}, else: %{}
      if Path.basename(path) != "publish.yml", do: assert_runtime(workflow, root, controls)
      source = File.read!(path)

      assert(
        (Path.basename(path) == "publish.yml" or
           not String.contains?(source, ["elixir-version:", "otp-version:", ".tool-versions"])) and
          not String.contains?(source, "version-file:") and
          not Regex.match?(~r/\b(?:elixir|erlang|otp)[_-]?(?:version)?\s*:\s*["']?[0-9]/i, source),
        "workflow runtime versions must come only from the shared reader outputs"
      )

      assert_workflow_controls(workflow, Path.basename(path) == "drift-report.yml")

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

    if {Path.basename(path), name} in [
         {"publish.yml", "upload"},
         {"publish.yml", "read-back"},
         {"qualification.yml", "postgres-lanes"},
         {"qualification.yml", "release-artifact"},
         {"qualification.yml", "fresh-consumer"},
         {"quick.yml", "quick"}
       ] do
      assert(
        timeout == 90 and
          String.contains?(block, "    timeout-minutes: 90 # no green run yet\n"),
        "unmeasured job timeout must be 90 # no green run yet"
      )
    else
      assert_measured_timeout(block, timeout)
    end
  end

  defp assert_measured_timeout(block, timeout) do
    case Regex.run(~r/# Green run ([0-9]+):[^\n]*?([0-9]+)m([0-9]+)s/, block) do
      [_comment, run, minutes, seconds] ->
        measured = String.to_integer(minutes) * 60 + String.to_integer(seconds)
        expected = if measured < 150, do: 5, else: div(2 * measured + 59, 60)

        assert(
          run in ~w(44208487858 44214414813 44224060553 44227674373 44554148819 44572306314 44736595182 44738538737 44765244702 44884720928 45895179176) and
            measured > 0 and measured <= 2700 and is_integer(timeout) and timeout <= 90 and
            timeout == expected,
          "CI timeout must follow its slowest measured green run and infra's 5-minute floor"
        )

      _missing ->
        fail("CI timeout needs its measured green run and duration comment")
    end
  end

  defp assert_ci_sources(root) do
    shell_scripts = Path.wildcard(Path.join(root, "scripts/**/*.sh"))
    assert(shell_scripts != [], "CI shell script inventory is missing")

    Enum.each(shell_scripts, fn path ->
      source = File.read!(path)

      assert(
        String.starts_with?(source, "#!/usr/bin/env bash\n") and
          String.contains?(source, "\nset -euo pipefail\n"),
        "CI shell scripts must use bash with errexit, nounset and pipefail"
      )
    end)

    Enum.each(@command_status_guards, fn {path, expected} ->
      assert(
        String.contains?(File.read!(Path.join(root, path)), expected),
        "CI command status must reach its check"
      )
    end)

    for {path, expected} <- [
          {"scripts/audit-fixtures.sh", @fixture_audit_script},
          {"test/fixtures/upgrade_0_4_app/mix.exs", @upgrade_fixture_project}
        ] do
      assert(
        File.read!(Path.join(root, path)) == expected,
        "CI safety script contract is invalid"
      )
    end

    verdict = File.read!(Path.join(root, "scripts/qualify.py"))

    assert(
      String.contains?(verdict, @qualification_lookup) and
        String.contains?(verdict, ~s|if not os.environ.get("GH_TOKEN"):|),
      "qualification must use the job token for its GitHub lookup"
    )

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

  defp postgres_declarations(root) do
    root = Path.expand(root)

    reader = Path.join(root, "scripts/ci/postgres-lanes.sh")
    {output, status} = System.cmd(reader, ["--json", root], stderr_to_stdout: true)

    assert(status == 0, "PostgreSQL lane reader refused its declarations")
    Jason.decode!(output)
  end

  defp assert_postgres(root) do
    assert(
      not File.exists?(Path.join(root, ".github/dependency-lanes.json")),
      "CI dependency lanes must derive from Mix declarations"
    )

    declarations = postgres_declarations(root)

    assert(
      declarations["compatibility"]
      |> Enum.take(3)
      |> Enum.map(&Map.drop(&1, ["pg_major", "pg_image"])) ==
        DependencyLanes.lanes(public_requirements(root)),
      "CI dependency matrix is invalid"
    )

    action = YamlElixir.read_from_file!(Path.join(root, ".github/actions/postgres/action.yml"))
    [check, manage] = get_in(action, ["runs", "steps"])

    assert(
      get_in(action, ["runs", "using"]) == "composite",
      "PostgreSQL action must be composite"
    )

    assert(
      check["name"] == "Check the public platform engine and pull its digest" and
        check["if"] == "inputs.mode == 'start' && inputs.image == ''" and
        check["shell"] == "bash" and check["run"] == @public_engine_check,
      "public PostgreSQL digest check is invalid"
    )

    assert(
      manage["if"] == "always() && (inputs.mode == 'stop' || success())" and
        manage["shell"] == "bash" and manage["run"] == @postgres_manage,
      "PostgreSQL startup, readiness or cleanup is invalid"
    )

    assert(
      manage["env"] == %{
        "MODE" => "${{ inputs.mode }}",
        "CONTAINER" => "${{ inputs.name }}",
        "PORT" => "${{ inputs.port }}",
        "IMAGE" => "${{ inputs.image }}",
        "DECODER_SOURCE" => "${{ inputs.decoder-source }}",
        "TEST_PG_USER" => "postgres",
        "TEST_PG_PASSWORD" => "postgres",
        "TEST_PG_DATABASE" => "ash_replicant_test",
        "POSTGRES_USER" => "postgres",
        "POSTGRES_PASSWORD" => "postgres",
        "POSTGRES_DB" => "ash_replicant_test"
      },
      "PostgreSQL fixture environment is invalid"
    )

    dockerfile = File.read!(Path.join(root, "test/support/pglogical.dockerfile"))

    assert(
      Regex.match?(~r/^ARG BASE$/m, dockerfile) and
        not Regex.match?(~r/ARG BASE=|@sha256:/, dockerfile) and
        String.contains?(dockerfile, ~s("postgresql-server-dev-$PG_MAJOR=$PG_VERSION")) and
        String.contains?(dockerfile, "https://apt-archive.postgresql.org") and
        String.contains?(
          dockerfile,
          ~s|*) echo "unsupported plugin source major" >&2; exit 1|
        ) and
        String.contains?(dockerfile, "libnuma-dev") and
        length(:binary.matches(dockerfile, ~S(LDFLAGS_EX="-L/usr/lib/postgresql/$PG_MAJOR/lib"))) ==
          2 and
        String.contains?(dockerfile, "COPY --from=build /plugins/ /"),
      "plugin builds must use declared bases, exact archived headers and staged plugin files"
    )

    for row <- declarations["decoder"] do
      assert(
        Regex.match?(
          ~r/(?:\s|\|)#{Regex.escape(row["pg_major"])}(?:\||\))/,
          dockerfile
        ),
        "plugin source major must have an explicit build branch"
      )
    end

    for [_, commit] <- Regex.scan(~r/git checkout --quiet ([^;\s]+)/, dockerfile) do
      assert(Regex.match?(~r/\A[0-9a-f]{40}\z/, commit), "plugin source commit must be immutable")
    end

    for path <- Path.wildcard(Path.join(root, ".github/workflows/*.yml")) do
      source = File.read!(path)

      assert(
        not Regex.match?(
          ~r/postgres:[0-9]|ghcr\.io\/baselabs\/postgres|PostgreSQL [0-9]|pg_major:\s*["']?[0-9]|docker (run|rm)/,
          source
        ),
        "workflows must use PostgreSQL declarations and the composite action"
      )
    end
  end

  defp assert_qualification_inventory(root, workflow) do
    declarations = postgres_declarations(root)

    expected =
      workflow
      |> Map.fetch!("jobs")
      |> Enum.flat_map(fn {_id, job} ->
        rows =
          case get_in(job, ["strategy", "matrix", "include"]) do
            "${{ fromJSON(needs.postgres-lanes.outputs.compatibility) }}" ->
              declarations["compatibility"]

            "${{ fromJSON(needs.postgres-lanes.outputs.decoder) }}" ->
              declarations["decoder"]

            nil ->
              [%{}]

            _other ->
              fail("qualification matrix must come from the lane reader")
          end

        Enum.map(rows, &qualification_check_name(job["name"], &1))
      end)
      |> Enum.sort()

    inventory = declarations["checks"]

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

  # Every installation consumes reader outputs and refuses an installed mismatch.
  defp assert_runtime(workflow, root, controls \\ %{}) do
    assert_toolchain_actions(root)
    pinned_runtime(root)
    assert(not Map.has_key?(workflow, "env"), "CI runtime must come only from the reader")

    for {_name, job} <- Map.get(workflow, "jobs", %{}),
        {step, index} <- Enum.with_index(Map.get(job, "steps", [])) do
      assert(
        not String.starts_with?(Map.get(step, "uses", ""), "erlef/setup-beam@"),
        "runtime installation must use the shared BEAM action"
      )

      if step["uses"] == @beam_action do
        assert(
          step == Map.merge(%{"uses" => @beam_action, "with" => @runtime_inputs}, controls),
          "runtime inputs must be unmodified reader outputs"
        )

        assert(
          index > 0 and
            Enum.at(job["steps"], index - 1) ==
              %{"uses" => @toolchain_action, "id" => "toolchain"},
          "runtime installation must follow the unconditional shared reader"
        )
      end
    end
  end

  defp assert_toolchain_actions(root) do
    path = Path.join(root, "scripts/toolchain.sh")
    digest = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    assert(
      digest == @toolchain_sha256 and Bitwise.band(File.stat!(path).mode, 0o7777) == 0o755,
      "shared toolchain reader bytes or mode differ from the pin"
    )

    toolchain =
      YamlElixir.read_from_file!(Path.join(root, ".github/actions/toolchain/action.yml"))

    beam = YamlElixir.read_from_file!(Path.join(root, ".github/actions/beam/action.yml"))

    outputs = %{
      "elixir" => %{
        "description" => "Exact Elixir version and OTP build suffix.",
        "value" => "${{ steps.versions.outputs.elixir }}"
      },
      "otp" => %{
        "description" => "Exact OTP version.",
        "value" => "${{ steps.versions.outputs.otp }}"
      }
    }

    reader_runs = %{
      "using" => "composite",
      "steps" => [
        %{
          "name" => "Test the shared toolchain reader",
          "shell" => "bash",
          "run" => "scripts/toolchain.sh --self-test"
        },
        %{
          "name" => "Read the checkout runtime",
          "id" => "versions",
          "shell" => "bash",
          "run" => ~s(scripts/toolchain.sh >> "$GITHUB_OUTPUT")
        }
      ]
    }

    assert(
      not Map.has_key?(toolchain, "inputs") and toolchain["outputs"] == outputs and
        toolchain["runs"] == reader_runs,
      "toolchain action must test and call the reader by path and expose its outputs"
    )

    inputs = %{
      "elixir" => %{
        "description" => "Exact Elixir version and OTP build suffix from the reader.",
        "required" => true
      },
      "otp" => %{"description" => "Exact OTP version from the reader.", "required" => true}
    }

    beam_runs = %{
      "using" => "composite",
      "steps" => [
        %{
          "uses" => @setup_beam,
          "with" => %{
            "elixir-version" => "${{ inputs.elixir }}",
            "otp-version" => "${{ inputs.otp }}",
            "version-type" => "strict",
            "install-hex" => false
          }
        },
        %{
          "name" => "Refuse a runtime other than the reader names",
          "shell" => "bash",
          "env" => %{"WANT_ELIXIR" => "${{ inputs.elixir }}", "WANT_OTP" => "${{ inputs.otp }}"},
          "run" =>
            ~s("$GITHUB_WORKSPACE/scripts/toolchain.sh" --installed "elixir=$WANT_ELIXIR" "erlang=$WANT_OTP")
        },
        %{
          "name" => "Install and verify the pinned Hex client",
          "shell" => "bash",
          "working-directory" => "${{ runner.temp }}",
          "run" => @install_hex
        }
      ]
    }

    assert(
      beam["inputs"] == inputs and beam["runs"] == beam_runs,
      "BEAM action must install strictly, immediately check the runtime and verify pinned Hex"
    )
  end

  defp pinned_runtime(root) do
    {output, status} =
      System.cmd(
        Path.join(Path.expand(root), "scripts/toolchain.sh"),
        [Path.join(Path.expand(root), ".tool-versions")],
        stderr_to_stdout: true
      )

    assert(status == 0, "shared toolchain reader refused its declarations")

    pins =
      output
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [name, version] = String.split(line, "=", parts: 2)
        {name, version}
      end)

    elixir = Map.get(pins, "elixir", "")
    otp = Map.get(pins, "otp", "")
    assert(Regex.match?(~r/\A\d+\.\d+\.\d+-otp-\d+\z/, elixir), "Elixir pin must be exact")
    assert(Regex.match?(~r/\A\d+(\.\d+)+\z/, otp), "OTP pin must be exact")
    {elixir |> String.split("-otp-") |> hd(), otp}
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

  defp assert_workflow_controls(workflow, drift_report?) do
    triggers = workflow["on"]
    events = if is_map(triggers), do: Map.keys(triggers), else: List.wrap(triggers)

    assert(
      Enum.all?(events, &(&1 not in ["pull_request", "pull_request_target"])),
      "CI must not run repository code from a pull request"
    )

    for {_name, job} <- Map.get(workflow, "jobs", %{}), step <- Map.get(job, "steps", []) do
      run = Map.get(step, "run", "")

      assert(
        is_binary(run) and not String.contains?(run, "${{"),
        "workflow expressions must enter run scripts through step env"
      )

      unless drift_report? do
        fetches = Regex.scan(~r/\bmix\s+deps\.get\b([^\n;&|]*)/, run)

        assert(
          not Regex.match?(~r/\bmix\s+deps\.(?:unlock|update)\b/, run) and
            Enum.all?(fetches, fn [_command, args] ->
              String.contains?(args, "--check-locked")
            end),
          "upstream resolution belongs only in a drift report, never qualification or publication"
        )
      end
    end

    assert(
      workflow["defaults"] == %{"run" => %{"shell" => "bash"}},
      "every workflow must default to bash with pipefail"
    )

    Enum.each(Map.get(workflow, "jobs", %{}), fn {_name, job} ->
      assert(not Map.has_key?(job, "defaults"), "CI jobs must inherit the workflow shell")

      Enum.each(Map.get(job, "steps", []), fn step ->
        assert(Map.get(step, "shell", "bash") == "bash", "CI steps must use bash with pipefail")
      end)
    end)

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

      if name in [
           "no-database",
           "compatibility",
           "performance",
           "decoder-sources"
         ] do
        assert(job["needs"] == "postgres-lanes", "database lanes must use the declaration job")
      end

      if name == "fresh-consumer" do
        assert(
          job["needs"] == ["postgres-lanes", "release-artifact"],
          "fresh consumer needs the qualified Hex archive"
        )
      end

      if name == "postgres-lanes" do
        assert(
          job["outputs"] == %{
            "engine_major" => "${{ steps.lanes.outputs.engine_major }}",
            "compatibility" => "${{ steps.lanes.outputs.compatibility }}",
            "decoder" => "${{ steps.lanes.outputs.decoder }}",
            "checks" => "${{ steps.lanes.outputs.checks }}"
          },
          "PostgreSQL lane outputs are invalid"
        )
      end

      if name in ["no-database", "fresh-consumer"] do
        assert(
          job["permissions"] == %{"contents" => "read"},
          "qualification job must keep read-only contents"
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
      Map.keys(step) -- ["name", "run", "id", "if", "env", "working-directory", "shell"] == [],
      "CI release run step control is invalid"
    )

    # Include step controls in the signature so a command cannot be bypassed
    # or given a broader environment.
    case Map.take(step, ["id", "if", "env", "working-directory", "shell"]) do
      controls when map_size(controls) == 0 -> {:run, String.trim(run)}
      controls -> {:run, String.trim(run), controls}
    end
  end

  defp step_signature(%{"uses" => action} = step) when is_binary(action) do
    assert(
      Map.keys(step) -- ["name", "uses", "with", "id", "if"] == [],
      "CI release Action step control is invalid"
    )

    signature = {:uses, action, Map.get(step, "with", :absent)}

    case Map.take(step, ["id", "if"]) do
      controls when map_size(controls) == 0 -> signature
      controls -> Tuple.insert_at(signature, tuple_size(signature), controls)
    end
  end

  defp step_signature(_step), do: fail("CI release step is invalid")

  defp assert_compatibility(workflow) do
    job = get_in(workflow, ["jobs", "compatibility"]) || fail("CI compatibility job is missing")

    assert(
      job["strategy"] == %{
        "fail-fast" => false,
        "matrix" => %{"include" => "${{ fromJSON(needs.postgres-lanes.outputs.compatibility) }}"}
      },
      "CI Ash compatibility matrix is invalid"
    )
  end

  defp assert_mix_contract(root) do
    source = root |> Path.join("mix.exs") |> File.read!()
    body = source |> Code.string_to_quoted!() |> mix_project_body()
    projects = find_definitions(body, :def, :project)
    dependency_lists = find_definitions(body, :defp, :deps)
    public_requirements(root)
    docs = find_definitions(body, :defp, :docs)
    [dependencies] = dependency_lists
    scoped_source_ref = ~S|source_ref: "baselabs_ash_replicant-v#{@version}"|

    assert(
      match?([[main: _, formatters: ["html", "markdown"], source_ref: _, extras: _]], docs) and
        String.contains?(source, scoped_source_ref) and
        Enum.any?(dependencies, fn dependency ->
          match?(
            {:{}, _, [:ex_doc, "== 0.40.4", [only: :dev, runtime: false]]},
            dependency
          )
        end),
      "docs must pin ExDoc 0.40.4 and ship HTML and Markdown only"
    )

    assert(
      exact_project_contract?(projects) and
        Enum.any?(dependencies, fn dependency ->
          match?(
            {:{}, _, [:igniter, {:@, _, [{:igniter_requirement, _, _}]}, [optional: true]]},
            dependency
          )
        end) and
        Enum.any?(dependencies, fn dependency ->
          match?({:db_connection, {:@, _, [{:db_connection_requirement, _, _}]}}, dependency)
        end),
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
      match?(
        {:|>, _, [{:deps, _, []}, {:select_requirements, _, []}]},
        Keyword.get(project, :deps)
      )
  end

  defp exact_project_contract?(_projects), do: false

  defp public_requirements(root) do
    DependencyRequirements.read!(Path.join(root, "mix.exs"))
  rescue
    ArgumentError -> fail("Mix release contract is invalid")
  end

  defp assert_replicant_contract(root) do
    lock = root |> Path.join("mix.lock") |> File.read!()
    requirements = public_requirements(root)

    assert_hex_lock(
      lock,
      "replicant",
      expected_replicant_lock_version(lock, requirements.replicant)
    )

    assert(
      Version.match?(hex_lock_version(lock, "postgrex"), requirements.postgrex),
      "Postgrex dependency lock contract is incomplete"
    )

    assert(
      Version.match?(hex_lock_version(lock, "db_connection"), requirements.db_connection),
      "DBConnection dependency lock contract is incomplete"
    )

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

  defp expected_replicant_lock_version(lock, requirement) do
    case System.get_env("ASH_REPLICANT_REPLICANT_VERSION") do
      value when value in [nil, ""] ->
        lock |> hex_lock_version("replicant") |> validate_replicant_lock_version!(requirement)

      "latest" ->
        lock
        |> hex_lock_version("replicant")
        |> validate_replicant_lock_version!(requirement)

      value ->
        validate_replicant_lock_version!(value, requirement)
    end
  end

  defp validate_replicant_lock_version!(value, requirement) do
    with true <- is_binary(value),
         {:ok, _version} <- Version.parse(value),
         true <- Version.match?(value, requirement) do
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

  defp block_expressions({:__block__, _, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp assert_docs(root) do
    paths = ~w(AGENTS.md CONTRIBUTING.md docs/adr/0002-supported-runtime-and-dependencies.md)

    for path <- paths do
      source = File.read!(Path.join(root, path))

      assert(
        not String.contains?(source, "kci/lock-bootstrap-ash") and
          not String.contains?(source, "uses `mix deps.unlock --all`"),
        "docs must not prescribe an upstream-resolution qualification workflow"
      )
    end

    Enum.each(doc_contracts(root), fn {path, heading, required_texts} ->
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
          ~r/(?:unsupported release foundation|does(?:[\s\p{Cf}]+not|n't)[\s\p{Cf}]+support[\s\p{Cf}]*(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.33\.4|Replicant 2(?:\.x|\.\d+(?:\.\d+)?))|(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.33\.4|Replicant 2(?:\.x|\.\d+(?:\.\d+)?))[\s\p{Cf}]*(?:is[\s\p{Cf}]+)?not[\s\p{Cf}]+supported)/iu,
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

  defp section(content, nil), do: content

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
