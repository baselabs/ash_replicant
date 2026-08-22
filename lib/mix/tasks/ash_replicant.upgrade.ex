defmodule Mix.Tasks.AshReplicant.Upgrade.Docs do
  @moduledoc false

  def short_doc, do: "Upgrade AshReplicant 0.4.0 checkpoint and sink state to 1.0.0"

  def example do
    ~s(mix ash_replicant.upgrade 0.4.0 1.0.0 --repo MyApp.Repo ) <>
      ~s(--destination-database destination_db --binding ) <>
      ~s|'{"sink":"MyApp.Sink","pipeline":"MyApp.Replicant.Pipeline",| <>
      ~s|"source_system_id":"...","source_database":"..."}'|
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshReplicant.Upgrade do
    @shortdoc Mix.Tasks.AshReplicant.Upgrade.Docs.short_doc()
    @moduledoc """
    #{@shortdoc}

    Generates one guarded, reversible host migration and removes only the
    compile-only `apply_ledger` marker from each explicitly bound legacy sink.
    Every populated legacy checkpoint row must match exactly one repeatable
    JSON `--binding`. The task never infers source provenance.

    Dry-run and apply output is structural and redacted. The generated
    migration requires `ASH_REPLICANT_PIPELINES_STOPPED=1` at migration time;
    set it only after stopping every pipeline node.

        #{Mix.Tasks.AshReplicant.Upgrade.Docs.example()}
    """

    use Igniter.Mix.Task

    require Igniter.Code.Function

    alias AshReplicant.Sink
    alias AshReplicant.Upgrade
    alias AshReplicant.Upgrade.{Checkpoint, Plan}
    alias AshReplicant.Upgrade.Checkpoint.Error, as: CheckpointError
    alias Igniter.Code.Common
    alias Igniter.Code.Function
    alias Igniter.Code.Keyword, as: CodeKeyword
    alias Igniter.Code.List, as: CodeList
    alias Igniter.Code.Module, as: CodeModule
    alias Igniter.Mix.Task.Info
    alias Igniter.Project.Application, as: ProjectApplication
    alias Igniter.Project.Config, as: ProjectConfig
    alias Igniter.Project.Module, as: ProjectModule
    alias Mix.Tasks.AshReplicant.Upgrade.Docs
    alias Sourceror.Zipper

    @migration_suffix "upgrade_ash_replicant_0_4_0_to_1_0_0.exs"

    # Igniter's default runner prints raw source diffs. Upgrade source embeds
    # destination/source identity facts, so this task owns a redacted runner:
    # one structural report, one confirmation, and no source hunk output.
    @impl Mix.Task
    def run(argv) do
      if Igniter.Mix.Task.help_requested?(argv) do
        Mix.Task.run("help", [Mix.Task.task_name(__MODULE__)])
      else
        Mix.Task.run("compile")
        Application.ensure_all_started(:rewrite)

        info =
          argv
          |> info(nil)
          |> Map.update!(:schema, &Keyword.merge(&1, Info.global_options()[:switches]))

        {opts, _rest} =
          Igniter.Util.Info.validate!(argv, info, Mix.Task.task_name(__MODULE__))

        igniter =
          Igniter.new()
          |> Map.put(:task, Mix.Task.task_name(__MODULE__))
          |> Igniter.Mix.Task.configure_and_run(__MODULE__, argv)
          |> Igniter.prepare_for_write()

        finish_run(igniter, opts)
      end
    end

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Info{
        group: :ash,
        example: Docs.example(),
        positional: [:from, :to],
        schema: [
          repo: :string,
          destination_database: :string,
          prefix: :string,
          binding: :keep
        ],
        defaults: [prefix: "public"],
        required: [:repo, :destination_database, :binding]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      if igniter.parent do
        Igniter.add_issue(
          igniter,
          "run mix ash_replicant.upgrade directly; composition is refused because the " <>
            "generic Igniter runner can render identity-bearing source changes"
        )
      else
        from = igniter.args.positional.from
        to = igniter.args.positional.to

        case Upgrade.validate_versions(from, to) do
          :ok -> build_plan(igniter)
          {:error, error} -> Igniter.add_issue(igniter, Exception.message(error))
        end
      end
    end

    defp build_plan(igniter) do
      {igniter, sinks} = sink_modules(igniter)
      encoded_bindings = List.wrap(igniter.args.options[:binding])

      with {:ok, parsed} <- parse_bindings(encoded_bindings, sinks),
           {:ok, igniter, bindings, repos} <- bind_sink_facts(igniter, parsed),
           {:ok, repo} <- select_repo(igniter.args.options[:repo], repos),
           :ok <- validate_checkpoint_bindings(bindings) do
        plan = %Plan{
          repo: repo,
          prefix: igniter.args.options[:prefix],
          destination_database: igniter.args.options[:destination_database],
          bindings: bindings
        }

        case legacy_source_plan(igniter, plan) do
          {:ok, igniter, source_plan} ->
            igniter
            |> apply_legacy_source_plan(source_plan)
            |> remove_legacy_markers(bindings)
            |> create_migration(plan)
            |> Igniter.assign(:ash_replicant_upgrade_plan, plan)
            |> Igniter.add_notice(Upgrade.report(plan, :planned))

          {:error, message} ->
            Igniter.add_issue(igniter, message)
        end
      else
        {:error, error} when is_exception(error) ->
          Igniter.add_issue(igniter, Exception.message(error))

        {:error, message} when is_binary(message) ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp sink_modules(igniter) do
      ProjectModule.find_all_matching_modules(igniter, fn _module, module_body ->
        match?({:ok, _use}, CodeModule.move_to_use(module_body, Sink))
      end)
    end

    defp parse_bindings(encoded, sinks) do
      Enum.reduce_while(encoded, {:ok, []}, fn value, {:ok, bindings} ->
        case Upgrade.parse_binding(value, sinks) do
          {:ok, binding} -> {:cont, {:ok, [binding | bindings]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, bindings} ->
          bindings = Enum.reverse(bindings)

          if unique_binding_targets?(bindings) do
            {:ok, bindings}
          else
            {:error, "each discovered sink and generated pipeline may be bound exactly once"}
          end

        error ->
          error
      end
    end

    defp unique_binding_targets?(bindings) do
      sinks = Enum.map(bindings, & &1.sink)
      pipelines = Enum.map(bindings, & &1.pipeline)
      Enum.uniq(sinks) == sinks and Enum.uniq(pipelines) == pipelines
    end

    defp bind_sink_facts(igniter, parsed) do
      Enum.reduce_while(parsed, {:ok, igniter, [], []}, fn binding,
                                                           {:ok, igniter, bindings, repos} ->
        case sink_facts(igniter, binding.sink) do
          {:ok, igniter, %{slot_name: slot_name, repo: repo}} ->
            bound =
              binding
              |> Map.put(:slot_name, slot_name)
              |> Map.update!(:pipeline, &pipeline_module/1)

            {:cont, {:ok, igniter, [bound | bindings], [repo | repos]}}

          {:error, igniter} ->
            {:halt,
             {:error, igniter,
              "a bound sink has unreadable repo or slot_name configuration; no source was changed"}}
        end
      end)
      |> case do
        {:ok, igniter, bindings, repos} ->
          {:ok, igniter, Enum.reverse(bindings), Enum.reverse(repos)}

        {:error, _igniter, message} ->
          {:error, message}
      end
    end

    defp sink_facts(igniter, sink) do
      case ProjectModule.find_module(igniter, sink) do
        {:ok, {igniter, _source, zipper}} ->
          with {:ok, module_body} <- Common.move_to_do_block(zipper),
               {:ok, use_call} <- CodeModule.move_to_use(module_body, Sink),
               {:ok, options} <- Function.move_to_nth_argument(use_call, 1),
               {:ok, repo} <- CodeKeyword.get_key(options, :repo),
               {:ok, slot_name} <- CodeKeyword.get_key(options, :slot_name),
               repo when is_atom(repo) <- literal_module(Zipper.node(repo)),
               slot_name when is_binary(slot_name) <- literal_string(Zipper.node(slot_name)) do
            {:ok, igniter, %{repo: repo, slot_name: slot_name}}
          else
            _unreadable -> {:error, igniter}
          end

        {:error, igniter} ->
          {:error, igniter}
      end
    end

    defp literal_module({:__block__, _meta, [value]}), do: literal_module(value)

    defp literal_module({:__aliases__, _meta, parts}) when is_list(parts) do
      if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
    end

    defp literal_module(value) when is_atom(value) and not is_nil(value), do: value
    defp literal_module(_value), do: nil

    defp literal_string({:__block__, _meta, [value]}), do: literal_string(value)
    defp literal_string(value) when is_binary(value), do: value
    defp literal_string(_value), do: nil

    defp pipeline_module(name), do: name |> String.split(".") |> Module.concat()

    defp legacy_source_plan(igniter, plan) do
      case checkpoint_snapshot_root(plan.repo) do
        {:ok, snapshot_root} ->
          igniter =
            igniter
            |> Igniter.include_glob("priv/repo/migrations/*.exs")
            |> Igniter.include_glob(Path.join(snapshot_root, "**/*.json"))

          legacy_source_plan(igniter, plan, snapshot_root)

        :error ->
          {:error, "the repo snapshot path is unreadable or invalid; no source was changed"}
      end
    end

    defp legacy_source_plan(igniter, plan, snapshot_root) do
      case checkpoint_snapshot_plan(igniter, plan.repo, snapshot_root) do
        {:ok, snapshot_plan} ->
          classify_source_plan(igniter, plan, snapshot_plan)

        :error ->
          {:error,
           "the checkpoint snapshot is missing, foreign, or not the exact 0.4 shape; no source was changed"}
      end
    end

    defp classify_source_plan(igniter, plan, snapshot_plan) do
      case {migration_exists?(igniter), snapshot_plan} do
        {true, :already_current} ->
          {:ok, igniter, :already_planned}

        {true, _snapshot_plan} ->
          {:error,
           "the upgrade migration exists without the matching current checkpoint snapshot; no source was changed"}

        {false, :already_current} ->
          source_plan_error()

        {false, snapshot_plan} ->
          build_source_plan(igniter, plan, snapshot_plan)
      end
    end

    defp build_source_plan(igniter, plan, snapshot_plan) do
      with %{path: _path, content: _content} <- snapshot_plan,
           application when is_atom(application) <- application_module(igniter),
           {:ok, igniter, children} <- application_children(igniter, application),
           {:ok, conversions} <- classify_legacy_children(children, plan.bindings),
           :ok <- validate_pipeline_targets(igniter, plan, conversions) do
        {:ok, igniter,
         %{application: application, conversions: conversions, snapshot: snapshot_plan}}
      else
        _other -> source_plan_error()
      end
    end

    defp source_plan_error do
      {:error,
       "legacy supervision is not one statically readable AshReplicant child per binding; no source was changed"}
    end

    defp checkpoint_snapshot_root(repo) do
      if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
        case repo.config()[:snapshots_path] do
          nil -> {:ok, "priv/resource_snapshots"}
          path when is_binary(path) and path != "" -> {:ok, path}
          _invalid -> :error
        end
      else
        {:ok, "priv/resource_snapshots"}
      end
    rescue
      _error -> :error
    catch
      _kind, _reason -> :error
    end

    defp checkpoint_snapshot_plan(igniter, repo, snapshot_root) do
      folder =
        Path.join([
          snapshot_root,
          repo |> Module.split() |> List.last() |> Macro.underscore(),
          "ash_replicant_checkpoints"
        ])

      sources =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.filter(fn source ->
          Path.dirname(source.path) == folder and
            Regex.match?(~r/\A\d{14}\.json\z/, Path.basename(source.path))
        end)
        |> Enum.sort_by(& &1.path)

      case List.last(sources) do
        nil ->
          :error

        source ->
          content = Rewrite.Source.get(source, :content)

          cond do
            Upgrade.current_checkpoint_snapshot?(content, repo) ->
              {:ok, :already_current}

            Upgrade.legacy_checkpoint_snapshot?(content, repo) ->
              migration_number =
                igniter.rewrite
                |> Rewrite.sources()
                |> Enum.map(& &1.path)
                |> Upgrade.next_migration_number()

              snapshot_number =
                migration_number
                |> String.to_integer()
                |> Kernel.+(1)
                |> Integer.to_string()
                |> String.pad_leading(14, "0")

              {:ok,
               %{
                 path: Path.join(folder, "#{snapshot_number}.json"),
                 content: Upgrade.render_checkpoint_snapshot(repo)
               }}

            true ->
              :error
          end
      end
    end

    defp migration_exists?(igniter) do
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.any?(&String.ends_with?(&1.path, "_#{@migration_suffix}"))
    end

    defp application_module(igniter) do
      case ProjectApplication.app_module(igniter) do
        {module, _args} when is_atom(module) -> module
        module when is_atom(module) -> module
        _other -> nil
      end
    end

    defp application_children(igniter, application) do
      case ProjectModule.find_module(igniter, application) do
        {:ok, {igniter, _source, zipper}} ->
          with {:ok, module_body} <- Common.move_to_do_block(zipper),
               {:ok, children} <- move_to_children_list(module_body),
               nodes when is_list(nodes) <- unwrap_block(Zipper.node(children)) do
            {:ok, igniter, nodes}
          else
            _unreadable -> :error
          end

        {:error, _igniter} ->
          :error
      end
    end

    defp move_to_children_list(zipper) do
      with {:ok, zipper} <- Function.move_to_def(zipper, :start, 2),
           {:ok, zipper} <-
             Function.move_to_function_call_in_current_scope(zipper, :=, [2], fn call ->
               Function.argument_matches_pattern?(
                 call,
                 0,
                 {:children, _, context}
                 when is_atom(context)
               ) and
                 Function.argument_matches_pattern?(call, 1, value when is_list(value))
             end) do
        Function.move_to_nth_argument(zipper, 1)
      end
    end

    defp classify_legacy_children(children, bindings) do
      classified = Enum.map(children, &classify_legacy_child/1)

      with false <- Enum.any?(classified, &match?({:error, _reason}, &1)),
           legacy <- Enum.filter(classified, &match?({:legacy, _, _, _}, &1)),
           true <- length(legacy) == length(bindings),
           {:ok, conversions} <- bind_legacy_children(legacy, bindings) do
        {:ok, conversions}
      else
        _other -> :error
      end
    end

    defp classify_legacy_child(node) do
      with {:ok, {module_ast, options_ast}} <- normalize_node(node),
           true <- literal_module(module_ast) == AshReplicant do
        if Keyword.keyword?(options_ast) and legacy_options_valid?(options_ast) do
          {:legacy, node, literal_module(Keyword.fetch!(options_ast, :sink)), options_ast}
        else
          {:error, :dynamic}
        end
      else
        {:ok, _other} -> :other
        false -> :other
        _error -> {:error, :unreadable}
      end
    end

    defp normalize_node(node) do
      node
      |> Sourceror.to_string()
      |> Code.string_to_quoted()
    end

    defp unwrap_block({:__block__, _meta, [value]}), do: value
    defp unwrap_block(value), do: value

    defp legacy_options_valid?(options) do
      keys = Keyword.keys(options)

      length(keys) == length(Enum.uniq(keys)) and
        Enum.all?([:sink, :connection, :publication], &Keyword.has_key?(options, &1)) and
        Enum.all?(keys, &(&1 in [:sink, :connection, :publication, :go_forward_only, :snapshot])) and
        relocatable_options?(Keyword.delete(options, :sink))
    end

    defp relocatable_options?(options) do
      {_ast, relocatable?} =
        Macro.prewalk(options, true, fn
          {:@, _meta, _args} = node, _relocatable? ->
            {node, false}

          {:__aliases__, _meta, [part]} = node, _relocatable?
          when part not in [:System, :Application] ->
            {node, false}

          {name, _meta, context} = node, _relocatable?
          when is_atom(name) and (is_atom(context) or is_nil(context)) ->
            {node, false}

          node, relocatable? ->
            {node, relocatable?}
        end)

      relocatable?
    end

    defp bind_legacy_children(legacy, bindings) do
      Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, conversions} ->
        matches =
          Enum.filter(legacy, fn {:legacy, _node, sink, _options} -> sink == binding.sink end)

        case matches do
          [{:legacy, node, _sink, options}] ->
            conversion = %{binding: binding, node: node, options: options}
            {:cont, {:ok, [conversion | conversions]}}

          _other ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, conversions} -> {:ok, Enum.reverse(conversions)}
        :error -> :error
      end
    end

    defp validate_pipeline_targets(igniter, plan, conversions) do
      app = ProjectApplication.app_name(igniter)

      if length(conversions) == length(plan.bindings) and
           Enum.all?(conversions, fn %{binding: binding} ->
             pipeline_absent?(igniter, binding.pipeline) and
               not ProjectConfig.configures_key?(igniter, "runtime.exs", app, [binding.pipeline])
           end) do
        :ok
      else
        :error
      end
    end

    defp pipeline_absent?(igniter, pipeline) do
      match?({:error, _igniter}, ProjectModule.find_module(igniter, pipeline))
    end

    defp apply_legacy_source_plan(igniter, :already_planned), do: igniter

    defp apply_legacy_source_plan(igniter, %{
           application: application,
           conversions: conversions,
           snapshot: snapshot
         }) do
      igniter
      |> replace_legacy_children(application, conversions)
      |> create_pipeline_modules(conversions)
      |> create_pipeline_configs(conversions)
      |> Igniter.create_new_file(snapshot.path, snapshot.content)
    end

    defp replace_legacy_children(igniter, application, conversions) do
      ProjectModule.find_and_update_module!(igniter, application, fn module_body ->
        case move_to_children_list(module_body) do
          {:ok, children} -> replace_legacy_children(conversions, children)
          :error -> :error
        end
      end)
    end

    defp replace_legacy_children([], children), do: {:ok, children}

    defp replace_legacy_children([conversion | rest], children) do
      case replace_legacy_child(children, conversion) do
        {:ok, children} -> replace_legacy_children(rest, children)
        :error -> :error
      end
    end

    defp replace_legacy_child(children, conversion) do
      Common.within(children, &replace_legacy_child_within(&1, conversion))
    end

    defp replace_legacy_child_within(children, conversion) do
      predicate = &legacy_child_for_binding?(&1, conversion.binding)

      case CodeList.move_to_list_item(children, predicate) do
        {:ok, item} -> {:ok, Common.replace_code(item, conversion.binding.pipeline)}
        :error -> :error
      end
    end

    defp legacy_child_for_binding?(item, binding),
      do: legacy_child_sink(Zipper.node(item)) == binding.sink

    defp legacy_child_sink(node) do
      case normalize_node(node) do
        {:ok, {module_ast, options}} when is_list(options) ->
          if literal_module(module_ast) == AshReplicant do
            options |> Keyword.get(:sink) |> literal_module()
          end

        _other ->
          nil
      end
    end

    defp create_pipeline_modules(igniter, conversions) do
      app = ProjectApplication.app_name(igniter)

      Enum.reduce(conversions, igniter, fn %{binding: binding}, igniter ->
        ProjectModule.create_module(igniter, binding.pipeline, """
        @moduledoc "Supervises the upgraded AshReplicant pipeline."

        use AshReplicant.Pipeline,
          otp_app: #{inspect(app)},
          sink: #{inspect(binding.sink)}
        """)
      end)
    end

    defp create_pipeline_configs(igniter, conversions) do
      app = ProjectApplication.app_name(igniter)

      Enum.reduce(conversions, igniter, fn %{binding: binding, options: options}, igniter ->
        options =
          options
          |> Keyword.delete(:sink)
          |> Keyword.put(:source_identity,
            system_identifier: binding.source_system_id,
            database: binding.source_database
          )

        ProjectConfig.configure_new(
          igniter,
          "runtime.exs",
          app,
          [binding.pipeline],
          {:code, options}
        )
      end)
    end

    defp select_repo(requested, repos) do
      requested = String.trim_leading(requested, "Elixir.")
      unique_repos = Enum.uniq(repos)

      case unique_repos do
        [repo] ->
          if Atom.to_string(repo) == "Elixir." <> requested,
            do: {:ok, repo},
            else: {:error, "--repo does not match every bound sink; no source was changed"}

        _other ->
          {:error, "every binding must use one literal destination repo; no source was changed"}
      end
    end

    defp validate_checkpoint_bindings(bindings) do
      checkpoint_bindings =
        Enum.map(bindings, &Map.take(&1, [:slot_name, :source_system_id, :source_database]))

      case Checkpoint.classify(%{
             schema: :legacy,
             rows: [],
             bindings: checkpoint_bindings
           }) do
        {:ok, _report} -> :ok
        {:error, error} -> {:error, error}
      end
    end

    defp remove_legacy_markers(igniter, bindings) do
      bindings
      |> Enum.map(& &1.sink)
      |> Enum.uniq()
      |> Enum.reduce(igniter, fn sink, igniter ->
        ProjectModule.find_and_update_module!(igniter, sink, fn module_body ->
          remove_legacy_marker(module_body)
        end)
      end)
    end

    defp remove_legacy_marker(module_body) do
      with {:ok, use_call} <- CodeModule.move_to_use(module_body, Sink),
           {:ok, options} <- Function.move_to_nth_argument(use_call, 1),
           {:ok, options} <- CodeKeyword.remove_keyword_key(options, :apply_ledger) do
        {:ok, options}
      else
        _unreadable ->
          {:error, "a bound sink cannot be rewritten structurally; no source was changed"}
      end
    end

    defp create_migration(igniter, plan) do
      igniter = Igniter.include_glob(igniter, "priv/repo/migrations/*.exs")

      paths = igniter.rewrite |> Rewrite.sources() |> Enum.map(& &1.path)

      case Enum.find(paths, &String.ends_with?(&1, "_#{@migration_suffix}")) do
        nil ->
          number = Upgrade.next_migration_number(paths)
          path = "priv/repo/migrations/#{number}_#{@migration_suffix}"
          migration_module = Module.concat([plan.repo, Migrations, UpgradeAshReplicant040To100])
          Igniter.create_new_file(igniter, path, Upgrade.render_migration(plan, migration_module))

        _existing ->
          igniter
      end
    end

    defp finish_run(%{issues: [_ | _] = issues}, _opts) do
      shell = Mix.shell()
      Enum.each(issues, &shell.error/1)
      exit({:shutdown, 1})
    end

    defp finish_run(igniter, opts) do
      plan = Map.fetch!(igniter.assigns, :ash_replicant_upgrade_plan)

      case live_check(plan) do
        {:ok, report} ->
          change_count = Enum.count(Rewrite.sources(igniter.rewrite), &Rewrite.Source.updated?/1)

          Mix.shell().info(
            Upgrade.report(plan, report.state) <> " source_changes=#{change_count}"
          )

          finish_write(igniter, opts)

        {:error, error} ->
          Mix.shell().error(Exception.message(error))
          exit({:shutdown, 1})
      end
    end

    defp finish_write(igniter, opts) do
      if opts[:dry_run] do
        :dry_run_with_changes
      else
        maybe_write(igniter, opts[:yes])
      end
    end

    defp maybe_write(igniter, yes?) do
      if yes? or Mix.shell().yes?("Apply the reported AshReplicant upgrade changes?") do
        case Rewrite.write_all(igniter.rewrite) do
          {:ok, _rewrite} -> :changes_made
          {:error, _error, _rewrite} -> exit({:shutdown, 1})
        end
      else
        :dry_run_with_changes
      end
    end

    defp live_check(%Plan{} = plan) do
      with :ok <- default_dynamic_repo?(plan.repo),
           :ok <- ensure_database_apps_started(),
           {:ok, started} <- ensure_repo_started(plan.repo) do
        try do
          Checkpoint.check(plan.repo,
            bindings:
              Enum.map(
                plan.bindings,
                &Map.take(&1, [:slot_name, :source_system_id, :source_database])
              ),
            prefix: plan.prefix,
            destination_database: plan.destination_database
          )
        after
          if started, do: GenServer.stop(started)
        end
      end
    rescue
      _error ->
        {:error, CheckpointError.exception(reason: :database_fault)}
    catch
      _kind, _reason ->
        {:error, CheckpointError.exception(reason: :database_fault)}
    end

    defp default_dynamic_repo?(repo) do
      if repo.get_dynamic_repo() == repo,
        do: :ok,
        else: {:error, CheckpointError.exception(reason: :destination_mismatch)}
    end

    defp ensure_database_apps_started do
      with {:ok, _started} <- Application.ensure_all_started(:ecto_sql),
           {:ok, _started} <- Application.ensure_all_started(:postgrex) do
        :ok
      else
        _error ->
          {:error, CheckpointError.exception(reason: :database_fault)}
      end
    end

    defp ensure_repo_started(repo) do
      case Process.whereis(repo) do
        pid when is_pid(pid) ->
          {:ok, false}

        nil ->
          case repo.start_link() do
            {:ok, pid} ->
              {:ok, pid}

            {:error, {:already_started, _pid}} ->
              {:ok, false}

            _other ->
              {:error, CheckpointError.exception(reason: :database_fault)}
          end
      end
    end
  end
else
  defmodule Mix.Tasks.AshReplicant.Upgrade do
    @moduledoc false
    @shortdoc Mix.Tasks.AshReplicant.Upgrade.Docs.short_doc()
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error(
        "mix ash_replicant.upgrade requires the optional :igniter dependency; " <>
          "add {:igniter, \"~> 0.8\", only: [:dev, :test], runtime: false} and retry"
      )

      exit({:shutdown, 1})
    end
  end
end
