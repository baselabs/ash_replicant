implementation =
  System.get_env("ASH_REPLICANT_RELEASE_CONTRACT_IMPLEMENTATION") ||
    Path.join(__DIR__, "assert_release_contract.exs")

Code.require_file(implementation)

defmodule AshReplicant.ReleaseContractSelfTest do
  alias AshReplicant.ReleaseContract
  alias AshReplicant.ReleaseContractError

  @source_root System.get_env("ASH_REPLICANT_RELEASE_CONTRACT_SOURCE_ROOT") || File.cwd!()
  @fixture_root Path.join(
                  System.tmp_dir!(),
                  "ash-replicant-release-contract-#{System.pid()}-#{System.unique_integer([:positive])}"
                )
  @workflow ".github/workflows/qualification.yml"
  @landing ".github/workflows/ci.yml"
  @pull_request ".github/workflows/pull-request.yml"
  @publish ".github/workflows/publish.yml"
  @inventory "scripts/qualification-jobs.json"
  @fail_late "${{ !cancelled() && steps.compile.outcome == 'success' }}"
  @publish_owner_condition "contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.actor) && contains(fromJSON('[\"corepay\",\"palermo-git\"]'), github.triggering_actor)"

  @postgres_run """
  docker run -d --name pg \\
    -e POSTGRES_HOST_AUTH_METHOD=trust \\
    -p 5432:5432 \\
    "$PG_IMAGE" \\
    -c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20
  scripts/wait-for-postgres.sh pg
  """

  @create_database """
  mix ecto.create
  mix ecto.migrate
  """

  # Mirrors assert_release_contract.exs's @performance_postgres_run (the
  # non-matrix performance job's literal pinned-digest PG16 step).
  @performance_postgres_run """
  docker run -d --name pg \\
    -e POSTGRES_HOST_AUTH_METHOD=trust \\
    -p 5432:5432 \\
    postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b \\
    -c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20
  scripts/wait-for-postgres.sh pg
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

  @job_commands %{
    "no-database" => [
      "scripts/assert-runtime-version.sh",
      "mix deps.get --check-locked",
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      "mix format --check-formatted",
      "elixir --version",
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
      "scripts/assert-runtime-version.sh",
      String.trim(@postgres_run),
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
      "scripts/assert-runtime-version.sh",
      String.trim(@performance_postgres_run),
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      String.trim(@create_database),
      "scripts/run-structural-tests.sh test/integration/performance_bounds_test.exs --include integration"
    ],
    "release-artifact" => [
      "scripts/assert-runtime-version.sh",
      "env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION mix deps.get --check-locked",
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      "elixir --version",
      "scripts/assert-release-contract.sh",
      String.trim(@public_dependency_check),
      "mix docs --warnings-as-errors",
      String.trim(@package_inspection)
    ]
  }

  @doc_contracts [
    {"README.md", "### Supported foundation",
     [
       "- Elixir 1.20.3 on Erlang/OTP 29;",
       "- Ash `>= 3.37.3 and < 4.0.0-0` (current lock 3.37.3);",
       "- AshPostgres `~> 2.13` (current lock 2.15.2 with AshSql 0.8.8; the latest-compatible cell tests the newest 2.x);",
       "- Spark `~> 2.7.0` (effective floor 2.7.6 through Ash; current lock 2.7.9);",
       "- Replicant `>= 1.4.0 and < 2.0.0-0` (current lock 1.5.1)",
       "- AshOnetime `>= 1.3.2 and < 2.0.0-0` (current lock 1.5.0)",
       "- AshCloak `>= 0.4.0 and < 1.0.0-0` (current lock 0.4.0"
     ]},
    {"CONTRIBUTING.md", "## Prerequisites",
     [
       "- **Elixir 1.20.3** and **Erlang/OTP 29**",
       "- Ash `>= 3.37.3 and < 4.0.0-0`; selector-free development uses this public range",
       "- Replicant `>= 1.4.0 and < 2.0.0-0` from Hex; the lock is 1.5.1.",
       "- AshCloak `>= 0.4.0 and < 1.0.0-0` from Hex; the current lock is 0.4.0 (the"
     ]},
    {"AGENTS.md", "## Development workflow",
     [
       "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
         "`>= 3.37.3 and < 4.0.0-0` (current lock 3.37.3) and Replicant\n" <>
         "`>= 1.4.0 and < 2.0.0-0` (current lock 1.5.1), plus\n" <>
         "AshOnetime `>= 1.3.2 and < 2.0.0-0` (current lock 1.5.0) and AshCloak\n" <>
         "`>= 0.4.0 and < 1.0.0-0` (current lock 0.4.0; releases below 0.4.0 carry\n" <>
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
  @named_separator_entities ~w(
    af ApplyFunction emsp13 emsp14 emsp ensp hairsp ic InvisibleComma
    InvisibleTimes it lrm MediumSpace nbsp NegativeMediumSpace NegativeThickSpace
    NegativeThinSpace NegativeVeryThinSpace NewLine NoBreak NonBreakingSpace numsp
    puncsp rlm shy Tab ThickSpace thinsp ThinSpace VeryThinSpace ZeroWidthSpace zwj zwnj
  )
  @mix_contracts [
    ~s(@ash_requirement ">= 3.37.3 and < 4.0.0-0"),
    ~s(@replicant_requirement ">= 1.4.0 and < 2.0.0-0"),
    ~s(@onetime_requirement ">= 1.3.2 and < 2.0.0-0"),
    ~s(elixir: "~> 1.20.3")
  ]

  def run do
    Process.put({__MODULE__, :checks}, 0)

    with_env("ASH_REPLICANT_REPLICANT_VERSION", nil, fn ->
      valid_fixture_probes()
      action_probes()
      action_input_probes()
      landing_and_fail_late_probes()
      qualification_probes()
      publish_probes()
      ci_requirement_probes()
      github_lookup_probes()
      decoder_job_probes()
      command_probes()
      compatibility_probes()
      packaging_selector_probes()
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
      "scripts/test-postgres-readiness.sh >/dev/null",
      "true"
    )

    assert_invalid!()
  end

  defp replicant_selector_probes do
    # The exact-floor CI cell re-resolves the lock to the selector's version
    # before the contract runs, so a floor-selector run is modeled by moving
    # the fixture lock TO the floor first (the lock is 1.5.1 now — the floor
    # cell's re-resolve is what puts 1.4.0 in it); any other lock under that
    # selector — stale in-window or below-floor — is rejected.
    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.5.1"),
      ~s("replicant": {:hex, :replicant, "1.4.0")
    )

    with_env("ASH_REPLICANT_REPLICANT_VERSION", "1.4.0", &assert_valid!/0)

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.5.1"),
      ~s("replicant": {:hex, :replicant, "1.3.1")
    )

    with_env("ASH_REPLICANT_REPLICANT_VERSION", "1.4.0", &assert_invalid!/0)

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.5.1"),
      ~s("replicant": {:hex, :replicant, "1.2.4")
    )

    with_env("ASH_REPLICANT_REPLICANT_VERSION", "1.4.0", &assert_invalid!/0)

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
      "jobs:\n  no-database:",
      """
      jobs:
        harmless-environment-key:
          runs-on: ubuntu-24.04
          env:
            uses: harmless-environment-value
          steps:
            - run: echo harmless

        no-database:
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
    replace_once!(@workflow, @setup_beam, @setup_beam <> "0")
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
      {@workflow, "release-artifact"},
      {@publish, "publish"}
    ]

    for {workflow, job} <- runtimes,
        {old, replacement} <- [
          {"          version-file: .tool-versions\n", ""},
          {"          version-file: .tool-versions\n",
           "          version-file: other.versions\n"},
          {"          version-file: .tool-versions\n", "          elixir-version: 1.20.3\n"},
          {"          version-file: .tool-versions\n", "          otp-version: 29.0.5\n"},
          {"          version-file: .tool-versions\n",
           "          version-file: .tool-versions\n          elixir-version: 1.20.3\n"},
          {"          version-type: strict\n", ""},
          {"          version-type: strict\n", "          version-type: loose\n"},
          {"      - run: scripts/assert-runtime-version.sh\n", ""},
          {"      - run: scripts/assert-runtime-version.sh\n",
           "      - run: scripts/assert-runtime-version.sh\n        if: false\n"}
        ] do
      prepare_fixture()
      mutate_job!(job, old, replacement, workflow)
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

      mutate_run_step!(job, "mix deps.compile", fn step ->
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
    # run, and kimosabe-land cannot land a commit CI never ran on.
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
          {"    if: always()\n", ""},
          {"    needs: [qualification]\n", "    needs: []\n"},
          {"    needs: [qualification]\n", ""},
          {"    timeout-minutes: 3\n", "    timeout-minutes: 10\n"},
          {"      actions: read\n", ""},
          {"          persist-credentials: false\n", "          persist-credentials: true\n"},
          {"      - run: python3 scripts/qualify.py\n", "      - run: true\n"},
          {"          GH_TOKEN: ${{ github.token }}\n", ""},
          {"          QUALIFICATION_RESULT: ${{ needs.qualification.result }}\n", ""},
          {"    uses: ./.github/workflows/qualification.yml\n",
           "    uses: ./.github/workflows/other.yml\n"}
        ] do
      prepare_fixture()
      replace_once!(@landing, old, replacement)
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
          timeout-minutes: 3
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

  defp publish_probes do
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
          {"          version-type: strict\n", ""},
          {"    timeout-minutes: 4\n", "    timeout-minutes: 30\n"},
          {"          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}\n",
           "          HEX_API_KEY: ${{ secrets.OTHER_KEY }}\n"}
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

      replace_once!(
        @publish,
        "        env:\n          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}\n",
        ""
      )

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

    prepare_fixture()

    replace_once!(
      @publish,
      "      - run: mix docs --warnings-as-errors\n",
      "      - run: mix docs --warnings-as-errors\n" <>
        "        env:\n          OTHER_KEY: ${{ secrets.OTHER_KEY }}\n"
    )

    assert_invalid!()
    prepare_fixture()

    replace_once!(
      @publish,
      "      - name: Build and inspect Hex package\n" <>
        "        run: |\n" <>
        "          env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION scripts/with-release-runtime.sh mix hex.build --output \"$RUNNER_TEMP/package.tar\"\n" <>
        "          scripts/inspect-release-package.sh \"$RUNNER_TEMP/package.tar\"\n",
      ""
    )

    assert_invalid!()

    for selector <- [
          "ASH_REPLICANT_ASH_VERSION",
          "ASH_REPLICANT_REPLICANT_VERSION",
          "ASH_REPLICANT_ONETIME_VERSION"
        ],
        command <- [
          "mix hex.build --output \"$RUNNER_TEMP/package.tar\"",
          "mix hex.publish --yes"
        ] do
      prepare_fixture()

      original =
        "env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION -u ASH_REPLICANT_ONETIME_VERSION scripts/with-release-runtime.sh #{command}"

      replace_once!(@publish, original, String.replace(original, "-u #{selector} ", ""))
      assert_invalid!()
    end
  end

  defp ci_requirement_probes do
    jobs = [
      {@workflow, "no-database", 47},
      {@workflow, "compatibility", 31},
      {@workflow, "performance", 6},
      {@workflow, "decoder-old-majors", 6},
      {@workflow, "release-artifact", 4},
      {@landing, "qualified", 3},
      {@publish, "publish", 4}
    ]

    for {workflow, job, timeout} <- jobs do
      for replacement <- ["", "    timeout-minutes: 1\n"] do
        prepare_fixture()
        mutate_job!(job, "    timeout-minutes: #{timeout}\n", replacement, workflow)
        assert_invalid!()
      end

      prepare_fixture()
      mutate_job!(job, "# Green run 44214414813:", "# No measurement:", workflow)
      assert_invalid!()

      prepare_fixture()
      mutate_job!(job, "persist-credentials: false", "persist-credentials: true", workflow)
      assert_invalid!()

      unless workflow == @landing do
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
    jobs:
      check:
        runs-on: ubuntu-24.04
        # Green run 44214414813: qualified 0m16s.
        timeout-minutes: 3
        steps:
          - uses: #{@checkout}
            with:
              persist-credentials: false
          - run: echo "$GITHUB_REF"
    """)

    assert_valid!()

    replace_once!(
      ".github/workflows/extra.yml",
      ~s(echo "$GITHUB_REF"),
      ~s(echo "${{ github.ref }}")
    )

    assert_invalid!()

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
      "          persist-credentials: false\n",
      "          persist-credentials: false\n" <> ref_step
    )

    assert_invalid!()
    prepare_fixture()
    replace_once!(@publish, " --unreleased\n", "\n")
    assert_invalid!()

    for {old, replacement} <- [
          {"0) release_tree_fail 'local tag already exists' ;;", "0) ;;"},
          {"*) release_tree_fail 'local tag lookup failed' ;;", "*) ;;"},
          {"0) release_tree_fail 'remote tag already exists' ;;", "0) ;;"},
          {"*) release_tree_fail 'remote tag lookup failed' ;;", "*) ;;"},
          {"404) ;;", "204) ;;"},
          {"200) release_tree_fail \"$label already exists\" ;;", "200) ;;"},
          {"*) release_tree_fail \"$label lookup failed\" ;;", "*) ;;"},
          {"|| release_tree_fail \"$label lookup failed\"", "|| return 0"},
          {"    assert_github_release_absent", "    :"},
          {"    assert_release_absent 'Hex release'", "    : 'Hex release'"},
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
          {"test/fixtures/upgrade_0_4_app/mix.exs", "EEF-CVE-2026-95105", "unreviewed-advisory"}
        ] do
      prepare_fixture()
      replace_once!(path, old, replacement)
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
          "scripts/assert-dependency-version.sh --newest spark '~> 2.7.0'"
        ] do
      prepare_fixture()
      mutate_job!("compatibility", "            #{command}\n", "            :\n")
      assert_invalid!()
    end

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          mix deps.get --check-locked\n",
      "          mix deps.get\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          - label: current-lock\n",
      "          - label: changed-lock\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            ash_selector: \"\"\n",
      "            ash_selector: latest\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            replicant_selector: \"\"\n",
      "            replicant_selector: latest\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            lockfile: mix.lock\n",
      "            lockfile: locks/latest-compatible.lock\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            lockfile: locks/exact-floors.lock\n",
      "            lockfile: mix.lock\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            ash_requirement: \"== 3.37.3\"\n",
      "            ash_requirement: \">= 3.37.3\"\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            replicant_requirement: \"== 1.4.0\"\n",
      "            replicant_requirement: \">= 1.4.0\"\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "      ASH_REPLICANT_ONETIME_VERSION: ${{ matrix.onetime_selector }}\n",
      ""
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            onetime_selector: \"1.3.2\"\n",
      "            onetime_selector: \"1.1.0\"\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            onetime_requirement: \"== 1.3.2\"\n",
      "            onetime_requirement: \">= 1.3.2\"\n"
    )

    assert_invalid!()
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

    prepare_fixture()

    mutate_job!(
      "release-artifact",
      "            ash_onetime: \">= 1.3.2 and < 2.0.0-0\",\n",
      "            ash_onetime: \">= 1.1.0 and < 2.0.0-0\",\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "release-artifact",
      "            ash_cloak: \">= 0.4.0 and < 1.0.0-0\"\n",
      "            ash_cloak: \"~> 0.1\"\n"
    )

    assert_invalid!()

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
                if ! diff -u scripts/release-package-files.txt <(cd "$package_dir" && find . \\( -type f -o -type l \\) | sed 's|^./||' | LC_ALL=C sort); then
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
      "permissions:\n",
      "defaults:\n  run:\n    shell: echo {0}\n\npermissions:\n"
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
          "    defaults:\n      run:\n        shell: echo {0}\n",
          "    needs: disabled-prerequisite\n"
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
    replace_once!(@workflow, "    runs-on: ubuntu-24.04\n", "    runs-on: self-hosted\n")
    assert_invalid!()

    # The image digests now ride the matrix (pg_image); mutating one digest
    # breaks the exact @matrix match — the pin's red direction. Anchored on
    # the PG17 cell (unique in the workflow; the PG16 ref appears 3x).
    prepare_fixture()

    replace_once!(
      @workflow,
      "pg_image: \"postgres:17@sha256:e38411452a464af89e5adadb8d223bf53b898d47d6ef918b2d58c08707350449\"",
      "pg_image: \"postgres:17\""
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
    Enum.each(@mix_contracts, fn required ->
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
      ~s(@ash_requirement ">= 3.37.3 and < 4.0.0-0"),
      ~s(@ash_requirement ">= 3.37.3 and < 4.0.0-0"\n  @ash_requirement ">= 3.0.0 and < 4.0.0-0")
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
      "{:ash, ash_requirement()}",
      "{:ash, String.replace(ash_requirement(), \">= 3.37.3\", \">= 3.0.0\")}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      ~s(@replicant_requirement ">= 1.4.0 and < 2.0.0-0"),
      ~s(@replicant_requirement ">= 0.3.0 and < 2.0.0-0")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:replicant, replicant_requirement()}",
      "{:replicant, path: \"../replicant\"}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:ash_onetime, onetime_requirement()}",
      "{:ash_onetime, \"~> 1.3\"}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:ash_onetime, onetime_requirement()}",
      "{:ash_onetime, path: \"../ash_onetime\"}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      "{:ash_cloak, \">= 0.4.0 and < 1.0.0-0\"}",
      "{:ash_cloak, \"~> 0.1\"}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.5.1"),
      ~s("replicant": {:hex, :replicant, "0.3.1")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.5.1"),
      ~s("replicant": {:hex, :replicant, "1.1.0")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("postgrex": {:hex, :postgrex, "0.22.4"),
      ~s("postgrex": {:hex, :postgrex, "0.22.3")
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

    for path <- [@workflow, @landing, @publish] do
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
          ".tool-versions",
          "mix.exs",
          "mix.lock",
          "scripts/test-release-checkers.sh",
          "scripts/audit-fixtures.sh",
          "scripts/assert-release-tree.sh",
          "scripts/test-release-guards.sh",
          "scripts/verify-release.sh",
          "test/fixtures/release_checker/recorded.lock",
          "test/fixtures/upgrade_0_4_app/mix.exs",
          "test/integration/upgrade_checkpoint_test.exs",
          "locks/exact-floors.lock",
          "locks/latest-compatible.lock",
          @inventory,
          "scripts/qualify.py",
          "lib/ash_replicant.ex",
          "lib/ash_replicant/sink.ex",
          "lib/ash_replicant/census.ex",
          "lib/ash_replicant/pipeline_owner.ex",
          "lib/ash_replicant/telemetry.ex",
          "lib/ash_replicant/upgrade.ex",
          "lib/ash_replicant/upgrade/checkpoint.ex",
          "lib/mix/tasks/ash_replicant.upgrade.ex"
        ] do
      File.mkdir_p!(Path.dirname(fixture_path(path)))
      File.cp!(Path.join(@source_root, path), fixture_path(path))
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
      Regex.scan(~r/^      - .*?(?=^      - |\z)/ms, job_block)
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

    for path <- [@workflow, @landing, @publish] do
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
