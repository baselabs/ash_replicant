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
      "env -u ASH_REPLICANT_TEST_URL scripts/run-structural-tests.sh --allow-excluded --exclude integration"
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
      "scripts/test-migration-drift-gate.sh",
      "scripts/run-structural-tests.sh --include integration",
      "scripts/run-structural-tests.sh test/integration --include integration",
      "mix dialyzer"
    ],
    "release-artifact" => [
      "env -u ASH_REPLICANT_ASH_VERSION mix deps.get",
      "mix deps.compile",
      "mix compile --warnings-as-errors",
      "elixir --version",
      "scripts/assert-runtime-version.sh",
      "scripts/assert-release-contract.sh",
      "mix docs --warnings-as-errors"
    ]
  }

  @doc_contracts [
    {"README.md", "### Supported foundation",
     [
       "- Elixir 1.20.3 on Erlang/OTP 29;",
       "- Ash `>= 3.31.3 and < 4.0.0-0` and AshPostgres 2.11.x;"
     ]},
    {"CONTRIBUTING.md", "## Prerequisites",
     [
       "- **Elixir 1.20.3** and **Erlang/OTP 29**",
       "- Ash `>= 3.31.3 and < 4.0.0-0`; selector-free development uses this public range"
     ]},
    {"AGENTS.md", "## Development workflow",
     [
       "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
         "`>= 3.31.3 and < 4.0.0-0`."
     ]}
  ]

  @checkout "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
  @mix_contracts [
    ~s(@ash_requirement ">= 3.31.3 and < 4.0.0-0"),
    ~s(elixir: "~> 1.20.3")
  ]

  def run do
    valid_fixture_probes()
    action_probes()
    command_probes()
    compatibility_probes()
    workflow_structure_probes()
    mix_contract_probes()
    documentation_probes()
    IO.puts("release contract self-tests: PASS")
  after
    File.rm_rf!(@fixture_root)
  end

  defp valid_fixture_probes do
    prepare_fixture()
    replace_once!(@workflow, "uses: #{@checkout}", "uses: \"#{@checkout}\"")
    assert_valid!()

    prepare_fixture()
    replace_once!(@workflow, "name: CI", "name: CI\n# Example text: uses: actions/setup-node@v4")
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
    mutate_job!("compatibility", "      ASH_REPLICANT_ASH_VERSION: ${{ matrix.selector }}\n", "")
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
      "      - name: Resolve and assert Ash version\n",
      "      - name: Resolve and assert Ash version\n        env:\n          ASH_REPLICANT_ASH_VERSION: latest\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          if [[ '${{ matrix.unlock }}' == 'true' ]]; then\n            mix deps.unlock ash\n          fi\n",
      "          mix deps.unlock ash\n          if [[ '${{ matrix.unlock }}' == 'true' ]]; then\n            :\n          fi\n"
    )

    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "          scripts/assert-dependency-version.sh ash '${{ matrix.requirement }}'\n",
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
    mutate_job!("compatibility", "            selector: \"\"\n", "            selector: latest\n")
    assert_invalid!()

    prepare_fixture()
    mutate_job!("compatibility", "            unlock: false\n", "            unlock: true\n")
    assert_invalid!()

    prepare_fixture()

    mutate_job!(
      "compatibility",
      "            requirement: \"== 3.31.3\"\n",
      "            requirement: \"#{">= 3.31.3"}\"\n"
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

    prepare_fixture()

    replace_once!(
      @workflow,
      "key: ${{ runner.os }}-ash-${{ matrix.label }}",
      "key: ${{ runner.os }}-ash-shared"
    )

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
        heading,
        "#{heading}\n\nThis package does not support Elixir 1.20.3 or Erlang/OTP 29."
      )

      assert_invalid!()

      prepare_fixture()

      replace_once!(
        path,
        heading,
        "#{heading}\n\nThis package does not support\nElixir 1.20.3 or Erlang/OTP 29."
      )

      assert_invalid!()
    end)
  end

  defp mix_contract_probes do
    Enum.each(@mix_contracts, fn required ->
      prepare_fixture()
      replace_once!("mix.exs", required, "release dependency removed")
      assert_invalid!()
    end)
  end

  defp prepare_fixture do
    File.rm_rf!(@fixture_root)
    File.mkdir_p!(Path.join(@fixture_root, ".github/workflows"))

    File.cp!(Path.join(@source_root, @workflow), fixture_path(@workflow))

    for path <- ["README.md", "CONTRIBUTING.md", "AGENTS.md", "mix.exs"] do
      File.cp!(Path.join(@source_root, path), fixture_path(path))
    end
  end

  defp insert_after_first_checkout!(addition) do
    replace_once!(
      @workflow,
      "      - uses: #{@checkout} # v4\n",
      "      - uses: #{@checkout} # v4\n#{addition}"
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
         |> Enum.map_join("\n", &("          " <> &1))) <> "\n"

    cond do
      String.contains?(content, direct) -> mutate_job!(job, direct, "")
      String.contains?(content, named) -> mutate_job!(job, named, "        run: :\n")
      String.contains?(content, multiline) -> mutate_job!(job, multiline, "        run: :\n")
      true -> raise "run fixture anchor missing: #{command}"
    end
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
    AshReplicant.ReleaseContract.run(@fixture_root)
    raise "release contract checker accepted a negative fixture"
  rescue
    AshReplicant.ReleaseContractError -> :ok
  end

  defp fixture_path(path), do: Path.join(@fixture_root, path)
end

AshReplicant.ReleaseContractSelfTest.run()
