defmodule AshReplicant.ReleaseContractError do
  defexception [:message]
end

defmodule AshReplicant.ReleaseContract do
  @immutable_action ~r/\A[^@\s]+@[0-9a-f]{40}\z/
  @postgres_image "postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b"
  @ash_requirement ">= 3.31.3 and < 4.0.0-0"

  @postgres_run """
  docker run -d --name pg \\
    -e POSTGRES_HOST_AUTH_METHOD=trust \\
    -p 5432:5432 \\
    #{@postgres_image} \\
    -c wal_level=logical -c max_replication_slots=20 -c max_wal_senders=20
  for _ in $(seq 1 30); do
    docker exec pg pg_isready -U postgres && break
    sleep 1
  done
  docker exec pg pg_isready -U postgres || { docker logs pg; exit 1; }
  """

  @resolve_ash """
  if [[ '${{ matrix.unlock }}' == 'true' ]]; then
    mix deps.unlock ash
  fi
  mix deps.get
  mix deps ash
  scripts/assert-dependency-version.sh ash '${{ matrix.requirement }}'
  """

  @matrix [
    %{
      "label" => "floor-3.31.3",
      "selector" => "3.31.3",
      "unlock" => true,
      "requirement" => "== 3.31.3"
    },
    %{
      "label" => "current-lock",
      "selector" => "",
      "unlock" => false,
      "requirement" => @ash_requirement
    },
    %{
      "label" => "latest-3.x",
      "selector" => "latest",
      "unlock" => true,
      "requirement" => @ash_requirement
    }
  ]

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
      String.trim(@resolve_ash),
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
       "- Ash `#{@ash_requirement}` and AshPostgres 2.11.x;"
     ]},
    {"CONTRIBUTING.md", "## Prerequisites",
     [
       "- **Elixir 1.20.3** and **Erlang/OTP 29**",
       "- Ash `#{@ash_requirement}`; selector-free development uses this public range"
     ]},
    {"AGENTS.md", "## Development workflow",
     [
       "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
         "`#{@ash_requirement}`."
     ]}
  ]

  def run(root) do
    workflow = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/ci.yml"))

    assert_runtime(workflow)
    assert_actions(workflow)
    assert_workflow_controls(workflow)
    assert_jobs(workflow)
    assert_compatibility(workflow)
    assert_cache_partition(workflow)
    assert_mix_contract(root)
    assert_docs(root)
  rescue
    _error in [YamlElixir.ParsingError, File.Error] -> fail("release contract input is invalid")
  end

  def run_cli(root) do
    run(root)
  rescue
    error in AshReplicant.ReleaseContractError ->
      IO.puts(:stderr, error.message)
      System.halt(1)
  end

  defp assert_runtime(workflow) do
    env = Map.get(workflow, "env", %{})
    assert(env["ELIXIR_VERSION"] == "1.20.3", "CI runtime contract is incomplete")
    assert(to_string(env["OTP_VERSION"]) == "29", "CI runtime contract is incomplete")
  end

  defp assert_actions(workflow) do
    actions = collect_uses(workflow)

    assert(actions != [], "CI Action contract is incomplete")

    assert(
      Enum.all?(actions, fn action ->
        is_binary(action) and
          (String.starts_with?(action, "./") or Regex.match?(@immutable_action, action))
      end),
      "CI contains a non-immutable Action reference"
    )
  end

  defp collect_uses(value) when is_list(value), do: Enum.flat_map(value, &collect_uses/1)

  defp collect_uses(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"uses", action} -> [action | collect_uses(action)]
      {_key, nested} -> collect_uses(nested)
    end)
  end

  defp collect_uses(_value), do: []

  defp assert_workflow_controls(workflow) do
    assert(not Map.has_key?(workflow, "defaults"), "CI workflow can override release shells")
  end

  defp assert_jobs(workflow) do
    jobs = Map.get(workflow, "jobs", %{})

    Enum.each(@job_commands, fn {name, commands} ->
      job = jobs[name] || fail("CI release jobs are incomplete")

      for key <- ["if", "needs", "continue-on-error", "defaults"] do
        assert(not Map.has_key?(job, key), "CI release job control is invalid")
      end

      assert(job["runs-on"] == "ubuntu-latest", "CI release runner is invalid")

      positions = Enum.map(commands, &dedicated_run_position(job, &1))

      assert(Enum.all?(positions, &is_integer/1), "CI release gate step is incomplete")

      assert(
        positions == Enum.sort(positions) and positions == Enum.uniq(positions),
        "CI release gate ordering is invalid"
      )
    end)
  end

  defp dedicated_run_position(job, command) do
    job
    |> Map.get("steps", [])
    |> Enum.with_index()
    |> Enum.find_value(fn {step, index} ->
      run = step |> Map.get("run", "") |> String.trim()

      controls_clear? =
        Enum.all?(["if", "continue-on-error", "shell", "env"], &(not Map.has_key?(step, &1)))

      if run == command and controls_clear?,
        do: index
    end)
  end

  defp assert_compatibility(workflow) do
    job = get_in(workflow, ["jobs", "compatibility"]) || fail("CI compatibility job is missing")
    env = Map.get(job, "env", %{})
    rows = get_in(job, ["strategy", "matrix", "include"]) || []

    assert(
      env["ASH_REPLICANT_ASH_VERSION"] == "${{ matrix.selector }}",
      "CI Ash selector binding is invalid"
    )

    assert(rows == @matrix, "CI Ash compatibility matrix is invalid")
  end

  defp assert_cache_partition(workflow) do
    steps = get_in(workflow, ["jobs", "compatibility", "steps"]) || []

    assert(
      Enum.any?(steps, fn step ->
        step["uses"] == "actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830" and
          String.contains?(get_in(step, ["with", "key"]) || "", "${{ matrix.label }}")
      end),
      "CI compatibility cache contract is incomplete"
    )
  end

  defp assert_mix_contract(root) do
    ast = root |> Path.join("mix.exs") |> File.read!() |> Code.string_to_quoted!()

    {_ast, state} =
      Macro.prewalk(ast, %{ash: false, elixir: false}, fn
        {:@, _, [{:ash_requirement, _, [@ash_requirement]}]} = node, state ->
          {node, %{state | ash: true}}

        {:elixir, "~> 1.20.3"} = node, state ->
          {node, %{state | elixir: true}}

        node, state ->
          {node, state}
      end)

    assert(state == %{ash: true, elixir: true}, "Mix release contract is incomplete")
  rescue
    _error in [SyntaxError, TokenMissingError] -> fail("Mix release contract is invalid")
  end

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
          ~r/(?:unsupported release foundation|does(?:\s+not|n't)\s+support[^\n]*(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.31\.3)|(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.31\.3)[^\n]*\bnot supported\b)/i,
          normalize_markdown(visible)
        ),
        "published runtime or dependency contract is contradictory"
      )
    end)
  end

  defp visible_markdown(content) do
    content
    |> then(&Regex.replace(~r/<!--.*?-->/s, &1, ""))
    |> String.split("\n")
    |> remove_code_lines()
    |> Enum.join("\n")
  end

  defp remove_code_lines(lines) do
    {visible, _fence} = Enum.reduce(lines, {[], nil}, &reduce_code_line/2)

    Enum.reverse(visible)
  end

  defp reduce_code_line(line, {visible, fence}) do
    case {fence, fence_marker(line)} do
      {nil, nil} ->
        reduce_visible_line(line, visible)

      {nil, marker} ->
        {visible, marker}

      {{character, length}, {character, closing_length}} when closing_length >= length ->
        {visible, nil}

      {_fence, _marker} ->
        {visible, fence}
    end
  end

  defp reduce_visible_line(line, visible) do
    if String.starts_with?(line, "    ") or String.starts_with?(line, "\t"),
      do: {visible, nil},
      else: {[line | visible], nil}
  end

  defp fence_marker(line) do
    case Regex.run(~r/^\s*(`{3,}|~{3,})/, line) do
      [_, marker] -> {String.first(marker), String.length(marker)}
      _ -> nil
    end
  end

  defp normalize_markdown(content) do
    content
    |> String.replace(~r/\s+/, " ")
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
    raise AshReplicant.ReleaseContractError, message: message
  end
end
