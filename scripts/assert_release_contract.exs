defmodule AshReplicant.ReleaseContractError do
  defexception [:message]
end

defmodule AshReplicant.ReleaseContract do
  @immutable_action ~r/\A[^@\s]+@[0-9a-f]{40}\z/
  @postgres_image "postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b"
  @ash_requirement ">= 3.31.3 and < 4.0.0-0"
  @replicant_requirement ">= 1.2.3 and < 2.0.0-0"
  @checkout "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
  @setup_beam "erlef/setup-beam@0f75c29430f34bb5af4cce5e3b7f6a8860fca236"
  @cache "actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830"
  @participant_example_start "<!-- ash-replicant-destination-participant-example:start -->"
  @participant_example_end "<!-- ash-replicant-destination-participant-example:end -->"

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

  @resolve_dependencies """
  if [[ '${{ matrix.ash_unlock }}' == 'true' ]]; then
    mix deps.unlock ash
  fi
  if [[ '${{ matrix.replicant_unlock }}' == 'true' ]]; then
    mix deps.unlock replicant
  fi
  mix deps.get
  mix deps ash
  mix deps replicant
  scripts/assert-dependency-version.sh ash '${{ matrix.ash_requirement }}'
  scripts/assert-dependency-version.sh replicant '${{ matrix.replicant_requirement }}'
  """

  @create_database """
  mix ecto.create
  mix ecto.migrate
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

  if test -e "$package_dir/priv"; then
    echo "::error::Package contains private migrations"
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
      "ASH_REPLICANT_ASH_VERSION" => "${{ matrix.ash_selector }}",
      "ASH_REPLICANT_REPLICANT_VERSION" => "${{ matrix.replicant_selector }}",
      "ASH_REPLICANT_TEST_URL" => "postgres://postgres@localhost:5432/postgres"
    },
    "release-artifact" => %{"MIX_ENV" => "dev"}
  }

  @matrix [
    %{
      "label" => "exact-floors",
      "ash_selector" => "3.31.3",
      "ash_unlock" => true,
      "ash_requirement" => "== 3.31.3",
      "replicant_selector" => "1.2.3",
      "replicant_unlock" => true,
      "replicant_requirement" => "== 1.2.3"
    },
    %{
      "label" => "current-lock",
      "ash_selector" => "",
      "ash_unlock" => false,
      "ash_requirement" => @ash_requirement,
      "replicant_selector" => "",
      "replicant_unlock" => false,
      "replicant_requirement" => @replicant_requirement
    },
    %{
      "label" => "latest-compatible",
      "ash_selector" => "latest",
      "ash_unlock" => true,
      "ash_requirement" => @ash_requirement,
      "replicant_selector" => "latest",
      "replicant_unlock" => true,
      "replicant_requirement" => @replicant_requirement
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
      {:run, String.trim(@resolve_dependencies)},
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
      {:run, "env -u ASH_REPLICANT_ASH_VERSION -u ASH_REPLICANT_REPLICANT_VERSION mix deps.get"},
      {:run, "mix deps.compile"},
      {:run, "mix compile --warnings-as-errors"},
      {:run, "elixir --version"},
      {:run, "scripts/assert-runtime-version.sh"},
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
       "- Ash `#{@ash_requirement}` and AshPostgres 2.11.x;",
       "- Replicant `#{@replicant_requirement}` (current release-candidate lock 1.2.3)"
     ]},
    {"CONTRIBUTING.md", "## Prerequisites",
     [
       "- **Elixir 1.20.3** and **Erlang/OTP 29**",
       "- Ash `#{@ash_requirement}`; selector-free development uses this public range",
       "- Replicant `#{@replicant_requirement}` from Hex; the release-candidate lock is 1.2.3."
     ]},
    {"AGENTS.md", "## Development workflow",
     [
       "The supported release foundation is Elixir 1.20.3 on Erlang/OTP 29 with Ash\n" <>
         "`#{@ash_requirement}` and Replicant\n" <>
         "`#{@replicant_requirement}` (current release-candidate lock 1.2.3)."
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

  # The exact package-inspection bytes the contract enforces on the workflow.
  # The package-inspection self-test executes these bytes against staged
  # fixtures (leak + clean), so the shipped predicate is proven to REJECT, not
  # merely to exist as text.
  @doc false
  def package_inspection, do: @package_inspection

  def run(root) do
    workflow = YamlElixir.read_from_file!(Path.join(root, ".github/workflows/ci.yml"))

    assert_runtime(workflow)
    assert_actions(workflow)
    assert_workflow_controls(workflow)
    assert_jobs(workflow)
    assert_compatibility(workflow)
    assert_cache_partition(workflow)
    assert_mix_contract(root)
    assert_replicant_contract(root)
    assert_checker_wiring(root)
    assert_docs(root)
    assert_b1_docs(root)
    assert_b1_examples(root)
    assert_no_b1_positive_contradictions(root)
    assert_b5_absence_scans(root)
  rescue
    _error in [YamlElixir.ParsingError, File.Error] -> fail("release contract input is invalid")
  end

  # U3/B5 (D6): the durable effect ledger stays ABSENT from lib/ — the only
  # permitted occurrences are the removed-option fail-closed compile error
  # (exactly the two allowlisted lines in sink.ex) — and no secret-shaped
  # literal ships in lib/.
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

    allowed_hits =
      MapSet.new([
        {sink_path,
         "# removed `apply_ledger`) must surface as a compile-time failure on the host,"},
        {sink_path, "\"(apply_ledger was removed; a removed option must not silently no-op)\""}
      ])

    actual_hits = MapSet.new(ledger_hits, fn {path, _line, content} -> {path, content} end)

    assert(
      length(ledger_hits) == 2 and actual_hits == allowed_hits,
      "apply_ledger must appear ONLY in the two exact fail-closed lines of lib/ash_replicant/sink.ex, found: #{inspect(ledger_hits)}"
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
  rescue
    _error in [File.Error] -> fail("AshOnetime migration checker wiring input is invalid")
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
    replicant_requirements = find_module_attributes(body, :replicant_requirement)

    assert(
      exact_project_contract?(projects) and exact_dependency_contract?(dependency_lists) and
        ash_requirements == [@ash_requirement] and
        replicant_requirements == [@replicant_requirement],
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
           _dependency -> false
         end) do
      [
        {:ash, {:ash_requirement, _, []}},
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
        "1.2.3"

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
          ~r/(?:unsupported release foundation|does(?:[\s\p{Cf}]+not|n't)[\s\p{Cf}]+support[\s\p{Cf}]*(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.31\.3|Replicant 1(?:\.x|\.\d+(?:\.\d+)?))|(?:Elixir 1\.20\.3|Erlang\/OTP 29|Ash 3\.31\.3|Replicant 1(?:\.x|\.\d+(?:\.\d+)?))[\s\p{Cf}]*(?:is[\s\p{Cf}]+)?not[\s\p{Cf}]+supported)/iu,
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
    raise AshReplicant.ReleaseContractError, message: message
  end
end
