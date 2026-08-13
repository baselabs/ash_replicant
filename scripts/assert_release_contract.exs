defmodule AshReplicant.ReleaseContractError do
  defexception [:message]
end

defmodule AshReplicant.ReleaseContract do
  @immutable_action ~r/\A[^@\s]+@[0-9a-f]{40}\z/
  @postgres_image "postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b"
  @ash_requirement ">= 3.31.3 and < 4.0.0-0"
  @checkout "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
  @setup_beam "erlef/setup-beam@0f75c29430f34bb5af4cce5e3b7f6a8860fca236"
  @cache "actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830"

  @setup_beam_inputs %{
    "elixir-version" => "${{ env.ELIXIR_VERSION }}",
    "otp-version" => "${{ env.OTP_VERSION }}"
  }

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

  @create_database """
  mix ecto.create
  mix ecto.migrate
  """

  @public_ash_check """
  env -u ASH_REPLICANT_ASH_VERSION mix run --no-start -e '
  requirement =
    Mix.Project.config()
    |> Keyword.fetch!(:deps)
    |> List.keyfind!(:ash, 0)
    |> elem(1)

  unless requirement == ">= 3.31.3 and < 4.0.0-0" do
    raise "unexpected public Ash requirement: \#{inspect(requirement)}"
  end'
  """

  @package_inspection """
  package_dir=$(mktemp -d)
  trap 'rm -rf "$package_dir"' EXIT
  env -u ASH_REPLICANT_ASH_VERSION mix hex.build --unpack --output "$package_dir"

  for required in lib .formatter.exs mix.exs README.md LICENSE NOTICE CHANGELOG.md usage-rules.md; do
    test -e "$package_dir/$required" || {
      echo "::error::Missing package path: $required"
      exit 1
    }
  done

  if find "$package_dir" -type d \\( -name test -o -name .forge -o -name _build \\) -print -quit | grep -q .; then
    echo "::error::Package contains test, Forge, or build residue"
    exit 1
  fi

  if find "$package_dir" -type f \\( -name '.env*' -o -name '*.pem' -o -name '*.key' \\) -print -quit | grep -q .; then
    echo "::error::Package contains a credential-shaped file"
    exit 1
  fi
  """

  @job_env %{
    "no-database" => %{"MIX_ENV" => "test"},
    "compatibility" => %{
      "MIX_ENV" => "test",
      "ASH_REPLICANT_ASH_VERSION" => "${{ matrix.selector }}",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres@localhost:5432/postgres"
    },
    "release-artifact" => %{"MIX_ENV" => "dev"}
  }

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

  @job_keys %{
    "no-database" => ~w(env name runs-on steps),
    "compatibility" => ~w(env name runs-on steps strategy),
    "release-artifact" => ~w(env name runs-on steps)
  }

  @job_steps %{
    "no-database" => [
      {:uses, @checkout, :absent},
      {:uses, @setup_beam, @setup_beam_inputs},
      {:uses, @cache,
       %{
         "path" => "deps\n_build\n",
         "key" =>
           "${{ runner.os }}-no-db-${{ env.OTP_VERSION }}-${{ env.ELIXIR_VERSION }}-${{ hashFiles('mix.lock') }}"
       }},
      {:run, "mix deps.get"},
      {:run, "mix deps.compile"},
      {:run, "mix format --check-formatted"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, "elixir --version"},
      {:run, "scripts/assert-runtime-version.sh"},
      {:run, "scripts/test-release-checkers.sh"},
      {:run, "scripts/test-release-contract.sh"},
      {:run, "mix credo --strict"},
      {:run, "mix deps.audit"},
      {:run,
       "env -u ASH_REPLICANT_TEST_URL scripts/run-structural-tests.sh --allow-excluded --exclude integration"}
    ],
    "compatibility" => [
      {:uses, @checkout, :absent},
      {:run, String.trim(@postgres_run)},
      {:uses, @setup_beam, @setup_beam_inputs},
      {:uses, @cache,
       %{
         "path" => "deps\n_build\npriv/plts\n",
         "key" =>
           "${{ runner.os }}-ash-${{ matrix.label }}-${{ env.OTP_VERSION }}-${{ env.ELIXIR_VERSION }}-${{ hashFiles('mix.lock') }}"
       }},
      {:run, String.trim(@resolve_ash)},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, "elixir --version"},
      {:run, "scripts/assert-runtime-version.sh"},
      {:run, "scripts/test-release-checkers.sh"},
      {:run, "scripts/assert-release-contract.sh"},
      {:run, "mix deps.audit"},
      {:run, String.trim(@create_database)},
      {:run, "scripts/test-migration-drift-gate.sh"},
      {:run, "scripts/run-structural-tests.sh --include integration"},
      {:run, "scripts/run-structural-tests.sh test/integration --include integration"},
      {:run, "mix dialyzer"}
    ],
    "release-artifact" => [
      {:uses, @checkout, :absent},
      {:uses, @setup_beam, @setup_beam_inputs},
      {:uses, @cache,
       %{
         "path" => "deps\n_build\n",
         "key" =>
           "${{ runner.os }}-release-${{ env.OTP_VERSION }}-${{ env.ELIXIR_VERSION }}-${{ hashFiles('mix.lock') }}"
       }},
      {:run, "env -u ASH_REPLICANT_ASH_VERSION mix deps.get"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, "elixir --version"},
      {:run, "scripts/assert-runtime-version.sh"},
      {:run, "scripts/assert-release-contract.sh"},
      {:run, String.trim(@public_ash_check)},
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

    assert(
      env == %{"ELIXIR_VERSION" => "1.20.3", "OTP_VERSION" => "29"},
      "CI runtime contract is incomplete"
    )
  end

  defp assert_actions(workflow) do
    actions = semantic_uses(workflow)

    assert(actions != [], "CI Action contract is incomplete")

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
    assert(not Map.has_key?(workflow, "defaults"), "CI workflow can override release shells")
  end

  defp assert_jobs(workflow) do
    jobs = Map.get(workflow, "jobs", %{})

    Enum.each(@job_steps, fn {name, expected_steps} ->
      job = jobs[name] || fail("CI release jobs are incomplete")

      assert(
        Enum.sort(Map.keys(job)) == Enum.sort(@job_keys[name]),
        "CI release job control is invalid"
      )

      assert(job["runs-on"] == "ubuntu-latest", "CI release runner is invalid")
      assert(job["env"] == @job_env[name], "CI release job environment is invalid")

      assert(
        Enum.map(Map.get(job, "steps", []), &step_signature/1) == expected_steps,
        "CI release step contract is invalid"
      )
    end)
  end

  defp step_signature(%{"run" => run} = step) when is_binary(run) do
    assert(Map.keys(step) -- ["name", "run"] == [], "CI release run step control is invalid")
    {:run, String.trim(run)}
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

  defp assert_cache_partition(workflow) do
    steps = get_in(workflow, ["jobs", "compatibility", "steps"]) || []

    assert(
      Enum.any?(steps, fn step ->
        step["uses"] == @cache and
          String.contains?(get_in(step, ["with", "key"]) || "", "${{ matrix.label }}")
      end),
      "CI compatibility cache contract is incomplete"
    )
  end

  defp assert_mix_contract(root) do
    ast = root |> Path.join("mix.exs") |> File.read!() |> Code.string_to_quoted!()
    body = mix_project_body(ast)
    projects = find_definitions(body, :def, :project)
    dependency_lists = find_definitions(body, :defp, :deps)
    ash_requirements = find_module_attributes(body, :ash_requirement)

    assert(
      exact_project_contract?(projects) and exact_dependency_contract?(dependency_lists) and
        ash_requirements == [@ash_requirement],
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
    case Enum.filter(dependencies, &match?({:ash, _requirement}, &1)) do
      [{:ash, {:ash_requirement, _, []}}] -> true
      _entries -> false
    end
  end

  defp exact_dependency_contract?(_dependency_lists), do: false

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
    |> String.replace(~r/[\s\p{Z}\p{Cf}]+/u, " ")
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
