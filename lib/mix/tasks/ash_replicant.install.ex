defmodule Mix.Tasks.AshReplicant.Install.Docs do
  @moduledoc false

  @doc false
  def short_doc, do: "Wire AshReplicant into an Ash application"

  @doc false
  def example, do: "mix ash_replicant.install --repo MyApp.Repo --slot shop_orders"

  @doc false
  def long_doc do
    """
    #{short_doc()}

    Generates the four modules a Replicant sink needs, registers them, and queues
    the migration codegen. Everything it writes is host-owned code you can read,
    edit, and re-generate; nothing is hidden behind the package.

    ## Example

    ```bash
    #{example()}
    ```

    ## What it generates

    | Artifact | Default name | Shape |
    | --- | --- | --- |
    | Domain | `MyApp.Replicant` | `use Ash.Domain`, holding the checkpoint |
    | Checkpoint | `MyApp.Replicant.Checkpoint` | `use AshReplicant.Checkpoint` |
    | Sink | `MyApp.Replicant.Sink` | `use AshReplicant.Sink` |
    | Pipeline | `MyApp.Replicant.Pipeline` | `use AshReplicant.Pipeline` |

    It also adds the domain to `:ash_domains`, supervises the pipeline in the
    application tree, imports AshReplicant's public DSL formatter metadata, and
    queues `mix ash.codegen install_ash_replicant` so the checkpoint migration
    comes from your resource snapshots rather than from a template that could
    drift.

    ## What it deliberately does NOT do

    It writes no connection, publication, source identity, or key material: those
    are operator facts, and a plausible-looking placeholder is worse than an
    absent one. The generated pipeline therefore supervises NOTHING until you
    configure it — a fresh install compiles and boots as a no-op. It also does not
    run migrations, start a pipeline, or mark your source resources with
    `AshReplicant.Resource`; the last is a modelling decision only you can make.

    ## Options

    * `--repo` - the AshPostgres repo the mirror and checkpoint commit through.
      Use it to select among several discovered repos; when none exists,
      generate one with `mix ash_postgres.install` first.
    * `--slot` - the PostgreSQL replication slot name. Defaults to
      `<otp_app>_replicant`.
    * `--domain` - name for the generated Ash domain.
    * `--checkpoint` - name for the generated checkpoint resource.
    * `--sink` - name for the generated sink.
    * `--pipeline` - name for the generated pipeline supervisor.

    ## Refusals

    The installer stops — writing nothing — rather than guess about anything whose
    wrongness is quiet: a malformed module name, an illegal slot name, an
    ambiguous, missing, unknown, or non-AshPostgres repo; incomplete project
    facts; a module it did not generate sitting at a target name; an unreadable
    existing binding; an existing checkpoint bound to another repo; an existing
    sink bound to another slot; or an existing pipeline wired to another sink.
    Each refusal names the flag or structural fact that resolves it.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshReplicant.Install do
    @shortdoc "#{Mix.Tasks.AshReplicant.Install.Docs.short_doc()}"
    @moduledoc Mix.Tasks.AshReplicant.Install.Docs.long_doc()

    use Igniter.Mix.Task

    alias AshReplicant.Install
    alias Igniter.Code.Common
    alias Igniter.Code.Function
    alias Igniter.Code.Keyword, as: CodeKeyword
    alias Igniter.Code.List, as: CodeList
    alias Igniter.Code.Module, as: CodeModule
    alias Igniter.Mix.Task.Info
    alias Igniter.Project.Application, as: ProjectApplication
    alias Igniter.Project.Config, as: ProjectConfig
    alias Igniter.Project.Formatter, as: ProjectFormatter
    alias Igniter.Project.IgniterConfig
    alias Igniter.Project.Module, as: ProjectModule
    alias Mix.Tasks.AshReplicant.Install.Docs
    alias Sourceror.Zipper

    @flags [:repo, :slot, :domain, :checkpoint, :sink, :pipeline]

    @ash_postgres_repo_contract [
      __adapter__: 0,
      default_constraint_match_type: 2,
      from_ecto: 1,
      installed_extensions: 0,
      on_transaction_begin: 1,
      prefer_transaction?: 0,
      to_ecto: 1
    ]

    # Igniter's default `run/1` prints the issues and returns `:issues`, leaving
    # the Mix task to exit 0 — so `mix ash_replicant.install && mix ecto.migrate`
    # would sail straight past a refusal. A structural refusal that reports
    # success is the exact quiet failure this task exists to prevent, so it gets
    # an exit status. (Composition is unaffected: `Igniter.compose_task/3` runs
    # `igniter/1`, never this.)
    @impl Mix.Task
    def run(argv), do: exit_status(super(argv))

    @doc false
    @spec exit_status(term()) :: no_return() | term()
    def exit_status(:issues), do: exit({:shutdown, 1})
    def exit_status(result), do: result

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Info{
        group: :ash,
        example: Docs.example(),
        schema: [
          repo: :string,
          slot: :string,
          domain: :string,
          checkpoint: :string,
          sink: :string,
          pipeline: :string
        ],
        composes: ["ash.codegen"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      otp_app = ProjectApplication.app_name(igniter)
      prefix = ProjectModule.module_name_prefix(igniter)
      options = options(igniter)

      {igniter, repos} = ash_postgres_repos(igniter)

      case Install.validate_options(options) do
        {:error, error} ->
          Igniter.add_issue(igniter, Exception.message(error))

        :ok ->
          artifacts = Install.artifacts(prefix, options)
          {igniter, existing} = existing_state(igniter, artifacts)

          plan =
            Install.plan(
              otp_app: otp_app,
              prefix: prefix,
              options: options,
              repos: repos,
              existing: existing
            )

          case plan do
            # A refusal writes NOTHING: the operator fixes one named thing and
            # re-runs against an untouched project.
            {:error, error} -> Igniter.add_issue(igniter, Exception.message(error))
            {:ok, plan} -> apply_plan(igniter, plan)
          end
      end
    end

    defp ash_postgres_repos(igniter) do
      production_folders =
        igniter
        |> IgniterConfig.get(:source_folders)
        |> Enum.reject(&non_production_folder?/1)

      {igniter, candidates} =
        ProjectModule.find_all_matching_modules(igniter, fn module, module_body ->
          match?({:ok, _use}, CodeModule.move_to_use(module_body, AshPostgres.Repo)) or
            compiled_ash_postgres_repo?(module)
        end)

      candidates
      |> Enum.reduce({igniter, []}, fn module, {igniter, repos} ->
        maybe_add_repo(igniter, module, repos, production_folders)
      end)
      |> then(fn {igniter, repos} -> {igniter, Enum.reverse(repos)} end)
    end

    defp maybe_add_repo(igniter, module, repos, production_folders) do
      case ProjectModule.find_module(igniter, module) do
        {:ok, {igniter, source, _zipper}} ->
          repos =
            if production_source?(source.path, production_folders),
              do: [module | repos],
              else: repos

          {igniter, repos}

        {:error, igniter} ->
          {igniter, repos}
      end
    end

    defp compiled_ash_postgres_repo?(module) do
      Code.ensure_loaded?(module) and
        Enum.all?(@ash_postgres_repo_contract, fn {name, arity} ->
          function_exported?(module, name, arity)
        end) and
        module.__adapter__() == Ecto.Adapters.Postgres
    rescue
      _ -> false
    end

    defp non_production_folder?(folder) do
      Enum.any?(Path.split(folder), &(&1 in ["test", "config"]))
    end

    defp production_source?(source, folders) do
      source = Path.expand(source)

      Enum.any?(folders, fn folder ->
        folder = Path.expand(folder)
        source == folder or String.starts_with?(source, folder <> "/")
      end)
    end

    defp options(igniter) do
      igniter.args.options
      |> Keyword.take(@flags)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end

    defp apply_plan(igniter, plan) do
      igniter
      |> create_domain(plan)
      |> create_checkpoint(plan)
      |> create_sink(plan)
      |> create_pipeline(plan)
      |> register_domain(plan)
      |> supervise_pipeline(plan)
      |> ProjectFormatter.import_dep(:ash_replicant)
      |> Ash.Igniter.codegen("install_ash_replicant")
      |> Igniter.add_notice(notice(plan))
    end

    # The domain is the one artifact that can be JOINED rather than created, so it
    # is the one place a second run could rewrite a file. `existing_state/2` has
    # already told us which case we are in, so decide from that rather than from
    # `Ash.Domain.Igniter`'s domain discovery: that helper's fast path consults
    # compiled `:ash_domains` plus only the CHANGED sources, so on a second run it
    # can miss a domain that is already on disk and rewrite the module wholesale.
    defp create_domain(igniter, %{domain: %{create?: false}} = plan) do
      {igniter, listed?} = checkpoint_listed?(igniter, plan)

      # Updating a module marks its source rewritten even when the codemod is a
      # no-op, which re-prints (and re-formats) a file the operator never asked us
      # to touch. Decide BEFORE updating, so a re-run is genuinely inert.
      if listed? do
        igniter
      else
        ProjectModule.find_and_update_module!(igniter, plan.domain.module, fn zipper ->
          add_resource(zipper, plan.checkpoint.module)
        end)
      end
    end

    defp create_domain(igniter, plan) do
      ProjectModule.create_module(igniter, plan.domain.module, """
      @moduledoc \"\"\"
      The Ash domain holding AshReplicant's internal checkpoint resource.
      \"\"\"

      use Ash.Domain,
        otp_app: #{inspect(plan.otp_app)}

      resources do
        resource #{inspect(plan.checkpoint.module)}
      end
      """)
    end

    defp checkpoint_listed?(igniter, plan) do
      case ProjectModule.find_module(igniter, plan.domain.module) do
        {:error, igniter} ->
          {igniter, false}

        {:ok, {igniter, _source, zipper}} ->
          {igniter, match?({:ok, _found}, move_to_resource(zipper, plan.checkpoint.module))}
      end
    end

    defp add_resource(zipper, resource) do
      case Function.move_to_function_call_in_current_scope(zipper, :resources, 1) do
        :error ->
          {:ok,
           Common.add_code(zipper, """
           resources do
             resource #{inspect(resource)}
           end
           """)}

        {:ok, resources} ->
          case Common.move_to_do_block(resources) do
            {:ok, body} -> {:ok, Common.add_code(body, "resource #{inspect(resource)}")}
            :error -> {:ok, zipper}
          end
      end
    end

    defp move_to_resource(zipper, resource) do
      with {:ok, module_body} <- Common.move_to_do_block(zipper),
           {:ok, resources} <-
             Function.move_to_function_call_in_current_scope(module_body, :resources, 1),
           {:ok, resources_body} <- Common.move_to_do_block(resources) do
        Function.move_to_function_call_in_current_scope(
          resources_body,
          :resource,
          [1, 2],
          &Function.argument_equals?(&1, 0, resource)
        )
      else
        _not_found -> :error
      end
    end

    defp create_checkpoint(igniter, %{checkpoint: %{create?: false}}), do: igniter

    defp create_checkpoint(igniter, plan) do
      ProjectModule.create_module(igniter, plan.checkpoint.module, """
      @moduledoc \"\"\"
      AshReplicant's durable commit-LSN watermark, one row per replication source
      and slot.

      Internal to the sink: the generated resource is default-deny, and the sink
      reads and upserts it with `authorize?: false`. See `AshReplicant.Checkpoint`.
      \"\"\"

      use AshReplicant.Checkpoint,
        repo: #{inspect(plan.repo)},
        domain: #{inspect(plan.domain.module)}
      """)
    end

    defp create_sink(igniter, %{sink: %{create?: false}}), do: igniter

    defp create_sink(igniter, plan) do
      ProjectModule.create_module(igniter, plan.sink.module, """
      @moduledoc \"\"\"
      The `Replicant.Sink` for the `#{plan.slot_name}` replication slot.

      Add every domain whose resources carry `AshReplicant.Resource` to `domains`.
      See `AshReplicant.Sink`.
      \"\"\"

      use AshReplicant.Sink,
        repo: #{inspect(plan.repo)},
        domains: [],
        checkpoint_resource: #{inspect(plan.checkpoint.module)},
        slot_name: #{inspect(plan.slot_name)}
      """)
    end

    defp create_pipeline(igniter, %{pipeline: %{create?: false}}), do: igniter

    defp create_pipeline(igniter, plan) do
      ProjectModule.create_module(igniter, plan.pipeline.module, """
      @moduledoc \"\"\"
      Supervises the pipeline owner for `#{inspect(plan.sink.module)}`.

      Supervises nothing until this module is configured. See
      `AshReplicant.Pipeline` for the keys it reads.
      \"\"\"

      use AshReplicant.Pipeline,
        otp_app: #{inspect(plan.otp_app)},
        sink: #{inspect(plan.sink.module)}
      """)
    end

    defp register_domain(igniter, plan) do
      ProjectConfig.configure(
        igniter,
        "config.exs",
        plan.otp_app,
        [:ash_domains],
        [plan.domain.module],
        updater: &CodeList.prepend_new_to_list(&1, plan.domain.module)
      )
    end

    defp supervise_pipeline(igniter, plan) do
      ProjectApplication.add_new_child(igniter, plan.pipeline.module)
    end

    defp notice(plan) do
      """
      AshReplicant is wired in. Four steps remain, and each needs a fact only you have:

      1. Configure the pipeline. Until this exists, #{inspect(plan.pipeline.module)}
         supervises nothing:

             config #{inspect(plan.otp_app)}, #{inspect(plan.pipeline.module)},
               connection: [hostname: "standby.example.com", database: "source_db"],
               publication: "#{plan.slot_name}_pub",
               source_identity: [system_identifier: "...", database: "source_db"],
               go_forward_only: true

      2. Mark the resources you mirror with the `AshReplicant.Resource` extension,
         and list their domains in #{inspect(plan.sink.module)}'s `domains`. Every
         published table must be mapped or explicitly ignored, or the pipeline
         refuses to start.

      3. Review the checkpoint migration `mix ash.codegen install_ash_replicant` just
         generated, then run `mix ecto.migrate`.

      4. On the SOURCE database, set `ALTER TABLE <table> REPLICA IDENTITY FULL` for
         every tenant-scoped, SCD2-with-non-PK-business-key, or append-log source
         table. Activation preflight enforces this; without it a delete's old row
         carries only the primary key.
      """
    end

    # Fact gathering: what is already at each target name, and what is it bound to.
    # Read-only — nothing here writes, so a refusal leaves the project untouched.

    defp existing_state(igniter, artifacts) do
      {igniter, domain} = classify(igniter, artifacts.domain, &domain_binding/1)
      {igniter, checkpoint} = classify(igniter, artifacts.checkpoint, &checkpoint_binding/1)
      {igniter, sink} = classify(igniter, artifacts.sink, &sink_binding/1)
      {igniter, pipeline} = classify(igniter, artifacts.pipeline, &pipeline_binding/1)

      {igniter, %{domain: domain, checkpoint: checkpoint, sink: sink, pipeline: pipeline}}
    end

    defp classify(igniter, module, binding) do
      case ProjectModule.find_module(igniter, module) do
        {:error, igniter} -> {igniter, :absent}
        {:ok, {igniter, _source, zipper}} -> {igniter, binding.(zipper)}
      end
    end

    defp domain_binding(zipper) do
      case move_to_use(zipper, Ash.Domain) do
        {:ok, _zipper} -> :ash_domain
        :error -> :foreign
      end
    end

    defp checkpoint_binding(zipper),
      do: generated_binding(zipper, AshReplicant.Checkpoint, :repo, &module_value/2)

    defp sink_binding(zipper),
      do: generated_binding(zipper, AshReplicant.Sink, :slot_name, &string_value/2)

    defp pipeline_binding(zipper),
      do: generated_binding(zipper, AshReplicant.Pipeline, :sink, &module_value/2)

    # An existing module that carries our top-level `use` is ours to reuse. An
    # unreadable binding is reported as nil and the planner refuses it; inability
    # to prove identity is never proof that the binding matches.
    defp generated_binding(zipper, macro, key, decode) do
      aliases = literal_aliases_before_use(zipper, macro)

      case move_to_use(zipper, macro) do
        :error -> :foreign
        {:ok, use_call} -> {:ash_replicant, use_option(use_call, key, aliases, decode)}
      end
    end

    defp move_to_use(zipper, module) do
      case Common.move_to_do_block(zipper) do
        {:ok, module_body} -> CodeModule.move_to_use(module_body, module)
        _not_a_module -> :error
      end
    end

    defp use_option(use_call, key, aliases, decode) do
      with {:ok, options} <- Function.move_to_nth_argument(use_call, 1),
           {:ok, value} <- CodeKeyword.get_key(options, key) do
        decode.(value, aliases)
      else
        _unreadable -> nil
      end
    end

    defp module_value(%Zipper{node: node}, aliases) do
      node
      |> unwrap()
      |> literal_module(aliases)
    end

    defp literal_module(value, _aliases) when is_atom(value) and not is_nil(value), do: value

    defp literal_module({:__aliases__, _meta, parts}, aliases) do
      if Enum.all?(parts, &is_atom/1), do: resolve_alias(parts, aliases), else: nil
    end

    defp literal_module(_value, _aliases), do: nil

    defp string_value(%Zipper{node: node}, _aliases) do
      case unwrap(node) do
        value when is_binary(value) -> value
        _other -> nil
      end
    end

    defp literal_aliases_before_use(zipper, macro) do
      case Common.move_to_do_block(zipper) do
        {:ok, body} -> collect_literal_aliases(body, macro)
        _not_a_module -> %{}
      end
    end

    defp collect_literal_aliases(body, macro) do
      body
      |> Zipper.node()
      |> top_level_expressions()
      |> Enum.reduce_while(%{}, fn expression, aliases ->
        if use_target?(expression, macro),
          do: {:halt, aliases},
          else: {:cont, add_literal_alias(aliases, expression)}
      end)
    end

    defp top_level_expressions({:__block__, _meta, expressions}), do: expressions
    defp top_level_expressions(expression), do: [expression]

    defp use_target?({:use, _meta, [target | _options]}, macro) do
      literal_module(target, %{}) == macro
    end

    defp use_target?(_expression, _macro), do: false

    defp add_literal_alias(aliases, {:alias, _meta, [target | options]}) do
      with {:__aliases__, _target_meta, target_parts} <- unwrap(target),
           true <- Enum.all?(target_parts, &is_atom/1),
           target_module when not is_nil(target_module) <- resolve_alias(target_parts, aliases),
           {:ok, local_name} <- alias_local_name(target_parts, alias_options(options)) do
        Map.put(aliases, local_name, target_module)
      else
        _unreadable -> aliases
      end
    end

    defp add_literal_alias(aliases, _expression), do: aliases

    defp alias_options([]), do: []
    defp alias_options([options]) when is_list(options), do: options
    defp alias_options(_unreadable), do: []

    defp alias_local_name(target_parts, options) do
      case Keyword.get(options, :as) do
        nil -> {:ok, List.last(target_parts)}
        {:__aliases__, _meta, [name]} when is_atom(name) -> {:ok, name}
        _unreadable -> :error
      end
    end

    defp resolve_alias([first | rest] = parts, aliases) do
      case Map.fetch(aliases, first) do
        {:ok, prefix} -> Module.concat([prefix | rest])
        :error -> Module.concat(parts)
      end
    end

    # Sourceror wraps literals in a `:__block__` node to carry formatting
    # metadata, so `slot_name: "orders"` reaches us as `{:__block__, _, ["orders"]}`
    # rather than the bare binary. Unwrap by pattern, never by evaluating the
    # host's source.
    defp unwrap({:__block__, _meta, [value]}), do: unwrap(value)
    defp unwrap(value), do: value
  end
else
  defmodule Mix.Tasks.AshReplicant.Install do
    @shortdoc "#{Mix.Tasks.AshReplicant.Install.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc Mix.Tasks.AshReplicant.Install.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_replicant.install' requires igniter.

      Add it to your dependencies and try again:

          {:igniter, "~> 0.8", only: [:dev, :test], runtime: false}

      Or install in one step, which brings igniter with it:

          mix igniter.install ash_replicant

      The manual, dependency-free equivalent is documented in the AshReplicant
      README under "Manual installation".
      """)

      exit({:shutdown, 1})
    end
  end
end
