implementation =
  System.get_env("ASH_REPLICANT_RELEASE_CONTRACT_IMPLEMENTATION") ||
    Path.join(__DIR__, "assert_release_contract.exs")

Code.require_file(implementation)

defmodule AshReplicant.ReleaseContractSelfTest do
  alias AshReplicant.DependencyLanes
  alias AshReplicant.DependencyRequirements
  alias AshReplicant.ReleaseContract
  alias AshReplicant.ReleaseContractError

  @source_root System.get_env("ASH_REPLICANT_RELEASE_CONTRACT_SOURCE_ROOT") || File.cwd!()
  @fixture_root Path.join(
                  System.tmp_dir!(),
                  "ash-replicant-release-contract-#{System.pid()}-#{System.unique_integer([:positive])}"
                )
  @requirements DependencyRequirements.read!(Path.join(@source_root, "mix.exs"))
  @workflow ".github/workflows/qualification.yml"
  @landing ".github/workflows/ci.yml"
  @drift ".github/workflows/drift-report.yml"
  @pull_request ".github/workflows/pull-request.yml"
  @publish ".github/workflows/publish.yml"
  @inventory "scripts/qualification-jobs.json"
  @fail_late "${{ !cancelled() && steps.compile.outcome == 'success' }}"
  @report_if "${{ !cancelled() && steps.runtime.outcome == 'success' }}"
  @publish_owner_condition "contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.actor) && contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.triggering_actor)"

  @create_database """
  mix ecto.create
  mix ecto.migrate
  """

  # Mirrors assert_release_contract.exs's @mutation_gates_run byte-for-byte;
  # qualification.yml and both contract scripts move together.
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

  expected = AshReplicant.DependencyRequirements.read!("mix.exs")

  public_deps = Enum.reject(deps, fn dependency ->
    options = if tuple_size(dependency) == 3, do: elem(dependency, 2), else: []
    Keyword.has_key?(options, :only)
  end)

  unless Enum.sort(Enum.map(public_deps, &elem(&1, 0))) == Enum.sort(Map.keys(expected)),
    do: raise("unexpected public dependency set")

  Enum.each(expected, fn {dependency, requirement} ->
    actual = deps |> List.keyfind!(dependency, 0) |> elem(1)
    unless actual == requirement, do: raise("unexpected public dependency requirement")
  end)
  '
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
    {"scripts/assert-release-tree.sh",
     ~S"""
       tree_status="$(git status --porcelain --untracked-files=all)" || release_tree_fail 'git status failed'
       [[ -z "$tree_status" ]] || release_tree_fail 'dirty tree'
     """},
    {"scripts/inspect-release-package.sh",
     ~S"""
     package_files="$(cd "$work/package" && find . \( -type f -o -type l \) | sed 's|^./||' | LC_ALL=C sort)"
     if ! diff -u "$root/scripts/release-package-files.txt" - <<<"$package_files"; then
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
     """},
    {"scripts/test-release-package-inspection.sh",
     ~S"""
     grep -qF "$selector_free_build" <<<"$inspection" || {
     """},
    {"scripts/test-release-package-inspection.sh",
     ~S"""
       build_status=0
       grep -q 'mix hex.build' <<<"$staged" || build_status=$?
       if [[ "$build_status" -ne 1 ]]; then
     """},
    {"scripts/test-release-package-inspection.sh",
     ~S"""
       inspection_script="$(rebind_staging)" || return
       ASH_REPLICANT_PACKAGE_FIXTURE="$1" bash -euo pipefail -c "$inspection_script"
     """},
    {"scripts/test-release-package-inspection.sh",
     ~S"""
       staged="$(printf '%s\n' "$inspection" \
         | sed -e 's|^package_dir=\$(mktemp -d)$|package_dir="$ASH_REPLICANT_PACKAGE_FIXTURE"|' \
               -e "s|^${selector_free_build}\$|: # self-test staged fixture|")" || return
     """}
  ]

  @package_inspection ~S"""
  package_dir=$(mktemp -d)
  trap 'rm -rf "$package_dir"' EXIT
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix hex.build --unpack --output "$package_dir"

  for required in lib .formatter.exs mix.exs README.md LICENSE NOTICE CHANGELOG.md usage-rules.md \
    lib/ash_replicant/upgrade.ex lib/ash_replicant/upgrade/checkpoint.ex \
    lib/mix/tasks/ash_replicant.upgrade.ex; do
    test -e "$package_dir/$required" || {
      echo "::error::Missing package path: $required"
      exit 1
    }
  done

  residue="$(find "$package_dir" -type d \( -name test -o -name _build -o -name '.*' ! -name . \) -print -quit)"
  if [[ -n "$residue" ]]; then
    echo "::error::Package contains test, build, or dot-directory residue"
    exit 1
  fi

  if test -e "$package_dir/priv"; then
    echo "::error::Package contains private migrations"
    exit 1
  fi

  credentials="$(find "$package_dir" -type f \( -name '.env*' -o -name '*.pem' -o -name '*.key' \) -print -quit)"
  if [[ -n "$credentials" ]]; then
    echo "::error::Package contains a credential-shaped file"
    exit 1
  fi

  package_files="$(cd "$package_dir" && find . \( -type f -o -type l \) | sed 's|^./||' | LC_ALL=C sort)"
  if ! diff -u scripts/release-package-files.txt - <<<"$package_files"; then
    echo "::error::Package files differ from the release allowlist"
    exit 1
  fi
  """

  @upload_archive_checks ~S"""
  trap 'rm -rf "$RUNNER_TEMP/package.tar" "$RUNNER_TEMP/hex-docs.tar.gz" "$RUNNER_TEMP/hex-docs.tar.gz.rendered"' EXIT
  version="$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)"
  python3 -I scripts/check-docs-archive.py "$RUNNER_TEMP/hex-docs.tar.gz" "$RUNNER_TEMP/hex-docs.tar.gz.rendered" --version "$version" --commit "$GITHUB_SHA"
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION scripts/with-release-runtime.sh mix hex.build --output "$RUNNER_TEMP/package.tar"
  scripts/inspect-release-package.sh "$RUNNER_TEMP/package.tar"
  python3 -B scripts/test_release_docs.py "$RUNNER_TEMP/hex-docs.tar.gz" "$RUNNER_TEMP/hex-docs.tar.gz.rendered" "$RUNNER_TEMP/package.tar"
  cd "$RUNNER_TEMP"
  mix run --no-mix-exs "$GITHUB_WORKSPACE/scripts/test_publish_hex_artifacts.exs"
  """

  @job_commands %{
    "postgres-lanes" => [
      "scripts/ci/postgres-lanes.sh",
      "python3 -B -m unittest discover -s scripts -p 'test_postgres_lanes.py'"
    ],
    "no-database" => [
      "mix deps.get --check-locked",
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      "mix format --check-formatted",
      "elixir --version",
      "scripts/test-prepush.sh",
      "scripts/test-release-checkers.sh",
      "scripts/test-release-guards.sh",
      "scripts/test-release-contract.sh",
      "python3 -B -m unittest discover -s scripts -p 'test_qualify.py'",
      "mix credo --strict",
      "mix deps.audit",
      "scripts/audit-fixtures.sh",
      "env -u ASH_REPLICANT_TEST_URL scripts/run-structural-tests.sh --allow-excluded --exclude integration",
      String.trim(@mutation_gates_run)
    ],
    "compatibility" => [
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      "elixir --version",
      "scripts/test-release-checkers.sh",
      "scripts/assert-release-contract.sh",
      "mix deps.audit",
      String.trim(@create_database),
      "scripts/test-migration-drift-gate.sh",
      "scripts/run-structural-tests.sh --include integration",
      "scripts/run-structural-tests.sh test/integration --include integration",
      "mix dialyzer"
    ],
    "performance" => [
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      String.trim(@create_database),
      "scripts/run-structural-tests.sh test/integration/performance_bounds_test.exs --include integration"
    ],
    "fresh-consumer" => [
      "mix deps.get --check-locked",
      "mix deps.compile",
      "scripts/test-fresh-consumer.sh"
    ],
    "release-artifact" => [
      "env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix deps.get --check-locked",
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      "elixir --version",
      "scripts/assert-release-contract.sh",
      String.trim(@public_dependency_check),
      ~s(scripts/build-release-docs.sh "$RUNNER_TEMP/hex-docs.tar.gz"),
      String.trim(@upload_archive_checks),
      String.trim(@package_inspection)
    ]
  }

  @doc_contracts [
    {"README.md", "### Supported foundation",
     [
       "- Elixir 1.20.3 on Erlang/OTP 29;",
       "- Ash `#{@requirements.ash}` (current lock 3.38.1);",
       "- AshPostgres `#{@requirements.ash_postgres}` (current lock 2.15.2 with AshSql 0.8.8; qualification tests the reviewed compatibility lock);",
       "- Spark `#{@requirements.spark}` (effective floor 2.7.6 through Ash; current lock 2.7.9);",
       "- Replicant `#{@requirements.replicant}` (current lock 1.6.0)",
       "- Postgrex `#{@requirements.postgrex}` (current lock 0.23.0);",
       "- AshOnetime `#{@requirements.ash_onetime}` (current lock 1.5.0)",
       "- AshCloak `#{@requirements.ash_cloak}` (current lock 0.4.0"
     ]},
    {"CONTRIBUTING.md", "## Prerequisites",
     [
       "- **Elixir 1.20.3** and **Erlang/OTP 29**",
       "- Ash `#{@requirements.ash}`; selector-free development uses this public range",
       "- Replicant `#{@requirements.replicant}` from Hex; the lock is 1.6.0.",
       "- Postgrex `#{@requirements.postgrex}` from Hex; the lock is 0.23.0.",
       "- AshCloak `#{@requirements.ash_cloak}` from Hex; the current lock is 0.4.0 (the"
     ]},
    {"AGENTS.md", "## Development workflow",
     [
       "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
         "`#{@requirements.ash}` (current lock 3.38.1) and Replicant\n" <>
         "`#{@requirements.replicant}` (current lock 1.6.0), plus\n" <>
         "AshOnetime `#{@requirements.ash_onetime}` (current lock 1.5.0) and AshCloak\n" <>
         "`#{@requirements.ash_cloak}` (current lock 0.4.0; releases below 0.4.0 carry\n" <>
         "CVE-2026-81319 and CVE-2026-81322 and are not admitted).",
       "Postgrex requires `#{@requirements.postgrex}` (current lock 0.23.0)"
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
    # CHANGELOG is matched whole-file (heading nil): an [Unreleased] block
    # legitimately carries its own `### Added` ahead of the released
    # section that owns this entry.
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

  @checkout "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
  @setup_beam "erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124"
  @beam ".github/actions/beam/action.yml"
  @toolchain ".github/actions/toolchain/action.yml"
  @named_separator_entities ~w(
    af ApplyFunction emsp13 emsp14 emsp ensp hairsp ic InvisibleComma
    InvisibleTimes it lrm MediumSpace nbsp NegativeMediumSpace NegativeThickSpace
    NegativeThinSpace NegativeVeryThinSpace NewLine NoBreak NonBreakingSpace numsp
    puncsp rlm shy Tab ThickSpace thinsp ThinSpace VeryThinSpace ZeroWidthSpace zwj zwnj
  )

  defp mix_contracts do
    Enum.map(@requirements, fn {name, requirement} ->
      "@#{name}_requirement #{inspect(requirement)}"
    end) ++
      [
        ~s(elixir: "~> 1.20.3"),
        ~s(formatters: ["html", "markdown"]),
        ~s({:ex_doc, "== 0.40.4", only: :dev, runtime: false})
      ]
  end

  def run do
    Process.put({__MODULE__, :checks}, 0)

    with_env("ASH_REPLICANT_REPLICANT_VERSION", nil, fn ->
      valid_fixture_probes()
      action_probes()
      action_input_probes()
      landing_and_fail_late_probes()
      qualification_probes()
      fresh_consumer_probes()
      drift_report_probes()
      publish_probes()
      command_status_probes()
      ci_requirement_probes()
      github_lookup_probes()
      postgres_probes()
      decoder_job_probes()
      command_probes()
      compatibility_probes()
      packaging_selector_probes()
      public_dependency_probes()
      workflow_structure_probes()
      checker_wiring_probes()
      mix_contract_probes()
      replicant_selector_probes()
      documentation_probes()
      b1_documentation_probes()
      census_contract_probes()
      upgrade_contract_probes()
    end)

    IO.puts("release contract self-tests: PASS (#{Process.get({__MODULE__, :checks})} checks)")
  after
    File.rm_rf!(@fixture_root)
  end

  defp checker_wiring_probes do
    prepare_fixture()

    replace_once!(
      "scripts/test-release-checkers.sh",
      "scripts/test-ash-onetime-migration-checker.sh >/dev/null",
      "true"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "scripts/test-release-checkers.sh",
      "scripts/test-release-package-inspection.sh >/dev/null",
      "true"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "scripts/test-release-checkers.sh",
      "python3 -B -m unittest discover -s scripts -p 'test_postgres_lanes.py' >/dev/null",
      "true"
    )

    assert_invalid!()
  end

  defp replicant_selector_probes do
    # Accept the declared floor, then reject stale locks and older selectors.
    floor = DependencyLanes.floor!(@requirements.replicant)
    prepare_fixture()
    with_env("ASH_REPLICANT_REPLICANT_VERSION", floor, &assert_valid!/0)

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.6.0"),
      ~s("replicant": {:hex, :replicant, "1.5.1")
    )

    with_env("ASH_REPLICANT_REPLICANT_VERSION", floor, &assert_invalid!/0)

    prepare_fixture()
    with_env("ASH_REPLICANT_REPLICANT_VERSION", "1.5.1", &assert_invalid!/0)

    prepare_fixture()
    with_env("ASH_REPLICANT_REPLICANT_VERSION", "latest", &assert_valid!/0)
  end

  defp valid_fixture_probes do
    prepare_fixture()
    replace_once!(@workflow, "uses: #{@checkout}", "uses: \"#{@checkout}\"")
    assert_valid!()

    prepare_fixture()

    replace_once!(
      @workflow,
      "name: Qualification",
      "name: Qualification\n# Example text: uses: actions/setup-node@v4"
    )

    assert_valid!()

    # A ninth, non-allowlisted apply_ledger occurrence anywhere in lib/ fails
    # the B5 absence scan (the gate's red direction).
    prepare_fixture()
    rogue = fixture_path(Path.join(["lib", "ash_replicant", "rogue.ex"]))
    File.write!(rogue, "# apply_ledger (rogue third occurrence)\n")
    assert_invalid!()

    prepare_fixture()

    replace_once!(
      @workflow,
      "jobs:\n  postgres-lanes:",
      """
      jobs:
        harmless-environment-key:
          runs-on: ubuntu-24.04
          env:
            uses: harmless-environment-value
          steps:
            - run: echo harmless

        postgres-lanes:
      """
      |> String.trim_trailing()
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "AGENTS.md",
      "## Development workflow",
      "## Development workflow\n\n<!-- This package is unsupported. -->"
    )

    assert_valid!()

    prepare_fixture()

    replace_once!(
      "AGENTS.md",
      "## Development workflow",
      "## Development workflow\n\nAsh 4 is not supported by this release line."
    )

    assert_valid!()
  end

  defp action_probes do
    prepare_fixture()
    replace_once!(@workflow, @checkout, "actions/checkout@v4")
    assert_invalid!()

    prepare_fixture()
    replace_once!(@workflow, @checkout, "actions/checkout@v4.2.2")
    assert_invalid!()

    prepare_fixture()
    insert_after_first_checkout!("      - {\"us\\u0065s\": actions/setup-node@v4}\n")
    assert_invalid!()

    prepare_fixture()
    insert_after_first_checkout!("      - uses: \"actions/setup-node@v4\"\n")
    assert_invalid!()

    prepare_fixture()
    replace_once!(@workflow, @checkout, "actions/checkout@not-a-sha")
    assert_invalid!()

    prepare_fixture()
    replace_once!(@beam, @setup_beam, @setup_beam <> "0")
    assert_invalid!()

    prepare_fixture()
    insert_after_first_checkout!("      - uses: #{@checkout} # unexpected duplicate\n")
    assert_invalid!()

    prepare_fixture()

    insert_after_first_checkout!(
      "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\n"
    )

    assert_invalid!()
  end

  defp action_input_probes do
    jobs = ["no-database", "compatibility", "release-artifact"]

    Enum.each(jobs, fn job ->
      prepare_fixture()

      mutate_job!(
        job,
        "          persist-credentials: false\n",
        "          persist-credentials: false\n          ref: stale-gate-revision\n"
      )

      assert_invalid!()
    end)

    runtimes = [
      {@workflow, "no-database"},
      {@workflow, "compatibility"},
      {@workflow, "performance"},
      {@workflow, "decoder-old-majors"},
      {@workflow, "fresh-consumer"},
      {@workflow, "release-artifact"},
      {@publish, "publish"},
      {@publish, "published-package"},
      {@drift, "report"}
    ]

    for {workflow, job} <- runtimes,
        {old, replacement} <- [
          {"      - uses: ./.github/actions/toolchain\n        id: toolchain\n", ""},
          {"      - uses: ./.github/actions/beam\n",
           "      - uses: ./.github/actions/beam\n        if: false\n"},
          {"          elixir: ${{ steps.toolchain.outputs.elixir }}\n",
           "          elixir: 1.20.3-otp-29\n"},
          {"          otp: ${{ steps.toolchain.outputs.otp }}\n", "          otp: 29.0.5\n"},
          {"          otp: ${{ steps.toolchain.outputs.otp }}\n", ""},
          {"        id: toolchain\n", "        id: toolchain\n        if: false\n"}
        ] do
      prepare_fixture()
      mutate_job!(job, old, replacement, workflow)
      assert_invalid!()
    end

    for {path, old, replacement} <- [
          {@beam, "        elixir-version: ${{ inputs.elixir }}\n",
           "        version-file: .tool-versions\n"},
          {@beam, "        elixir-version: ${{ inputs.elixir }}\n",
           "        elixir-version: 1.20.3-otp-29\n"},
          {@beam, "        otp-version: ${{ inputs.otp }}\n", "        otp-version: 29.0.5\n"},
          {@beam, "        version-type: strict\n", "        version-type: loose\n"},
          {@beam, "        install-hex: false\n", ""},
          {@beam, "--installed", "--unverified"},
          {@beam, "    - name: Refuse a runtime other than the reader names\n",
           "    - name: Refuse a runtime other than the reader names\n      if: false\n"},
          {@beam, "        WANT_ELIXIR: ${{ inputs.elixir }}\n",
           "        WANT_ELIXIR: 1.20.3-otp-29\n"},
          {@beam, "        WANT_OTP: ${{ inputs.otp }}\n", "        WANT_OTP: 29.0.5\n"},
          {@beam, "        WANT_HEX: \"2.7.0\"\n", "        WANT_HEX: \"2.6.0\"\n"},
          {@beam, "        mix local.hex \"$WANT_HEX\" --force\n",
           "        mix local.hex --force\n"},
          {@toolchain, "scripts/toolchain.sh --self-test", "true"},
          {@toolchain, "scripts/toolchain.sh >>", "sh scripts/toolchain.sh >>"},
          {@toolchain, "scripts/toolchain.sh >>", "awk '{print}' .tool-versions >>"},
          {@toolchain, "${{ steps.versions.outputs.elixir }}", "1.20.3-otp-29"},
          {@toolchain, "${{ steps.versions.outputs.otp }}", "29.0.5"},
          {"scripts/toolchain.sh", "set -euo pipefail", "set -eu"}
        ] do
      prepare_fixture()
      replace_once!(path, old, replacement)
      assert_invalid!()
    end

    for mode <- [0o644, 0o777, 0o4755] do
      prepare_fixture()
      File.chmod!(fixture_path("scripts/toolchain.sh"), mode)
      assert_invalid!()
    end

    for {old, replacement} <- [
          {"ARG BASE\n", "ARG BASE=postgres:latest\n"},
          {"=$PG_VERSION", ""},
          {"COPY --from=build /plugins/ /", "COPY --from=build /usr/lib/ /usr/lib/"},
          {"unsupported plugin source major\" >&2; exit 1",
           "unsupported plugin source major\" >&2; exit 0"}
        ] do
      prepare_fixture()
      replace_once!("test/support/pg_old.dockerfile", old, replacement)
      assert_invalid!()
    end
  end

  defp landing_and_fail_late_probes do
    prepare_fixture()

    jobs =
      fixture_path(@workflow) |> YamlElixir.read_from_file!() |> Map.fetch!("jobs") |> Map.keys()

    for job <- jobs, value <- ["true", "false", "${{ true }}"] do
      prepare_fixture()

      mutate_job!(
        job,
        "    runs-on: ubuntu-24.04\n",
        "    runs-on: ubuntu-24.04\n    continue-on-error: #{value}\n"
      )

      assert_invalid!()
      prepare_fixture()

      command =
        if job == "postgres-lanes", do: "scripts/ci/postgres-lanes.sh", else: "mix deps.compile"

      mutate_run_step!(job, command, fn step ->
        String.trim_trailing(step) <> "\n        continue-on-error: #{value}\n"
      end)

      assert_invalid!()
    end

    for branches <- [
          "",
          "master",
          "main",
          "main, 'kci/**'",
          "main, 'kci/*'",
          "main, 'kci/**', 't/**'",
          "'kci/*'",
          "'kci/**', 't/**'"
        ] do
      prepare_fixture()
      replace_once!(@landing, "branches: ['kci/**']", "branches: [#{branches}]")
      assert_invalid!()
    end

    # A path filter on push lets a candidate whose files are all filtered get no
    # run, and the landing tool cannot land a commit CI never ran on.
    for filter <- ["paths-ignore: ['**/*.md']", "paths: ['lib/**']", "tags: ['v*']"] do
      prepare_fixture()

      replace_once!(
        @landing,
        "    branches: ['kci/**']\n",
        "    branches: ['kci/**']\n    #{filter}\n"
      )

      assert_invalid!()
    end

    for job <- ["no-database", "compatibility"] do
      for replacement <- ["", "        id: other_compile\n", "        id: false\n"] do
        prepare_fixture()

        mutate_run_step!(job, "mix compile --warnings-as-errors", fn step ->
          replace_once(step, "        id: compile\n", replacement)
        end)

        assert_invalid!()
      end

      checks =
        @job_commands[job]
        |> Enum.drop_while(&(&1 != "mix compile --warnings-as-errors"))
        |> Enum.drop(1)
        |> Enum.reject(&(&1 == String.trim(@create_database)))

      for command <- checks do
        for replacement <- [
              "",
              "        if: false\n",
              "        if: ${{ always() }}\n",
              "        if: ${{ !cancelled() && steps.other_compile.outcome == 'success' }}\n"
            ] do
          prepare_fixture()

          mutate_run_step!(job, command, fn step ->
            replace_once(step, "        if: #{@fail_late}\n", replacement)
          end)

          assert_invalid!()
        end

        prepare_fixture()
        mutate_run_step!(job, command, &(String.trim_trailing(&1) <> "\n        id: check\n"))
        assert_invalid!()
      end

      for command <- ["mix deps.compile", "mix compile --warnings-as-errors"] do
        prepare_fixture()

        mutate_run_step!(job, command, fn step ->
          String.trim_trailing(step) <> "\n        if: #{@fail_late}\n"
        end)

        assert_invalid!()
      end

      prepare_fixture()

      mutate_run_step!(
        job,
        "mix deps.compile",
        &(String.trim_trailing(&1) <> "\n        id: compile\n")
      )

      assert_invalid!()
    end

    for command <- @job_commands["release-artifact"] do
      for control <- ["if: #{@fail_late}", "id: compile"] do
        prepare_fixture()

        mutate_run_step!("release-artifact", command, fn step ->
          String.trim_trailing(step) <> "\n        #{control}\n"
        end)

        assert_invalid!()
      end
    end

    for job <- ["no-database", "compatibility", "release-artifact"],
        command <- @job_commands[job],
        value <- ["true", "false", "${{ true }}"] do
      prepare_fixture()

      mutate_run_step!(job, command, fn step ->
        String.trim_trailing(step) <> "\n        continue-on-error: #{value}\n"
      end)

      assert_invalid!()
    end
  end

  defp qualification_probes do
    prepare_fixture()
    replace_once!(@landing, "on:\n  push:", "on:\n  pull_request:\n  push:")
    assert_invalid!()

    prepare_fixture()
    path = fixture_path(@landing)
    [caller, _verdict] = String.split(File.read!(path), "\n  qualified:", parts: 2)
    File.write!(path, caller <> "\n")
    assert_invalid!()

    for {old, replacement} <- [
          {"  qualified:\n", "  qualified:\n    name: qualified\n"},
          {"    if: always()\n", ""},
          {"    needs: [qualification]\n", "    needs: []\n"},
          {"    needs: [qualification]\n", ""},
          {"    timeout-minutes: 5\n", "    timeout-minutes: 10\n"},
          {"      actions: read\n", ""},
          {"          persist-credentials: false\n", "          persist-credentials: true\n"},
          {"      - run: python3 scripts/qualify.py\n", "      - run: true\n"},
          {"          GH_TOKEN: ${{ github.token }}\n", ""},
          {"          QUALIFICATION_RESULT: ${{ needs.qualification.result }}\n", ""},
          {"          EXPECTED_CHECKS: ${{ needs.qualification.outputs.checks }}\n", ""},
          {"          EXPECTED_CHECKS: ${{ needs.qualification.outputs.checks }}\n",
           "          EXPECTED_CHECKS: ${{ needs.qualification.outputs.other }}\n"},
          {"    uses: ./.github/workflows/qualification.yml\n",
           "    uses: ./.github/workflows/other.yml\n"}
        ] do
      prepare_fixture()
      replace_once!(@landing, old, replacement)
      assert_invalid!()
    end

    for {old, replacement} <- [
          {"      checks: ${{ steps.lanes.outputs.checks }}\n", ""},
          {"      checks: ${{ steps.lanes.outputs.checks }}\n",
           "      checks: ${{ steps.lanes.outputs.other }}\n"},
          {"    outputs:\n      checks:\n" <>
             "        description: Expected qualification check inventory\n" <>
             "        value: ${{ jobs.postgres-lanes.outputs.checks }}\n", ""},
          {"        value: ${{ jobs.postgres-lanes.outputs.checks }}\n",
           "        value: ${{ jobs.postgres-lanes.outputs.other }}\n"}
        ] do
      prepare_fixture()
      replace_once!(@workflow, old, replacement)
      assert_invalid!()
    end

    for trigger <- ["pull_request", "pull_request_target"] do
      prepare_fixture()

      File.write!(fixture_path(@pull_request), """
      name: Forbidden pull request execution
      on:
        #{trigger}:
      jobs:
        check:
          runs-on: ubuntu-24.04
          # Green run 44214414813: qualified 0m16s.
          timeout-minutes: 5
          steps:
            - uses: #{@checkout}
              with:
                persist-credentials: false
            - run: true
      """)

      assert_invalid!()
    end

    for workflow <- [@landing, @workflow, @publish],
        runner <- ["self-hosted", "${{ vars.BASELABS_RUNNER || 'ubuntu-24.04' }}"] do
      prepare_fixture()
      replace_once!(workflow, "runs-on: ubuntu-24.04", "runs-on: #{runner}")
      assert_invalid!()
    end

    for mutation <- [&tl/1, &(&1 ++ ["qualification / Extra proof"])] do
      prepare_fixture()
      path = fixture_path(@inventory)
      inventory = path |> File.read!() |> Jason.decode!()
      File.write!(path, Jason.encode!(mutation.(inventory)))
      assert_invalid!()
    end

    prepare_fixture()
    replace_once!(@workflow, "  workflow_call:\n", "  push:\n")
    assert_invalid!()
  end

  defp fresh_consumer_probes do
    prepare_fixture()
    path = fixture_path(@workflow)
    source = File.read!(path)

    File.write!(
      path,
      Regex.replace(~r/^  fresh-consumer:\n.*?(?=^  [a-z][a-z0-9-]+:\n|\z)/ms, source, "")
    )

    assert_invalid!()

    for {old, replacement} <- [
          {"scripts/test-fresh-consumer.sh", "scripts/test-fresh-consumer.sh --check"},
          {"    permissions:\n      contents: read", "    permissions:\n      contents: write"},
          {"      MIX_ENV: dev", "      MIX_ENV: prod"},
          {"      ASH_REPLICANT_TEST_URL:", "      UNUSED_DATABASE_URL:"},
          {"mix deps.get --check-locked", "mix deps.get"},
          {"mix deps.compile", "true"},
          {"        if: always()", "        if: success()"},
          {"          mode: stop", "          mode: start"}
        ] do
      prepare_fixture()
      mutate_job!("fresh-consumer", old, replacement)
      assert_invalid!()
    end

    for {old, replacement} <- [
          {~s|(cd "$root" && mix deps.audit --path "$consumer")|, "consumer_mix deps.audit"},
          {~s|(cd "$root" && mix deps.audit --path "$consumer")|, "true"},
          {~s|--path "$consumer"|, ~s|--path "$root"|},
          {"consumer_mix hex.audit", "true"},
          {"export MIX_ENV=dev", "export MIX_ENV=prod"}
        ] do
      prepare_fixture()
      replace_once!("scripts/test-fresh-consumer.sh", old, replacement)
      assert_invalid!()
    end
  end

  defp drift_report_probes do
    for trigger <- ["push", "pull_request", "pull_request_target", "workflow_call"] do
      prepare_fixture()
      replace_once!(@drift, "  workflow_dispatch:\n", "  workflow_dispatch:\n  #{trigger}:\n")
      assert_invalid!()
    end

    for {old, replacement} <- [
          {"  schedule:\n    - cron: '23 6 * * *'\n", ""},
          {"  workflow_dispatch:\n", ""},
          {"  contents: read\n", "  contents: write\n"},
          {"  contents: read\n", "  contents: read\n  actions: read\n"},
          {"  report:\n", "  qualified:\n"},
          {"    name: Upstream dependencies\n", "    name: qualified\n"},
          {"    runs-on: ubuntu-24.04\n", "    runs-on: self-hosted\n"},
          {"    env:\n", "    environment: publish\n    env:\n"},
          {"    env:\n", "    permissions:\n      contents: write\n    env:\n"},
          {"      MIX_ENV: test\n", "      MIX_ENV: test\n      KEY: ${{ secrets.KEY }}\n"},
          {"jobs:\n", "env:\n  KEY: ${{ secrets.KEY }}\njobs:\n"},
          {"          DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}\n",
           "          DEFAULT_BRANCH: main\n"},
          {~s|if [[ "$GITHUB_REF" != "refs/heads/$DEFAULT_BRANCH" ]]; then|,
           ~s|if [[ "$GITHUB_REF" == "refs/heads/$DEFAULT_BRANCH" ]]; then|},
          {"            exit 1\n", "            true\n"},
          {"          persist-credentials: false\n", "          persist-credentials: true\n"},
          {"          otp: ${{ steps.toolchain.outputs.otp }}\n",
           "          otp: ${{ steps.toolchain.outputs.otp }}\n          cache: true\n"},
          {"        id: runtime\n", ""},
          {"    timeout-minutes: 24\n", "    timeout-minutes: 90 # no green run yet\n"},
          {"          rm mix.lock\n", "          true\n"},
          {"        working-directory: ${{ runner.temp }}\n", ""},
          {"        working-directory: ${{ runner.temp }}\n",
           "        working-directory: ${{ github.workspace }}\n"},
          {"          mix deps.get\n", "          mix deps.get --check-locked\n"}
        ] do
      prepare_fixture()
      replace_once!(@drift, old, replacement)
      assert_invalid!()
    end

    for action <- ["actions/cache", "actions/cache/restore", "actions/cache/save"] do
      prepare_fixture()

      replace_once!(
        @drift,
        "      - name: Report Ash lock lag\n",
        "      - uses: #{action}@#{String.duplicate("a", 40)} # v5.0.0\n" <>
          "      - name: Report Ash lock lag\n"
      )

      assert_invalid!()
    end

    prepare_fixture()
    source = File.read!(fixture_path(@drift))
    [refusal] = Regex.run(~r/^      - name: Refuse.*?(?=^      - uses:)/ms, source)
    replace_once!(@drift, refusal, "")

    replace_once!(
      @drift,
      "          persist-credentials: false\n",
      "          persist-credentials: false\n" <> refusal
    )

    assert_invalid!()

    # Each check must remain independently reportable after another check fails.
    prepare_fixture()
    workflow = YamlElixir.read_from_file!(fixture_path(@drift))

    reports =
      workflow["jobs"]["report"]["steps"]
      |> Enum.drop(5)
      |> Enum.filter(&Map.has_key?(&1, "run"))

    for step <- reports do
      prepare_fixture()

      command =
        step["run"]
        |> String.trim_trailing()
        |> String.split("\n")
        |> Enum.map_join("\n", fn
          "" -> ""
          line -> "          " <> line
        end)
        |> String.trim_leading()

      replace_once!(@drift, command, "true")
      assert_invalid!()
    end

    for replacement <- ["", "success()", "always()", "${{ !cancelled() }}"] do
      prepare_fixture()
      replace_once!(@drift, "        if: #{@report_if}\n", "        if: #{replacement}\n")
      assert_invalid!()
    end
  end

  defp command_status_probes do
    defaults = "defaults:\n  run:\n    shell: bash\n\n"

    for workflow <- [@workflow, @landing, @publish, @drift] do
      for replacement <- ["", "defaults:\n  run:\n    shell: sh\n\n"] do
        prepare_fixture()
        replace_once!(workflow, defaults, replacement)
        assert_invalid!()
      end

      for shell <- ["sh", "bash {0}", "python3", "echo {0}"] do
        prepare_fixture()

        replace_once!(
          workflow,
          "      - run:",
          "      - shell: #{shell}\n        run:"
        )

        assert_invalid!()
      end
    end

    for {path, guard} <- @command_status_guards do
      prepare_fixture()
      replace_once!(path, guard, "removed_command_status_guard\n")
      assert_invalid!()
    end

    for command <- ["residue=", "credentials=", "package_files="] do
      prepare_fixture()
      source = File.read!(fixture_path(@workflow))
      [line] = Regex.run(~r/^          #{Regex.escape(command)}[^\n]*\n/m, source)
      replace_once!(@workflow, line, "")
      assert_invalid!()
    end

    for path <- Path.wildcard(Path.join(@source_root, "scripts/**/*.sh")) do
      relative = Path.relative_to(path, @source_root)

      for {old, replacement} <- [
            {"#!/usr/bin/env bash\n", "#!/bin/sh\n"},
            {"set -euo pipefail\n", "set -eu\n"}
          ] do
        prepare_fixture()
        replace_once!(relative, old, replacement)
        assert_invalid!()
      end
    end
  end

  defp publish_probes do
    admission =
      "      - name: Refuse a missing, duplicated or empty release changelog section\n" <>
        "        run: python3 -I scripts/release-notes.py\n"

    for replacement <- [
          "",
          String.replace(admission, "        run:", "        if: false\n        run:")
        ] do
      prepare_fixture()
      replace_once!(@publish, admission, replacement)
      assert_invalid!()
    end

    prepare_fixture()
    replace_once!(@publish, admission, "")

    replace_once!(
      @publish,
      "      - run: mix local.rebar --force\n",
      "      - run: mix local.rebar --force\n" <> admission
    )

    assert_invalid!()

    for {path, old} <- [
          {"scripts/release-notes.py", "if len(versions) != 1:"},
          {"scripts/release-notes.py", "if len(matches) != 1 or not matches[0].isfile():"},
          {"scripts/release-notes.py", "if not re.sub("},
          {"scripts/release-notes.py", "if len(sections) == 1 else"},
          {"scripts/check-docs-archive.py",
           "notes = release_notes.package_section(package_archive, version)"},
          {"scripts/check-docs-archive.py", "Commit: {published}"},
          {"scripts/check-docs-archive.py", "Package SHA-256: {digests[0]}"},
          {"scripts/check-docs-archive.py", "Docs SHA-256: {digests[1]}"},
          {"scripts/test_release_docs.py", "release notes accepted an invalid changelog section"},
          {"scripts/test_release_docs.py",
           "release assets accepted invalid packaged release notes"}
        ] do
      prepare_fixture()
      replace_once!(path, old, "removed_release_notes_guard")
      assert_invalid!()
    end

    for trigger <- ["push", "pull_request"] do
      prepare_fixture()

      replace_once!(
        @publish,
        "  workflow_dispatch:\n",
        "  workflow_dispatch:\n  #{trigger}:\n"
      )

      assert_invalid!()
    end

    for {old, replacement} <- [
          {"    environment: publish\n", ""},
          {"    environment: publish\n", "    environment: other\n"},
          {"mix deps.get --check-locked", "mix deps.get"},
          {"          persist-credentials: false\n", "          persist-credentials: true\n"},
          {"    timeout-minutes: 90 # no green run yet\n", "    timeout-minutes: 30\n"},
          {"90 # no green run yet", "90 # unmeasured"},
          {"90 # no green run yet", "90"},
          {"          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}\n",
           "          HEX_API_KEY: ${{ secrets.OTHER_KEY }}\n"},
          {~s(scripts/build-release-docs.sh "$RUNNER_TEMP/hex-docs.tar.gz"), "true"},
          {"scripts/build-release-docs.sh", "true"},
          {"scripts/inspect-release-package.sh", "true"},
          {"        working-directory: ${{ runner.temp }}\n", ""},
          {"working-directory: ${{ runner.temp }}", "working-directory: ${{ github.workspace }}"},
          {~s(mix run --no-mix-exs "$GITHUB_WORKSPACE/scripts/publish_hex_artifacts.exs"),
           "mix hex.publish --yes"},
          {~s(mix run --no-mix-exs "$GITHUB_WORKSPACE/scripts/publish_hex_artifacts.exs"),
           "mix run scripts/publish_hex_artifacts.exs"},
          {~s(mix run --no-mix-exs "$GITHUB_WORKSPACE/scripts/publish_hex_artifacts.exs"),
           "mix compile && mix run --no-mix-exs scripts/publish_hex_artifacts.exs"},
          {~s(mix run --no-mix-exs "$GITHUB_WORKSPACE/scripts/publish_hex_artifacts.exs"),
           "mix run --no-mix-exs scripts/other.exs"},
          {"ash_replicant \"$VERSION\" \"$RUNNER_TEMP/package.tar\"",
           "ash_replicant \"$VERSION\" \"$RUNNER_TEMP/other.tar\""},
          {"name: release-assets", "name: other-assets"},
          {"cf430e030ddbb5b0abf93d22962f4752f3646cd9", "v7.0.2"}
        ] do
      prepare_fixture()
      replace_once!(@publish, old, replacement)
      assert_invalid!()
    end

    for condition <- [
          "",
          "    if: true\n",
          "    if: contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.actor)\n",
          "    if: #{String.replace(@publish_owner_condition, "palermo-git", "other-actor")}\n"
        ] do
      prepare_fixture()
      replace_once!(@publish, "    if: #{@publish_owner_condition}\n", condition)
      assert_invalid!()
    end

    for scope <- [:job, :workflow] do
      prepare_fixture()
      replace_once!(@publish, "          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}\n", "")

      case scope do
        :job ->
          replace_once!(
            @publish,
            "      MIX_ENV: dev\n",
            "      MIX_ENV: dev\n      HEX_API_KEY: ${{ secrets.HEX_API_KEY }}\n"
          )

        :workflow ->
          replace_once!(
            @publish,
            "jobs:\n",
            "env:\n  HEX_API_KEY: ${{ secrets.HEX_API_KEY }}\n\njobs:\n"
          )
      end

      assert_invalid!()
    end

    # Every other step, including actions and cleanup, must reject the publish key.
    source = File.read!(Path.join(@source_root, @publish))

    steps =
      Regex.scan(~r/^      - .*?(?=^      - |^  [a-z][a-z0-9-]+:\n|\z)/ms, source)
      |> List.flatten()

    for step <- steps, not String.contains?(step, "name: Upload inspected archives") do
      prepare_fixture()

      replacement =
        if String.contains?(step, "        env:\n") do
          String.replace(
            step,
            "        env:\n",
            "        env:\n          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}\n"
          )
        else
          String.trim_trailing(step) <>
            "\n        env:\n          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}\n"
        end

      replace_once!(@publish, step, replacement)
      assert_invalid!()
    end

    prepare_fixture()
    replace_once!(@publish, "name: Publish to Hex", "name: Publish to Hex\n# mix hex.publish")
    assert_invalid!()

    for selector <- [
          "ASH_REPLICANT_ASH_VERSION",
          "ASH_REPLICANT_REPLICANT_VERSION",
          "ASH_REPLICANT_ONETIME_VERSION"
        ] do
      prepare_fixture()
      replace_once!(@publish, "-u #{selector} ", "")
      assert_invalid!()
    end

    for {path, old} <- [
          {"scripts/publish_hex_artifacts.exs", "    package_bytes = File.read!(archive)"},
          {"scripts/publish_hex_artifacts.exs", "    docs_bytes = File.read!(docs)"},
          {"scripts/publish_hex_artifacts.exs", "    if Mix.Project.get()"},
          {"scripts/publish_hex_artifacts.exs",
           "existing_package!(Hex.API.Package.get_anonymous(nil, name), name)"},
          {"scripts/publish_hex_artifacts.exs", "{:held, _docs?} ->"},
          {"scripts/publish_hex_artifacts.exs",
           "Hex.API.Release.publish(nil, package_bytes, auth)"},
          {"scripts/publish_hex_artifacts.exs",
           "Hex.API.ReleaseDocs.publish(nil, name, version, docs_bytes, auth)"},
          {"scripts/publish_hex_artifacts.exs", "package_read_back!(Hex.Repo.get_tarball"},
          {"scripts/publish_hex_artifacts.exs", "docs_read_back!(Hex.Repo.get_docs"},
          {"scripts/publish_hex_artifacts.exs", "|> approved!()"},
          {"scripts/release_identity.exs", "checksum != digest"},
          {"scripts/release_identity.exs", "retirement != :null"},
          {"scripts/build-release-docs.sh", "mix docs --warnings-as-errors"},
          {"scripts/build-release-docs.sh", "release.json"},
          {"scripts/build-release-docs.sh", "mix deps.get --check-locked"},
          {"scripts/build-docs-archive.exs", ":mix_hex_tarball.create_docs(files)"},
          {"scripts/check-docs-archive.py", "if source is not None and names != source.keys():"},
          {"scripts/test_release_docs.py", "check(candidate, Path(directory))"},
          {"scripts/test_publish_hex_artifacts.exs", "PublishHexArtifacts.package_read_back!"},
          {"scripts/test_publish_hex_artifacts.exs", "PublishHexArtifacts.docs_read_back!"},
          {"scripts/read-release-assets.sh", "fetch_archive"},
          {"scripts/read-release-assets.sh", "--assets"},
          {"scripts/check-docs-archive.py", "if release is None:"},
          {"scripts/check-docs-archive.py",
           ~s|git("merge-base", "--is-ancestor", published, commit)|},
          {"scripts/check-docs-archive.py", "shutil.copyfile(archive, paths[1])"}
        ] do
      prepare_fixture()
      replace_once!(path, old, "removed_guard")
      assert_invalid!()
    end

    for job <- ["publish", "published-package"] do
      for {old, replacement} <- [
            {"    if: " <> @publish_owner_condition, "    if: true"},
            {"mix deps.get --check-locked", "mix deps.get"},
            {"refs/heads/main", "refs/heads/other"}
          ] do
        prepare_fixture()
        mutate_job!(job, old, replacement, @publish)
        assert_invalid!()
      end
    end

    for {old, replacement} <- [
          {"    needs: publish", "    needs: []"},
          {"    name: Verify published package",
           "    environment: publish\n    name: Verify published package"},
          {"scripts/test-fresh-consumer.sh --from-hex", "true --from-hex"},
          {"scripts/read-release-assets.sh", "true"},
          {"          fetch-depth: 0", "          fetch-depth: 1"}
        ] do
      prepare_fixture()
      replace_once!(@publish, old, replacement)
      assert_invalid!()
    end
  end

  defp ci_requirement_probes do
    jobs = [
      {@workflow, "postgres-lanes", 90},
      {@workflow, "no-database", 77},
      {@workflow, "compatibility", 37},
      {@workflow, "performance", 7},
      {@workflow, "decoder-old-majors", 7},
      {@workflow, "release-artifact", 12},
      {@workflow, "fresh-consumer", 9},
      {@landing, "qualified", 5},
      {@publish, "publish", 5},
      {@drift, "report", 24},
      {@publish, "published-package", 90}
    ]

    for {workflow, job, timeout} <- jobs do
      suffix =
        if job in ["published-package", "postgres-lanes"], do: " # no green run yet", else: ""

      for replacement <- ["", "    timeout-minutes: 1\n"] do
        prepare_fixture()
        mutate_job!(job, "    timeout-minutes: #{timeout}#{suffix}\n", replacement, workflow)
        assert_invalid!()
      end

      prepare_fixture()

      if job in ["published-package", "postgres-lanes"] do
        mutate_job!(job, "# no green run yet", "# No measurement", workflow)
      else
        path = fixture_path(workflow)
        source = File.read!(path)
        pattern = ~r/^  #{Regex.escape(job)}:\n.*?(?=^  [a-z][a-z0-9-]+:\n|\z)/ms
        [block] = Regex.run(pattern, source)
        [comment] = Regex.run(~r/# Green run [0-9]+:/, block)
        mutate_job!(job, comment, "# No measurement:", workflow)
      end

      assert_invalid!()

      unless job in ["published-package", "postgres-lanes"] do
        # A measured timeout must cite a recorded green run, not any number.
        prepare_fixture()
        path = fixture_path(workflow)
        pattern = ~r/^  #{Regex.escape(job)}:\n.*?(?=^  [a-z][a-z0-9-]+:\n|\z)/ms
        [block] = Regex.run(pattern, File.read!(path))
        [comment] = Regex.run(~r/# Green run [0-9]+:/, block)
        mutate_job!(job, comment, "# Green run 1:", workflow)
        assert_invalid!()
      end

      prepare_fixture()
      mutate_job!(job, "persist-credentials: false", "persist-credentials: true", workflow)
      assert_invalid!()

      unless workflow in [@landing, @drift] or job == "postgres-lanes" do
        prepare_fixture()
        mutate_job!(job, "mix deps.get --check-locked", "mix deps.get", workflow)
        assert_invalid!()
      end
    end

    prepare_fixture()
    extra = fixture_path(".github/workflows/extra.yml")

    File.write!(extra, """
    name: Expression guard probe
    on:
      workflow_call:
    defaults:
      run:
        shell: bash
    jobs:
      check:
        runs-on: ubuntu-24.04
        # Green run 44214414813: qualified 0m16s.
        timeout-minutes: 5
        steps:
          - uses: #{@checkout}
            with:
              persist-credentials: false
          - run: echo "$GITHUB_REF"
    """)

    assert_valid!()
    extra_source = File.read!(extra)

    for command <- ["mix deps.get", "mix deps.unlock --all", "mix deps.update --all"] do
      File.write!(extra, String.replace(extra_source, ~s(echo "$GITHUB_REF"), command))
      assert_invalid!()
    end

    File.write!(extra, extra_source)

    replace_once!(
      ".github/workflows/extra.yml",
      ~s(echo "$GITHUB_REF"),
      ~s(echo "${{ github.ref }}")
    )

    assert_invalid!()

    paths = ~w(AGENTS.md CONTRIBUTING.md docs/adr/0002-supported-runtime-and-dependencies.md)

    for path <- paths do
      prepare_fixture()
      source = File.read!(fixture_path(path))
      File.write!(fixture_path(path), source <> "\nUse kci/lock-bootstrap-ash.\n")
      assert_invalid!()
    end

    for name <- ["mix.exs", "mix.lock"] do
      prepare_fixture()
      File.write!(fixture_path("test/fixtures/release_checker/#{name}"), "")
      assert_invalid!()
    end

    prepare_fixture()
    File.rm!(fixture_path("test/fixtures/release_checker/recorded.lock"))
    assert_invalid!()

    for label <- ["exact-floors", "latest-compatible"] do
      prepare_fixture()
      File.rm!(fixture_path("locks/#{label}.lock"))
      assert_invalid!()
    end

    for {old, replacement} <- [
          {"cp mix.lock \"$fixture/mix.lock\"", ":"},
          {"mix deps.get --check-locked", "mix deps.get"},
          {"&& mix hex.audit)", ")"},
          {"mix deps.audit --path \"$fixture\"", ":"},
          {"trap 'rm -rf \"$fixture\"' EXIT", ":"}
        ] do
      prepare_fixture()
      replace_once!("scripts/audit-fixtures.sh", old, replacement)
      assert_invalid!()
    end

    prepare_fixture()

    replace_once!(
      "test/integration/upgrade_checkpoint_test.exs",
      ~s|["deps.get", "--check-locked"]|,
      ~s|["deps.get"]|
    )

    assert_invalid!()

    ref_step =
      "      - name: Refuse publishing outside the default branch\n" <>
        "        run: test \"$GITHUB_REF\" = \"refs/heads/main\"\n"

    for replacement <- ["", String.replace(ref_step, "refs/heads/main", "refs/heads/other")] do
      prepare_fixture()
      replace_once!(@publish, ref_step, replacement)
      assert_invalid!()
    end

    prepare_fixture()
    replace_once!(@publish, ref_step, "")

    replace_once!(
      @publish,
      "      - uses: ./.github/actions/toolchain",
      ref_step <> "      - uses: ./.github/actions/toolchain"
    )

    assert_invalid!()
    prepare_fixture()
    replace_once!(@publish, " --unreleased\n", "\n")
    assert_invalid!()

    for {old, replacement} <- [
          {"    assert_hex_package_exists ash_replicant https://hex.pm/api/packages/ash_replicant",
           "    :"},
          {"200) ;;", "201) ;;"},
          {"404) release_tree_fail \"$name is not on Hex; first publication is the owner's decision\" ;;",
           "404) ;;"},
          {"*) release_tree_fail \"$name package lookup failed\" ;;", "*) ;;"},
          {"|| release_tree_fail \"$name package lookup failed\"", "|| return 0"},
          {"0) release_tree_fail 'local tag already exists' ;;", "0) ;;"},
          {"*) release_tree_fail 'local tag lookup failed' ;;", "*) ;;"},
          {"0) release_tree_fail 'remote tag already exists' ;;", "0) ;;"},
          {"*) release_tree_fail 'remote tag lookup failed' ;;", "*) ;;"},
          {"404) ;;", "204) ;;"},
          {"200) release_tree_fail \"$label already exists\" ;;", "200) ;;"},
          {"*) release_tree_fail \"$label lookup failed\" ;;", "*) ;;"},
          {"|| release_tree_fail \"$label lookup failed\"", "|| return 0"},
          {"    assert_github_release_absent", "    :"},
          {~s|    elixir "$(dirname "${BASH_SOURCE[0]}")/release_identity.exs"|, "    :"},
          {"git ls-remote --exit-code --tags origin", ": --exit-code --tags origin"},
          {"gh api --hostname github.com -i", "curl -i"},
          {"[[ -n \"${GH_TOKEN:-}\" ]]", "true"},
          {"read -r protocol code _", "read -r protocol _ code"},
          {"404:1) ;;", "404:0) ;;"},
          {"200:0) release_tree_fail 'GitHub release already exists' ;;", "200:0) ;;"},
          {"*) release_tree_fail 'GitHub release lookup failed' ;;", "*) ;;"}
        ] do
      prepare_fixture()
      replace_once!("scripts/assert-release-tree.sh", old, replacement)
      assert_invalid!()
    end
  end

  defp github_lookup_probes do
    for {workflow, job, command} <- [
          {@workflow, "no-database", "scripts/test-release-guards.sh"},
          {@publish, "publish", "scripts/assert-release-tree.sh"}
        ] do
      for replacement <- ["", "          GH_TOKEN: ${{ secrets.HEX_API_KEY }}\n"] do
        prepare_fixture()
        mutate_job!(job, "          GH_TOKEN: ${{ github.token }}\n", replacement, workflow)
        assert_invalid!()
      end

      prepare_fixture()

      mutate_job!(
        job,
        "      MIX_ENV:",
        "      GH_TOKEN: ${{ github.token }}\n      MIX_ENV:",
        workflow
      )

      assert_invalid!()
      prepare_fixture()
      mutate_job!(job, "      contents: read\n", "      contents: write\n", workflow)
      assert_invalid!()
      prepare_fixture()
      mutate_job!(job, command, "true", workflow)
      assert_invalid!()
    end

    for {path, old, replacement} <- [
          {"scripts/test-release-checkers.sh", "scripts/test-newest-dependency.sh",
           "scripts/test-release-guards.sh\nscripts/test-newest-dependency.sh"},
          {"scripts/qualify.py", ~s|"gh", "api", "--hostname", "github.com"|, ~s|"curl"|},
          {"scripts/qualify.py", ~s|if not os.environ.get("GH_TOKEN"):|, "if False:"},
          {"scripts/verify-release.sh", "gh api --hostname github.com", "curl"},
          {"scripts/verify-release.sh", ~s|[[ -n "${GH_TOKEN:-}" ]]|, "true"},
          {"scripts/test-release-guards.sh", "without_github_token", "without_token_bypass"},
          {"scripts/test-release-guards.sh", "assert_hex_package_exists ash_replicant.invalid",
           "true"},
          {"test/fixtures/upgrade_0_4_app/mix.exs", "EEF-CVE-2026-95105", "unreviewed-advisory"}
        ] do
      prepare_fixture()
      replace_once!(path, old, replacement)
      assert_invalid!()
    end
  end

  defp postgres_probes do
    for {old, replacement} <- [
          {"wal_level=logical", "wal_level=replica"},
          {"pg_isready -h 127.0.0.1", "pg_isready"},
          {"docker rm -f -v", "docker rm -f"},
          {"docker logs \"$CONTAINER\" || cleanup_status=1", "true"},
          {"--env TEST_PG_PASSWORD", "--env OMITTED_PASSWORD"},
          {"--tmpfs /var/lib/pg:uid=26,gid=26,mode=0750", "--tmpfs /var/lib/pg"},
          {"host replication all all md5", "host replication all all trust"},
          {"docker pull \"$engine\"", "true"}
        ] do
      prepare_fixture()
      replace_once!(".github/actions/postgres/action.yml", old, replacement)
      assert_invalid!()
    end
  end

  defp decoder_job_probes do
    for control <- [
          "if: false",
          "shell: echo {0}",
          "env:\n          BASH_ENV: /tmp/release-bypass"
        ] do
      prepare_fixture()

      mutate_run_step!("decoder-old-majors", "mix deps.compile", fn step ->
        String.trim_trailing(step) <> "\n        #{control}\n"
      end)

      assert_invalid!()
      prepare_fixture()
      assert_valid!()
    end

    prepare_fixture()

    mutate_job!(
      "decoder-old-majors",
      "      MIX_ENV: test\n",
      "      MIX_ENV: test\n      BASH_ENV: /tmp/release-bypass\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "decoder-old-majors",
      "    runs-on: ubuntu-24.04\n",
      "    runs-on: ubuntu-24.04\n    defaults:\n      run:\n        shell: echo {0}\n"
    )

    assert_invalid!()
    prepare_fixture()
    assert_valid!()
  end

  defp command_probes do
    Enum.each(@job_commands, fn {job, commands} ->
      Enum.each(commands, fn command ->
        prepare_fixture()
        remove_run_command!(job, command)
        assert_invalid!()
      end)
    end)

    command = "scripts/test-release-contract.sh"

    for replacement <- [
          "      - run: |\n          if false; then\n            #{command}\n          fi\n",
          "      - run: |\n          never_called() {\n            #{command}\n          }\n",
          "      - run: |\n          cat <<'EOF'\n          #{command}\n          EOF\n",
          "      - run: |\n          exit 0\n          #{command}\n",
          "      - run: #{command}\n        if: false\n",
          "      - run: #{command}\n        continue-on-error: true\n"
        ] do
      prepare_fixture()
      mutate_run_step!("no-database", command, fn _step -> replacement end)
      assert_invalid!()
    end

    prepare_fixture()

    mutate_job!(
      "no-database",
      "    name: No-database tests\n",
      "    name: No-database tests\n    if: false\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "no-database",
      "    name: No-database tests\n",
      "    name: No-database tests\n    continue-on-error: true\n"
    )

    assert_invalid!()

    prepare_fixture()
    swap_run_commands!("no-database", "mix deps.compile", "mix compile --warnings-as-errors")
    assert_invalid!()
  end

  defp compatibility_probes do
    prepare_fixture()

    mutate_job!(
      "compatibility",
      "      ASH_REPLICANT_ASH_VERSION: ${{ matrix.ash_selector }}\n",
      ""
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "      ASH_REPLICANT_REPLICANT_VERSION: ${{ matrix.replicant_selector }}\n",
      ""
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          mix deps.get --check-locked\n",
      ""
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          mix deps ash\n",
      ""
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          mix deps replicant\n",
      ""
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          LOCKFILE: ${{ matrix.lockfile }}\n",
      "          LOCKFILE: ${{ matrix.lockfile }}\n          ASH_REPLICANT_ASH_VERSION: latest\n"
    )

    assert_invalid!()

    for replacement <- ["            :\n", "            cp mix.lock mix.lock\n"] do
      prepare_fixture()

      mutate_job!(
        "compatibility",
        "            cp \"$LOCKFILE\" mix.lock\n",
        replacement
      )

      assert_invalid!()
    end

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          scripts/assert-dependency-version.sh ash \"$ASH_REQUIREMENT\"\n",
      "          :\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          scripts/assert-dependency-version.sh replicant \"$REPLICANT_REQUIREMENT\"\n",
      "          :\n"
    )

    assert_invalid!()

    for command <- [
          "scripts/assert-dependency-version.sh --newest ash \"$ASH_REQUIREMENT\"",
          "scripts/assert-dependency-version.sh --newest replicant \"$REPLICANT_REQUIREMENT\"",
          "scripts/assert-dependency-version.sh --newest ash_onetime \"$ONETIME_REQUIREMENT\"",
          "scripts/assert-dependency-version.sh --newest ash_postgres '~> 2.13'",
          "scripts/assert-dependency-version.sh --newest spark '~> 2.7.0'",
          "curl https://hex.pm/api/packages/ash",
          "mix hex.outdated",
          "python3 scripts/hex-release-candidates.py"
        ] do
      prepare_fixture()

      mutate_job!(
        "compatibility",
        "          mix deps ash\n",
        "          mix deps ash\n          #{command}\n"
      )

      assert_invalid!()
    end

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          mix deps.get --check-locked\n",
      "          mix deps.get\n"
    )

    assert_invalid!()

    for {old, replacement} <- [
          {~s({"current-lock", "mix.lock", ""}), ~s({"changed-lock", "mix.lock", ""})},
          {~s({"current-lock", "mix.lock", ""}), ~s({"current-lock", "mix.lock", "latest"})},
          {~s({"exact-floors", "locks/exact-floors.lock", :floor}),
           ~s({"exact-floors", "mix.lock", :floor})},
          {~s("== " <> selector), ~s(">= " <> selector)},
          {"selector = if mode == :floor, do: floor!(requirement), else: mode",
           ~s(selector = if mode == :floor, do: "0.0.0", else: mode)}
        ] do
      prepare_fixture()
      replace_once!("scripts/dependency_lanes.exs", old, replacement)
      assert_invalid!()
    end

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "      ASH_REPLICANT_ONETIME_VERSION: ${{ matrix.onetime_selector }}\n",
      ""
    )

    assert_invalid!()
  end

  defp public_dependency_probes do
    for {configured, expected_status, message} <- [
          {"deps: deps() |> select_requirements(),", 0, nil},
          {~s|deps: select_requirements(deps()) ++ [{:extra_literal, "~> 7.8"}],|, 1,
           "unexpected public dependency set"},
          {"deps: Enum.reject(select_requirements(deps()), &(elem(&1, 0) == :ash_cloak)),", 1,
           "unexpected public dependency set"}
        ] do
      prepare_fixture()
      directory = fixture_path("metadata-consumer")
      File.mkdir_p!(directory)

      source =
        @source_root
        |> Path.join("mix.exs")
        |> File.read!()
        |> String.replace("deps: deps() |> select_requirements(),", configured)

      File.write!(Path.join(directory, "mix.exs"), source)
      reader = Path.join(@source_root, "lib/ash_replicant/dependency_requirements.ex")

      command =
        String.replace(
          @public_dependency_check,
          "mix run --no-start -e",
          "elixir -r \"#{reader}\" -S mix run --no-start --no-compile --no-deps-check -e"
        )

      {output, status} =
        System.cmd("bash", ["-euo", "pipefail", "-c", command],
          cd: directory,
          stderr_to_stdout: true
        )

      unless status == expected_status and (is_nil(message) or String.contains?(output, message)) do
        raise "public dependency metadata guard did not observe the expected set"
      end

      Process.put({__MODULE__, :checks}, Process.get({__MODULE__, :checks}, 0) + 1)
    end
  end

  # The selector-free packaging commands must clear ALL THREE dependency
  # selectors (release-artifact deps.get, the metadata assertion, and
  # hex.build). RED/GREEN regression for the ASH_REPLICANT_ONETIME_VERSION
  # omission: against the pre-fix checker these mutations were ACCEPTED,
  # so an exported onetime selector could pin the built package's metadata
  # to one version instead of publishing the requirement range. Each probe
  # removes exactly the onetime clearing (or weakens the asserted
  # onetime requirement) and must be rejected byte-for-byte.
  defp packaging_selector_probes do
    prepare_fixture()

    mutate_job!(
      "release-artifact",
      "      - run: env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix deps.get --check-locked\n",
      "      - run: env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION mix deps.get --check-locked\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "release-artifact",
      "          env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix run --no-start -e '\n",
      "          env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION mix run --no-start -e '\n"
    )

    assert_invalid!()

    for dependency <- [:ash_onetime, :ash_cloak, :postgrex] do
      prepare_fixture()

      mutate_job!(
        "release-artifact",
        ~s[          expected = AshReplicant.DependencyRequirements.read!("mix.exs")],
        ~s[          expected = AshReplicant.DependencyRequirements.read!("mix.exs") |> Map.delete(:#{dependency})]
      )

      assert_invalid!()
    end

    prepare_fixture()

    mutate_job!(
      "release-artifact",
      "          env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix hex.build --unpack --output \"$package_dir\"\n",
      "          env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION mix hex.build --unpack --output \"$package_dir\"\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "release-artifact",
      """
                if ! diff -u scripts/release-package-files.txt - <<<"$package_files"; then
                  echo "::error::Package files differ from the release allowlist"
                  exit 1
                fi
      """,
      "          :\n"
    )

    assert_invalid!()
  end

  defp workflow_structure_probes do
    prepare_fixture()

    replace_once!(
      @workflow,
      "    shell: bash\n",
      "    shell: echo {0}\n"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      @workflow,
      "permissions:\n",
      "env:\n  BASH_ENV: /tmp/release-bypass\n\npermissions:\n"
    )

    assert_invalid!()

    for {job, mix_env} <- [
          {"no-database", "test"},
          {"compatibility", "test"},
          {"release-artifact", "dev"}
        ] do
      prepare_fixture()

      mutate_job!(
        job,
        "      MIX_ENV: #{mix_env}\n",
        "      MIX_ENV: #{mix_env}\n      BASH_ENV: /tmp/release-bypass\n"
      )

      assert_invalid!()
    end

    for job <- ["no-database", "compatibility", "release-artifact"] do
      prepare_fixture()

      mutate_job!(
        job,
        "    runs-on: ubuntu-24.04\n",
        """
            runs-on: ubuntu-24.04
            container:
              image: ubuntu:24.04
              env:
                BASH_ENV: /tmp/release-bypass
        """
      )

      assert_invalid!()
    end

    prepare_fixture()

    insert_after_first_checkout!("""
          - name: Inject inherited Bash control
            run: |
              printf '%s\\n' "trap 'exit 0' DEBUG" > /tmp/release-bypass
              printf '%s\\n' 'BASH_ENV=/tmp/release-bypass' >> "$GITHUB_ENV"
    """)

    assert_invalid!()

    prepare_fixture()
    mutate_job!("compatibility", "      fail-fast: false\n", "      fail-fast: true\n")
    assert_invalid!()

    for replacement <- [
          "      - run: scripts/test-release-contract.sh\n        shell: echo {0}\n",
          "      - run: scripts/test-release-contract.sh\n        continue-on-error: ${{ true }}\n",
          "      - run: scripts/test-release-contract.sh\n        env:\n          ASH_REPLICANT_ASH_VERSION: latest\n"
        ] do
      prepare_fixture()

      mutate_run_step!("no-database", "scripts/test-release-contract.sh", fn _step ->
        replacement
      end)

      assert_invalid!()
    end

    for control <- [
          "    continue-on-error: ${{ true }}\n",
          "    defaults:\n      run:\n        shell: echo {0}\n"
        ] do
      prepare_fixture()

      mutate_job!(
        "no-database",
        "    name: No-database tests\n",
        "    name: No-database tests\n#{control}"
      )

      assert_invalid!()
    end

    prepare_fixture()

    mutate_job!(
      "no-database",
      "    needs: postgres-lanes\n",
      "    needs: disabled-prerequisite\n"
    )

    assert_invalid!()

    prepare_fixture()
    replace_once!(@workflow, "    runs-on: ubuntu-24.04\n", "    runs-on: self-hosted\n")
    assert_invalid!()

    prepare_fixture()

    replace_once!(
      @workflow,
      "include: ${{ fromJSON(needs.postgres-lanes.outputs.compatibility) }}",
      "include: []"
    )

    assert_invalid!()

    for workflow <- [@workflow, @publish],
        declaration <- ["ELIXIR_VERSION: \"1.20.3\"", "OTP_VERSION: \"29.0.5\""] do
      prepare_fixture()
      replace_once!(workflow, "jobs:\n", "env:\n  #{declaration}\n\njobs:\n")
      assert_invalid!()
    end

    # A patch update changes the single source, with no workflow version edit.
    prepare_fixture()
    replace_once!(".tool-versions", "erlang 29.0.5", "erlang 29.0.6")
    assert_valid!()

    prepare_fixture()
    replace_once!(".tool-versions", "erlang 29.0.5", "erlang 29")
    assert_invalid!()

    prepare_fixture()
    replace_once!(".tool-versions", "elixir 1.20.3-otp-29", "elixir 1.20.3-otp-28")
    assert_invalid!()
  end

  defp documentation_probes do
    Enum.each(@doc_contracts, fn {path, heading, required_texts} ->
      prepare_fixture()
      replace_once!(path, heading, "#{heading} changed")
      assert_invalid!()

      Enum.each(required_texts, fn required ->
        prepare_fixture()
        replace_once!(path, required, "contract text removed")
        assert_invalid!()

        prepare_fixture()
        replace_once!(path, required, "<!--\n#{required}\n-->")
        assert_invalid!()
      end)

      prepare_fixture()
      replace_once!(path, hd(required_texts), "```text\n#{hd(required_texts)}\n```")
      assert_invalid!()

      prepare_fixture()
      replace_once!(path, hd(required_texts), "~~~text\n#{hd(required_texts)}\n~~~")
      assert_invalid!()

      prepare_fixture()

      replace_once!(
        path,
        hd(required_texts),
        "```text\n```still-code\n#{hd(required_texts)}\n```"
      )

      assert_invalid!()

      prepare_fixture()

      replace_once!(
        path,
        hd(required_texts),
        "```text\n    ```\n#{hd(required_texts)}\n```"
      )

      assert_invalid!()

      prepare_fixture()

      replace_once!(
        path,
        heading,
        "#{heading}\n\nThis package does not support Elixir 1.20.3 or Erlang/OTP 29."
      )

      assert_invalid!()

      for entity <- ["&#32;", "&#160;", "&#x2009;", "&#8203;"] do
        prepare_fixture()

        replace_once!(
          path,
          heading,
          "#{heading}\n\nThis package does#{entity}not support Elixir 1.20.3 or Erlang/OTP 29."
        )

        assert_invalid!()
      end

      for name <- @named_separator_entities do
        prepare_fixture()

        replace_once!(
          path,
          heading,
          "#{heading}\n\nThis package does&#{name};not support Elixir 1.20.3 or Erlang/OTP 29."
        )

        assert_invalid!()
      end

      prepare_fixture()

      replace_once!(
        path,
        heading,
        "#{heading}\n\nThis package does not support\nElixir 1.20.3 or Erlang/OTP 29."
      )

      assert_invalid!()
    end)
  end

  defp b1_documentation_probes do
    Enum.each(@b1_doc_contracts, fn {path, heading, required_texts} ->
      prepare_fixture()
      replace_once!(path, heading, "#{heading} changed")
      assert_invalid!()

      Enum.each(required_texts, fn required ->
        prepare_fixture()
        replace_contract_text_once!(path, required, "destination boundary contract text removed")
        assert_invalid!()
      end)
    end)

    prepare_fixture()

    replace_contract_text_once!(
      "README.md",
      "Declarations are trusted metadata; they do not prove an arbitrary Elixir body.",
      "<!-- Declarations are trusted metadata; they do not prove an arbitrary Elixir body. -->"
    )

    assert_invalid!()

    Enum.each(@b1_forbidden_positive_claims, fn claim ->
      prepare_fixture()

      replace_once!(
        "README.md",
        "## Destination transaction boundary",
        "## Destination transaction boundary\n\n#{claim}"
      )

      assert_invalid!()
    end)

    prepare_fixture()
    replace_once!("README.md", "%ActionRef{", "%MissingActionRef{")
    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "README.md",
      "<!-- ash-replicant-destination-participant-example:start -->",
      "<!-- destination participant example marker removed -->"
    )

    assert_invalid!()
  end

  defp census_contract_probes do
    Enum.each(@census_doc_contracts, fn {path, heading, required_texts} ->
      prepare_fixture()
      replace_once!(path, heading, "#{heading} changed")
      assert_invalid!()

      prepare_fixture()
      replace_once!(path, heading, "<!--\n#{heading}\n-->")
      assert_invalid!()

      prepare_fixture()
      replace_once!(path, heading, "```text\n#{heading}\n```")
      assert_invalid!()

      Enum.each(required_texts, fn required ->
        prepare_fixture()
        replace_once!(path, required, "continuous census contract text removed")
        assert_invalid!()
      end)
    end)

    Enum.each(@census_source_contracts, fn {path, required} ->
      prepare_fixture()
      replace_once!(path, required, "# continuous census contract removed")
      assert_invalid!()
    end)
  end

  defp upgrade_contract_probes do
    Enum.each(@upgrade_doc_contracts, fn {path, heading, required_texts} ->
      unless is_nil(heading) do
        prepare_fixture()
        replace_once!(path, heading, "#{heading} changed")
        assert_invalid!()
      end

      Enum.each(required_texts, fn required ->
        prepare_fixture()
        replace_once!(path, required, "upgrade contract text removed")
        assert_invalid!()
      end)
    end)

    Enum.each(@upgrade_source_contracts, fn {path, required} ->
      prepare_fixture()
      replace_once!(path, required, "upgrade package contract removed")
      assert_invalid!()
    end)
  end

  defp mix_contract_probes do
    Enum.each(mix_contracts(), fn required ->
      prepare_fixture()
      replace_once!("mix.exs", required, "release dependency removed")
      assert_invalid!()
    end)

    prepare_fixture()

    replace_once!(
      "mix.exs",
      ~s(elixir: "~> 1.20.3"),
      ~s(elixir: "~> 1.18", release_contract_decoy: [elixir: "~> 1.20.3"])
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      ~s(@ash_requirement "#{@requirements.ash}"),
      ~s(@ash_requirement "#{@requirements.ash}"\n  @ash_requirement ">= 3.0.0 and < 4.0.0-0")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "\n  def cli, do:",
      """

        defoverridable project: 0

        def project do
          super()
          |> Keyword.put(:elixir, ">= 1.18.0")
        end

        def cli, do:
      """
      |> String.trim_trailing()
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:ash, @ash_requirement}",
      "{:ash, ash_requirement()}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      ~s(@replicant_requirement "#{@requirements.replicant}"),
      ~s(@replicant_requirement ">= 0.3.0 and < 2.0.0-0")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:replicant, @replicant_requirement}",
      "{:replicant, path: \"../replicant\"}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:ash_onetime, @ash_onetime_requirement}",
      "{:ash_onetime, \"~> 1.3\"}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:ash_onetime, @ash_onetime_requirement}",
      "{:ash_onetime, path: \"../ash_onetime\"}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:ash_cloak, @ash_cloak_requirement}",
      "{:ash_cloak, \"~> 0.1\"}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.6.0"),
      ~s("replicant": {:hex, :replicant, "0.3.1")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.6.0"),
      ~s("replicant": {:hex, :replicant, "1.1.0")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("postgrex": {:hex, :postgrex, "0.23.0"),
      ~s("postgrex": {:hex, :postgrex, "0.22.4")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/sink.ex",
      "@callback handle_session_identity",
      "@callback removed_session_identity"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/sink.ex",
      "def notify_slot_origin",
      "def removed_slot_origin_notification"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/connection.ex",
      "Replicant.Sink.accept_session_identity",
      "Replicant.Sink.removed_session_identity"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/connection.ex",
      "Replicant.Sink.accept_session_identity(state.sink, identity, %{",
      "# Replicant.Sink.accept_session_identity(state.sink, identity, %{\n         Replicant.Sink.removed_session_identity(state.sink, identity, %{"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/sink.ex",
      "@callback handle_slot_origin",
      "@callback removed_slot_origin"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/connection.ex",
      "reason: :checkpoint_unknown",
      "reason: :data_gap"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/telemetry.ex",
      "@meta_shapes %{",
      "@removed_meta_shapes %{"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/telemetry.ex",
      "def validate_measurements!",
      "def removed_measurement_validation!"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/telemetry.ex",
      ~s|validate_shapes!(meta, @meta_shapes, "metadata")|,
      ~s|removed_shape_guard!(meta, @meta_shapes, "metadata")|
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/snapshotter/incremental.ex",
      "@max_table_attempts 3",
      "@max_table_attempts 30"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/snapshotter/incremental.ex",
      "def keyed_retry_decision(attempts, _qualified, :window_reset)",
      "def removed_keyed_retry_decision(attempts, _qualified, :window_reset)"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/snapshotter/incremental.ex",
      "attempt >= @max_table_attempts",
      "attempt > @max_table_attempts"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/sink.ex",
      "binary() | nil | :backfill_pending",
      "binary() | nil"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/connection.ex",
      "def classify_progress({:ok, :backfill_pending})",
      "def removed_pending_progress_classification({:ok, :backfill_pending})"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/snapshotter/incremental.ex",
      "def classify_durable_progress(:backfill_pending, :sink_owned)",
      "def removed_pending_progress_classification(:backfill_pending, :sink_owned)"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/connection.ex",
      "Replicant.Sink.sink_kind(state.sink) != :append_log",
      "Replicant.Sink.sink_kind(state.sink) == :append_log"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "deps/replicant/lib/replicant/connection.ex",
      "Replicant.Sink.sink_kind(state.sink) != :append_log",
      "Replicant.Sink.sink_kind(state.sink) == :append_log"
    )

    with_env("ASH_REPLICANT_REPLICANT_VERSION", "latest", &assert_invalid!/0)

    prepare_fixture()

    File.write!(
      fixture_path("README.md"),
      File.read!(fixture_path("README.md")) <>
        "\nThis project does not support Replicant 1.2.3.\n"
    )

    assert_invalid!()
  end

  defp prepare_fixture do
    File.rm_rf!(@fixture_root)
    File.mkdir_p!(Path.join(@fixture_root, ".github/workflows"))

    for path <- [@workflow, @landing, @publish, @drift] do
      File.cp!(Path.join(@source_root, path), fixture_path(path))
    end

    for path <- [
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "AGENTS.md",
          "usage-rules.md",
          "docs/CHARTER.md",
          "docs/adr/0007-source-bound-checkpoint-effect-once.md",
          "docs/adr/0002-supported-runtime-and-dependencies.md",
          "docs/adr/0005-replicant-coordination.md",
          ".tool-versions",
          "config/config.exs",
          "mix.exs",
          "mix.lock",
          "scripts/test-release-checkers.sh",
          "scripts/audit-fixtures.sh",
          "scripts/assert-release-tree.sh",
          "scripts/publish_hex_artifacts.exs",
          "scripts/check-docs-archive.py",
          "scripts/release-notes.py",
          "scripts/build-docs-archive.exs",
          "scripts/build-release-docs.sh",
          "scripts/release_identity.exs",
          "scripts/release/published_packages.sha256",
          "scripts/test_publish_hex_artifacts.exs",
          "scripts/test_release_docs.py",
          "scripts/test-release-guards.sh",
          "scripts/verify-release.sh",
          "test/fixtures/release_checker/recorded.lock",
          "test/fixtures/upgrade_0_4_app/mix.exs",
          "test/integration/upgrade_checkpoint_test.exs",
          "locks/exact-floors.lock",
          "locks/latest-compatible.lock",
          @inventory,
          ".github/postgres.ref",
          ".github/postgres-lanes.json",
          "scripts/dependency-requirements.exs",
          "scripts/dependency_lanes.exs",
          "lib/ash_replicant/dependency_requirements.ex",
          ".github/actions/postgres/action.yml",
          @beam,
          @toolchain,
          "scripts/ci/postgres-lanes.sh",
          "scripts/test_postgres_lanes.py",
          "test/support/pg_old.dockerfile",
          "scripts/qualify.py",
          "lib/ash_replicant.ex",
          "lib/ash_replicant/sink.ex",
          "lib/ash_replicant/census.ex",
          "lib/ash_replicant/application.ex",
          "lib/ash_replicant/lease.ex",
          "lib/ash_replicant/pipeline_guard.ex",
          "lib/ash_replicant/pipeline_owner.ex",
          "lib/ash_replicant/telemetry.ex",
          "lib/ash_replicant/upgrade.ex",
          "lib/ash_replicant/upgrade/checkpoint.ex",
          "lib/mix/tasks/ash_replicant.upgrade.ex"
        ] do
      File.mkdir_p!(Path.dirname(fixture_path(path)))
      File.cp!(Path.join(@source_root, path), fixture_path(path))
    end

    for source <- Path.wildcard(Path.join(@source_root, "scripts/*.sh")) do
      destination = fixture_path(Path.relative_to(source, @source_root))
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
    end

    for path <- [
          "lib/replicant/session_identity.ex",
          "lib/replicant/sink.ex",
          "lib/replicant/connection.ex",
          "lib/replicant/telemetry.ex",
          "lib/replicant/snapshotter/incremental.ex"
        ] do
      destination = fixture_path(Path.join("deps/replicant", path))
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join([@source_root, "deps/replicant", path]), destination)
    end
  end

  defp insert_after_first_checkout!(addition) do
    replace_once!(
      @workflow,
      "      - uses: #{@checkout} # v7.0.1\n        with:\n          persist-credentials: false\n",
      "      - uses: #{@checkout} # v7.0.1\n        with:\n          persist-credentials: false\n#{addition}"
    )
  end

  defp mutate_job!(job, old, replacement, workflow \\ @workflow) do
    path = fixture_path(workflow)
    content = File.read!(path)
    regex = ~r/^  #{Regex.escape(job)}:\n.*?(?=^  [a-z][a-z0-9-]+:\n|\z)/ms

    case Regex.run(regex, content, return: :index) do
      [{start, length}] ->
        block = binary_part(content, start, length)
        replacement_block = replace_once(block, old, replacement)

        File.write!(
          path,
          binary_part(content, 0, start) <>
            replacement_block <>
            binary_part(content, start + length, byte_size(content) - start - length)
        )

      _ ->
        raise "job fixture anchor missing: #{job}"
    end
  end

  defp remove_run_command!(job, command) do
    mutate_run_step!(job, command, fn _step -> "" end)
  end

  defp mutate_run_step!(job, command, mutation) do
    path = fixture_path(@workflow)
    content = File.read!(path)
    direct = "      - run: #{command}\n"
    named = "        run: #{command}\n"

    multiline =
      "        run: |\n" <>
        (command
         |> String.split("\n")
         |> Enum.map_join("\n", fn
           "" -> ""
           line -> "          " <> line
         end)) <> "\n"

    job_regex = ~r/^  #{Regex.escape(job)}:\n.*?(?=^  [a-z][a-z0-9-]+:\n|\z)/ms
    [{job_start, job_length}] = Regex.run(job_regex, content, return: :index)
    job_block = binary_part(content, job_start, job_length)

    step =
      Regex.scan(~r/^      - .*?(?=^      - |^  [a-z][a-z0-9-]+:\n|\z)/ms, job_block)
      |> List.flatten()
      |> Enum.find(fn step ->
        String.contains?(step, direct) or String.contains?(step, named) or
          String.contains?(step, multiline)
      end)

    if step,
      do: mutate_job!(job, step, mutation.(step)),
      else: raise("run fixture anchor missing: #{command}")
  end

  defp swap_run_commands!(job, first, second) do
    marker = "__ASH_REPLICANT_COMMAND_SWAP__"
    mutate_job!(job, "      - run: #{first}\n", "      - run: #{marker}\n")
    mutate_job!(job, "      - run: #{second}\n", "      - run: #{first}\n")
    mutate_job!(job, "      - run: #{marker}\n", "      - run: #{second}\n")
  end

  defp replace_once!(path, old, replacement) do
    full_path = fixture_path(path)
    File.write!(full_path, full_path |> File.read!() |> replace_once(old, replacement))
  end

  defp replace_contract_text_once!(path, text, replacement) do
    full_path = fixture_path(path)
    content = File.read!(full_path)

    pattern =
      text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map_join("\\s+", &Regex.escape/1)
      |> Regex.compile!()

    case Regex.scan(pattern, content, return: :index) do
      [[{start, length}]] ->
        File.write!(
          full_path,
          binary_part(content, 0, start) <>
            replacement <>
            binary_part(content, start + length, byte_size(content) - start - length)
        )

      matches ->
        raise "fixture contract mutation anchor count invalid: #{length(matches)}"
    end
  end

  defp replace_once(content, old, replacement) do
    case :binary.matches(content, old) do
      [] -> raise "fixture mutation anchor missing: #{inspect(old)}"
      _matches -> String.replace(content, old, replacement, global: false)
    end
  end

  defp assert_valid! do
    Process.put({__MODULE__, :checks}, Process.get({__MODULE__, :checks}, 0) + 1)
    ReleaseContract.run(@fixture_root)
  end

  defp assert_invalid! do
    Process.put({__MODULE__, :checks}, Process.get({__MODULE__, :checks}, 0) + 1)

    for path <- [@workflow, @landing, @publish, @drift] do
      YamlElixir.read_from_file!(fixture_path(path))
    end

    ReleaseContract.run(@fixture_root)
    raise "release contract checker accepted a negative fixture"
  rescue
    ReleaseContractError -> :ok
  end

  defp with_env(key, value, function) do
    previous = System.get_env(key)

    try do
      if value do
        System.put_env(key, value)
      else
        System.delete_env(key)
      end

      function.()
    after
      if previous do
        System.put_env(key, previous)
      else
        System.delete_env(key)
      end
    end
  end

  defp fixture_path(path), do: Path.join(@fixture_root, path)
end

AshReplicant.ReleaseContractSelfTest.run()
