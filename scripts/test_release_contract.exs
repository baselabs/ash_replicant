implementation =
  System.get_env("ASH_REPLICANT_RELEASE_CONTRACT_IMPLEMENTATION") ||
    Path.join(__DIR__, "assert_release_contract.exs")

Code.require_file(implementation)

defmodule AshReplicant.ReleaseContractSelfTest do
  @source_root System.get_env("ASH_REPLICANT_RELEASE_CONTRACT_SOURCE_ROOT") || File.cwd!()
  @fixture_root Path.join(
                  System.tmp_dir!(),
                  "ash-replicant-release-contract-#{System.pid()}-#{System.unique_integer([:positive])}"
                )
  @workflow ".github/workflows/ci.yml"

  @postgres_run """
  docker run -d --name pg \\
    -e POSTGRES_HOST_AUTH_METHOD=trust \\
    -p 5432:5432 \\
    postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b \\
    -c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20
  for _ in $(seq 1 30); do
    docker exec pg pg_isready -U postgres && break
    sleep 1
  done
  docker exec pg pg_isready -U postgres || { docker logs pg; exit 1; }
  """

  @create_database """
  mix ecto.create
  mix ecto.migrate
  """

  # Mirrors assert_release_contract.exs's @mutation_gates_run byte-for-byte
  # (the three-file pin set: ci.yml + both contract scripts move TOGETHER).
  @mutation_gates_run """
  BASE="${GITHUB_EVENT_BEFORE:-}"
  if [ -n "$BASE" ] && [ "$BASE" != "0000000000000000000000000000000000000000" ] \\
     && git fetch --no-tags --quiet origin "$BASE"; then
    scripts/run-mutation-gates.py --diff-base "$BASE"
  else
    scripts/run-mutation-gates.py
  fi
  """

  @public_dependency_check """
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION mix run --no-start -e '
  deps = Mix.Project.config() |> Keyword.fetch!(:deps)

  expected = %{
    ash: ">= 3.31.3 and < 4.0.0-0",
    replicant: ">= 1.2.3 and < 2.0.0-0"
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
  env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION mix hex.build --unpack --output "$package_dir"

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
  """

  @job_commands %{
    "no-database" => [
      "mix deps.get",
      "mix deps.compile",
      "mix format --check-formatted",
      "mix compile --warnings-as-errors",
      "elixir --version",
      "scripts/assert-runtime-version.sh",
      "scripts/test-release-checkers.sh",
      "scripts/test-release-contract.sh",
      "mix credo --strict",
      "mix deps.audit",
      "env -u ASH_REPLICANT_TEST_URL scripts/run-structural-tests.sh --allow-excluded --exclude integration",
      String.trim(@mutation_gates_run)
    ],
    "compatibility" => [
      String.trim(@postgres_run),
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      "elixir --version",
      "scripts/assert-runtime-version.sh",
      "scripts/test-release-checkers.sh",
      "scripts/assert-release-contract.sh",
      "mix deps.audit",
      String.trim(@create_database),
      "scripts/test-migration-drift-gate.sh",
      "scripts/run-structural-tests.sh --include integration",
      "scripts/run-structural-tests.sh test/integration --include integration",
      "mix dialyzer"
    ],
    "release-artifact" => [
      "env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION mix deps.get",
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      "elixir --version",
      "scripts/assert-runtime-version.sh",
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
       "- Ash `>= 3.31.3 and < 4.0.0-0` and AshPostgres 2.11.x;",
       "- Replicant `>= 1.2.3 and < 2.0.0-0` (current release-candidate lock 1.2.3)"
     ]},
    {"CONTRIBUTING.md", "## Prerequisites",
     [
       "- **Elixir 1.20.3** and **Erlang/OTP 29**",
       "- Ash `>= 3.31.3 and < 4.0.0-0`; selector-free development uses this public range",
       "- Replicant `>= 1.2.3 and < 2.0.0-0` from Hex; the release-candidate lock is 1.2.3."
     ]},
    {"AGENTS.md", "## Development workflow",
     [
       "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
         "`>= 3.31.3 and < 4.0.0-0` and Replicant\n" <>
         "`>= 1.2.3 and < 2.0.0-0` (current release-candidate lock 1.2.3)."
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
    {"CHANGELOG.md", "### Added", ["**Guarded 0.4.0 to 1.0.0 package upgrade and rollback.**"]}
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
  @setup_beam "erlef/setup-beam@0f75c29430f34bb5af4cce5e3b7f6a8860fca236"
  @cache "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
  @named_separator_entities ~w(
    af ApplyFunction emsp13 emsp14 emsp ensp hairsp ic InvisibleComma
    InvisibleTimes it lrm MediumSpace nbsp NegativeMediumSpace NegativeThickSpace
    NegativeThinSpace NegativeVeryThinSpace NewLine NoBreak NonBreakingSpace numsp
    puncsp rlm shy Tab ThickSpace thinsp ThinSpace VeryThinSpace ZeroWidthSpace zwj zwnj
  )
  @mix_contracts [
    ~s(@ash_requirement ">= 3.31.3 and < 4.0.0-0"),
    ~s(@replicant_requirement ">= 1.2.3 and < 2.0.0-0"),
    ~s(elixir: "~> 1.20.3")
  ]

  def run do
    with_env("ASH_REPLICANT_REPLICANT_VERSION", nil, fn ->
      valid_fixture_probes()
      action_probes()
      action_input_probes()
      command_probes()
      compatibility_probes()
      workflow_structure_probes()
      checker_wiring_probes()
      mix_contract_probes()
      replicant_selector_probes()
      documentation_probes()
      b1_documentation_probes()
      census_contract_probes()
      upgrade_contract_probes()
    end)

    IO.puts("release contract self-tests: PASS")
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
  end

  defp replicant_selector_probes do
    prepare_fixture()
    with_env("ASH_REPLICANT_REPLICANT_VERSION", "1.2.3", &assert_valid!/0)

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.2.3"),
      ~s("replicant": {:hex, :replicant, "1.2.2")
    )

    with_env("ASH_REPLICANT_REPLICANT_VERSION", "1.2.3", &assert_invalid!/0)

    prepare_fixture()
    with_env("ASH_REPLICANT_REPLICANT_VERSION", "latest", &assert_valid!/0)
  end

  defp valid_fixture_probes do
    prepare_fixture()
    replace_once!(@workflow, "uses: #{@checkout}", "uses: \"#{@checkout}\"")
    assert_valid!()

    prepare_fixture()
    replace_once!(@workflow, "name: CI", "name: CI\n# Example text: uses: actions/setup-node@v4")
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
          runs-on: ubuntu-latest
          env:
            uses: harmless-environment-value
          steps:
            - run: echo harmless

        no-database:
      """
      |> String.trim_trailing()
    )

    assert_valid!()

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

    for action <- [@setup_beam, @cache] do
      prepare_fixture()
      replace_once!(@workflow, action, action <> "0")
      assert_invalid!()
    end

    prepare_fixture()
    insert_after_first_checkout!("      - uses: #{@checkout} # unexpected duplicate\n")
    assert_invalid!()
  end

  defp action_input_probes do
    jobs = ["no-database", "compatibility", "release-artifact"]

    Enum.each(jobs, fn job ->
      prepare_fixture()

      mutate_job!(
        job,
        "      - uses: #{@checkout} # v7.0.1\n",
        "      - uses: #{@checkout} # v7.0.1\n        with:\n          ref: stale-gate-revision\n"
      )

      assert_invalid!()
    end)

    for job <- jobs,
        {input, environment, replacement} <- [
          {"elixir-version", "ELIXIR_VERSION", "1.18.0"},
          {"otp-version", "OTP_VERSION", "28"}
        ] do
      prepare_fixture()

      mutate_job!(
        job,
        "          #{input}: ${{ env.#{environment} }}\n",
        "          #{input}: #{replacement}\n"
      )

      assert_invalid!()
    end

    Enum.each(jobs, fn job ->
      prepare_fixture()

      mutate_job!(
        job,
        "          otp-version: ${{ env.OTP_VERSION }}\n",
        "          otp-version: ${{ env.OTP_VERSION }}\n          version-type: strict\n"
      )

      assert_invalid!()

      prepare_fixture()

      mutate_job!(
        job,
        "          key: ",
        "          restore-keys: stale-gate-bytes\n          key: "
      )

      assert_invalid!()
    end)

    for {job, path, key} <- [
          {"no-database", "deps\n            _build",
           "${{ runner.os }}-no-db-${{ env.OTP_VERSION }}-${{ env.ELIXIR_VERSION }}-${{ hashFiles('mix.lock') }}"},
          {"compatibility", "deps\n            _build\n            priv/plts",
           "${{ runner.os }}-ash-${{ matrix.label }}-${{ env.OTP_VERSION }}-${{ env.ELIXIR_VERSION }}-${{ hashFiles('mix.lock') }}"},
          {"release-artifact", "deps\n            _build",
           "${{ runner.os }}-release-${{ env.OTP_VERSION }}-${{ env.ELIXIR_VERSION }}-${{ hashFiles('mix.lock') }}"}
        ] do
      prepare_fixture()

      mutate_job!(
        job,
        "          path: |\n            #{path}\n",
        "          path: |\n            #{path}\n            scripts\n            .github/workflows\n"
      )

      assert_invalid!()

      prepare_fixture()
      mutate_job!(job, "          key: #{key}\n", "          key: #{key}-stale\n")
      assert_invalid!()
    end
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
      mutate_job!("no-database", "      - run: #{command}\n", replacement)
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
      "          mix deps.get\n",
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
      "      - name: Resolve and assert dependency versions\n",
      "      - name: Resolve and assert dependency versions\n        env:\n          ASH_REPLICANT_ASH_VERSION: latest\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          if [[ '${{ matrix.ash_unlock }}' == 'true' ]]; then\n            mix deps.unlock ash\n          fi\n",
      "          mix deps.unlock ash\n          if [[ '${{ matrix.ash_unlock }}' == 'true' ]]; then\n            :\n          fi\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          if [[ '${{ matrix.replicant_unlock }}' == 'true' ]]; then\n            mix deps.unlock replicant\n          fi\n",
      "          mix deps.unlock replicant\n          if [[ '${{ matrix.replicant_unlock }}' == 'true' ]]; then\n            :\n          fi\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          scripts/assert-dependency-version.sh ash '${{ matrix.ash_requirement }}'\n",
      "          :\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          scripts/assert-dependency-version.sh replicant '${{ matrix.replicant_requirement }}'\n",
      "          :\n"
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
      "            ash_unlock: false\n",
      "            ash_unlock: true\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            replicant_unlock: false\n",
      "            replicant_unlock: true\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            ash_requirement: \"== 3.31.3\"\n",
      "            ash_requirement: \">= 3.31.3\"\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            replicant_requirement: \"== 1.2.3\"\n",
      "            replicant_requirement: \">= 1.2.3\"\n"
    )

    assert_invalid!()
  end

  defp workflow_structure_probes do
    prepare_fixture()

    replace_once!(
      @workflow,
      "env:\n  ELIXIR_VERSION:",
      "defaults:\n  run:\n    shell: echo {0}\n\nenv:\n  ELIXIR_VERSION:"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      @workflow,
      "env:\n  ELIXIR_VERSION:",
      "env:\n  BASH_ENV: /tmp/release-bypass\n  ELIXIR_VERSION:"
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
        "    runs-on: ubuntu-latest\n",
        """
            runs-on: ubuntu-latest
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
      mutate_job!("no-database", "      - run: scripts/test-release-contract.sh\n", replacement)
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
    replace_once!(@workflow, "    runs-on: ubuntu-latest\n", "    runs-on: self-hosted\n")
    assert_invalid!()

    prepare_fixture()

    replace_once!(
      @workflow,
      "postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b \\",
      "postgres:16 \\\n          # postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b"
    )

    assert_invalid!()

    prepare_fixture()
    replace_once!(@workflow, "  OTP_VERSION: \"29\"", "  OTP_VERSION: \"28\"")
    assert_invalid!()

    prepare_fixture()
    replace_once!(@workflow, "  ELIXIR_VERSION: \"1.20.3\"", "  ELIXIR_VERSION: \"1.19.5\"")
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
      prepare_fixture()
      replace_once!(path, heading, "#{heading} changed")
      assert_invalid!()

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
      ~s(@ash_requirement ">= 3.31.3 and < 4.0.0-0"),
      ~s(@ash_requirement ">= 3.31.3 and < 4.0.0-0"\n  @ash_requirement ">= 3.0.0 and < 4.0.0-0")
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
      "{:ash, String.replace(ash_requirement(), \">= 3.31.3\", \">= 3.0.0\")}"
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.exs",
      ~s(@replicant_requirement ">= 1.2.3 and < 2.0.0-0"),
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
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.2.3"),
      ~s("replicant": {:hex, :replicant, "0.3.1")
    )

    assert_invalid!()

    prepare_fixture()

    replace_once!(
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.2.3"),
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
      "mix.lock",
      ~s("replicant": {:hex, :replicant, "1.2.3"),
      ~s("replicant": {:hex, :replicant, "1.2.4")
    )

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

    File.cp!(Path.join(@source_root, @workflow), fixture_path(@workflow))

    for path <- [
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "AGENTS.md",
          "usage-rules.md",
          "docs/CHARTER.md",
          "docs/adr/0007-source-bound-checkpoint-effect-once.md",
          "mix.exs",
          "mix.lock",
          "scripts/test-release-checkers.sh",
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
      "      - uses: #{@checkout} # v7.0.1\n",
      "      - uses: #{@checkout} # v7.0.1\n#{addition}"
    )
  end

  defp mutate_job!(job, old, replacement) do
    path = fixture_path(@workflow)
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

    if step, do: mutate_job!(job, step, ""), else: raise("run fixture anchor missing: #{command}")
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
    AshReplicant.ReleaseContract.run(@fixture_root)
  end

  defp assert_invalid! do
    YamlElixir.read_from_file!(fixture_path(@workflow))
    AshReplicant.ReleaseContract.run(@fixture_root)
    raise "release contract checker accepted a negative fixture"
  rescue
    AshReplicant.ReleaseContractError -> :ok
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
