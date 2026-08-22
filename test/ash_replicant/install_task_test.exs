defmodule AshReplicant.InstallTaskTest.RepoBase do
  defmacro __using__(opts) do
    quote do
      use AshPostgres.Repo, unquote(opts)
    end
  end
end

defmodule AshReplicant.InstallTaskTest.IndirectRepo do
  use AshReplicant.InstallTaskTest.RepoBase,
    otp_app: :ash_replicant,
    warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule AshReplicant.InstallTaskTest do
  @moduledoc """
  `mix ash_replicant.install` (I01) against Igniter's in-memory project harness.

  Three properties carry the acceptance:

  1. A blank supported Ash app reaches the whole wiring in one command, and every
     generated file is real Elixir that the shipped macros actually compile.
  2. Re-running changes nothing.
  3. Unsafe pre-existing names and bindings STOP the install with an actionable
     structural error — and leave the project untouched.
  """

  # NOT async: two tests reach for process-global state — `capture_io(:stderr, ...)`
  # around the generated-code compile, and `Mix.shell/1` around the fallback task.
  # Neither is asynchronous-safe.
  use ExUnit.Case, async: false

  import Igniter.Test

  alias Mix.Tasks.AshReplicant.Install, as: Task

  @repo """
  defmodule MyApp.Repo do
    use AshPostgres.Repo, otp_app: :my_app
  end
  """

  @application """
  defmodule MyApp.Application do
    @moduledoc false
    use Application

    @impl true
    def start(_type, _args) do
      children = [MyApp.Repo]

      Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
    end
  end
  """

  # `mix new --sup`'s mix.exs: the supervised shape a real Ash app has, so the
  # installer patches the EXISTING application module rather than creating one.
  @mix_exs """
  defmodule MyApp.MixProject do
    use Mix.Project

    def project do
      [
        app: :my_app,
        version: "0.1.0",
        elixir: "~> 1.17",
        start_permanent: Mix.env() == :prod,
        deps: deps()
      ]
    end

    def application do
      [
        extra_applications: [:logger],
        mod: {MyApp.Application, []}
      ]
    end

    defp deps do
      []
    end
  end
  """

  @supervised %{
    "mix.exs" => @mix_exs,
    "lib/my_app/repo.ex" => @repo,
    "lib/my_app/application.ex" => @application
  }

  defp project(files \\ %{}) do
    test_project(app_name: :my_app, files: Map.merge(@supervised, files))
  end

  defp install(igniter, argv \\ []), do: Igniter.compose_task(igniter, Task, argv)

  defp content(igniter, path) do
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  describe "a blank supported Ash app" do
    setup do
      %{igniter: project() |> install() |> apply_igniter!()}
    end

    test "generates the domain, checkpoint, sink, and pipeline", %{igniter: igniter} do
      for path <- [
            "lib/my_app/replicant.ex",
            "lib/my_app/replicant/checkpoint.ex",
            "lib/my_app/replicant/sink.ex",
            "lib/my_app/replicant/pipeline.ex"
          ] do
        assert Igniter.exists?(igniter, path), "expected the installer to create #{path}"
        assert content(igniter, path) =~ "defmodule MyApp.Replicant"
      end
    end

    test "every generated file is syntactically valid Elixir", %{igniter: igniter} do
      for path <- [
            "lib/my_app/replicant.ex",
            "lib/my_app/replicant/checkpoint.ex",
            "lib/my_app/replicant/sink.ex",
            "lib/my_app/replicant/pipeline.ex",
            "config/config.exs"
          ] do
        assert {:ok, _ast} = Code.string_to_quoted(content(igniter, path)),
               "#{path} is not valid Elixir"
      end
    end

    test "the domain holds the checkpoint resource", %{igniter: igniter} do
      source = content(igniter, "lib/my_app/replicant.ex")

      assert source =~ "use Ash.Domain"
      # The synthetic project carries no `import_deps: [:ash]`, so `mix format`
      # parenthesizes Ash's DSL locals here. Accept either rendering.
      assert source =~ ~r/resource\(?MyApp\.Replicant\.Checkpoint\)?/
    end

    test "the checkpoint binds the discovered repo and the generated domain", %{igniter: igniter} do
      source = content(igniter, "lib/my_app/replicant/checkpoint.ex")

      assert source =~ "use AshReplicant.Checkpoint"
      assert source =~ "repo: MyApp.Repo"
      assert source =~ "domain: MyApp.Replicant"
    end

    test "the sink binds the repo, checkpoint, and derived slot", %{igniter: igniter} do
      source = content(igniter, "lib/my_app/replicant/sink.ex")

      assert source =~ "use AshReplicant.Sink"
      assert source =~ "repo: MyApp.Repo"
      assert source =~ "checkpoint_resource: MyApp.Replicant.Checkpoint"
      assert source =~ ~s(slot_name: "my_app_replicant")
      assert source =~ "domains: []"
    end

    test "the pipeline binds the otp app and the generated sink", %{igniter: igniter} do
      source = content(igniter, "lib/my_app/replicant/pipeline.ex")

      assert source =~ "use AshReplicant.Pipeline"
      assert source =~ "otp_app: :my_app"
      assert source =~ "sink: MyApp.Replicant.Sink"
    end

    test "registers the domain in config", %{igniter: igniter} do
      assert content(igniter, "config/config.exs") =~ "ash_domains: [MyApp.Replicant]"
    end

    test "supervises the pipeline in the application tree", %{igniter: igniter} do
      assert content(igniter, "lib/my_app/application.ex") =~ "MyApp.Replicant.Pipeline"
    end

    test "writes no connection, publication, identity, or key material", %{igniter: igniter} do
      sources =
        Enum.map_join(
          [
            "lib/my_app/replicant.ex",
            "lib/my_app/replicant/checkpoint.ex",
            "lib/my_app/replicant/sink.ex",
            "lib/my_app/replicant/pipeline.ex",
            "config/config.exs"
          ],
          "\n",
          &content(igniter, &1)
        )

      refute sources =~ ~r/hostname:|password|system_identifier:|publication:/
      refute sources =~ ~r/message_digest_keys|snapshot_provenance_keys/
    end
  end

  describe "follow-up work" do
    test "queues the migration codegen rather than writing a migration itself" do
      project()
      |> install()
      |> assert_has_task("ash.codegen", ["install_ash_replicant"])
    end

    test "tells the operator what only they can do" do
      igniter = install(project())

      assert [notice] = igniter.notices

      # The three facts the installer cannot know, plus the two host-side steps.
      assert notice =~ "MyApp.Replicant.Pipeline"
      assert notice =~ "connection:"
      assert notice =~ "publication:"
      assert notice =~ "source_identity:"
      assert notice =~ "AshReplicant.Resource"
      assert notice =~ "REPLICA IDENTITY FULL"
      assert notice =~ "mix ecto.migrate"
    end
  end

  describe "flags" do
    test "--slot overrides the derived slot name" do
      igniter = project() |> install(["--slot", "shop_orders"]) |> apply_igniter!()

      assert content(igniter, "lib/my_app/replicant/sink.ex") =~ ~s(slot_name: "shop_orders")
    end

    test "--repo overrides repo discovery" do
      igniter =
        project(%{
          "lib/my_app/mirror_repo.ex" => """
          defmodule MyApp.MirrorRepo do
            use AshPostgres.Repo, otp_app: :my_app
          end
          """
        })
        |> install(["--repo", "MyApp.MirrorRepo"])
        |> apply_igniter!()

      assert content(igniter, "lib/my_app/replicant/checkpoint.ex") =~ "repo: MyApp.MirrorRepo"
      assert content(igniter, "lib/my_app/replicant/sink.ex") =~ "repo: MyApp.MirrorRepo"
    end

    test "--repo accepts a compiled AshPostgres repo defined through a wrapper macro" do
      repo = AshReplicant.InstallTaskTest.IndirectRepo

      igniter =
        project(%{
          "lib/my_app/indirect_repo.ex" => """
          defmodule #{inspect(repo)} do
            use AshReplicant.InstallTaskTest.RepoBase, otp_app: :ash_replicant
          end
          """
        })
        |> install(["--repo", inspect(repo)])
        |> apply_igniter!()

      assert content(igniter, "lib/my_app/replicant/checkpoint.ex") =~ "repo: #{inspect(repo)}"
    end

    test "each artifact name is individually overridable" do
      igniter =
        project()
        |> install([
          "--domain",
          "MyApp.Mirror",
          "--checkpoint",
          "MyApp.Mirror.Watermark",
          "--sink",
          "MyApp.Mirror.OrdersSink",
          "--pipeline",
          "MyApp.Mirror.OrdersPipeline"
        ])
        |> apply_igniter!()

      assert content(igniter, "lib/my_app/mirror/watermark.ex") =~ "domain: MyApp.Mirror"

      assert content(igniter, "lib/my_app/mirror/orders_sink.ex") =~
               "checkpoint_resource: MyApp.Mirror.Watermark"

      assert content(igniter, "lib/my_app/mirror/orders_pipeline.ex") =~
               "sink: MyApp.Mirror.OrdersSink"
    end
  end

  describe "idempotency" do
    test "a second run over the installed project changes nothing" do
      second = project() |> install() |> apply_igniter!() |> install()

      # `assert_unchanged` alone is not enough: re-creating an existing file
      # leaves the source untouched and raises an ISSUE instead, which would
      # read as a clean idempotent run while actually blocking the install.
      assert second.issues == []
      assert_unchanged(second)
    end

    test "a second run does not re-register the domain or re-supervise the pipeline" do
      igniter = project() |> install() |> apply_igniter!() |> install() |> apply_igniter!()

      config = content(igniter, "config/config.exs")
      application = content(igniter, "lib/my_app/application.ex")

      assert length(String.split(config, "MyApp.Replicant")) == 2
      assert length(String.split(application, "MyApp.Replicant.Pipeline")) == 2
    end
  end

  describe "formatter contract" do
    defp public_replicant_locals do
      AshReplicant.Resource.sections()
      |> Enum.flat_map(fn section ->
        [{section.name, 1} | Enum.map(Keyword.keys(section.schema), &{&1, 1})]
      end)
      |> Enum.sort()
    end

    defp formatter_config(source) do
      {config, _binding} = Code.eval_string(source)
      config
    end

    defp package_exported_locals do
      {package_formatter, _binding} = Code.eval_file(".formatter.exs")

      package_formatter
      |> Keyword.get(:export, [])
      |> Keyword.get(:locals_without_parens, [])
      |> Enum.sort()
    end

    test "exports every public Replicant DSL local" do
      assert package_exported_locals() == public_replicant_locals()
    end

    test "the actual install imports and consumes the package formatter export" do
      igniter = project() |> install()
      host_formatter = formatter_config(content(igniter, ".formatter.exs"))
      assert :ash_replicant in Keyword.fetch!(host_formatter, :import_deps)

      imported_locals =
        host_formatter
        |> Keyword.fetch!(:import_deps)
        |> Enum.flat_map(fn
          :ash_replicant -> package_exported_locals()
          _other -> []
        end)

      formatted =
        """
        replicant do
          source_table "orders"
          tenant_attribute :org_id
          sensitive [:pan]
        end
        """
        |> Code.format_string!(locals_without_parens: imported_locals)
        |> IO.iodata_to_binary()
        |> String.trim_trailing()

      assert formatted ==
               String.trim_trailing("""
               replicant do
                 source_table "orders"
                 tenant_attribute :org_id
                 sensitive [:pan]
               end
               """)
    end
  end

  describe "pre-existing project state" do
    test "appends to an existing ash_domains list instead of replacing it" do
      igniter =
        project(%{
          "config/config.exs" => """
          import Config

          config :my_app, ash_domains: [MyApp.Shop]
          """
        })
        |> install()
        |> apply_igniter!()

      config = content(igniter, "config/config.exs")

      assert config =~ "MyApp.Shop"
      assert config =~ "MyApp.Replicant"
    end

    test "joins an existing Ash domain rather than refusing it" do
      igniter =
        project(%{
          ".formatter.exs" => """
          [
            inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
            locals_without_parens: [resource: 1]
          ]
          """,
          "lib/my_app/replicant.ex" => """
          defmodule MyApp.Replicant do
            use Ash.Domain

            resources do
              resource MyApp.Replicant.Something
            end
          end
          """
        })
        |> install()
        |> apply_igniter!()

      source = content(igniter, "lib/my_app/replicant.ex")

      assert source =~ ~r/resource(?:\(|\s+)MyApp\.Replicant\.Something\)?/
      assert source =~ ~r/resource(?:\(|\s+)MyApp\.Replicant\.Checkpoint\)?/
    end

    test "leaves an existing domain untouched when the checkpoint is already listed" do
      igniter =
        project(%{
          ".formatter.exs" => """
          [
            import_deps: [:ash_replicant],
            inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
            locals_without_parens: [resource: 1]
          ]
          """,
          "lib/my_app/replicant.ex" => """
          defmodule MyApp.Replicant do
            use Ash.Domain

            resources do
              resource MyApp.Replicant.Checkpoint
            end
          end
          """
        })
        |> install()

      assert igniter.issues == []
      assert_unchanged(igniter, "lib/my_app/replicant.ex")
    end

    test "creates an application module when the project has none" do
      igniter =
        test_project(app_name: :my_app, files: %{"lib/my_app/repo.ex" => @repo})
        |> install()
        |> apply_igniter!()

      assert content(igniter, "lib/my_app/application.ex") =~ "MyApp.Replicant.Pipeline"
    end
  end

  describe "structural refusals" do
    defp refuse(igniter, argv \\ []) do
      igniter = install(igniter, argv)

      assert [issue] = igniter.issues
      issue
    end

    test "refuses when the project has no repo" do
      issue =
        test_project(app_name: :my_app)
        |> refuse()

      assert issue =~ "AshPostgres"
      assert issue =~ "--repo"
    end

    test "refuses a plain Ecto repo instead of treating it as AshPostgres" do
      issue =
        test_project(
          app_name: :my_app,
          files: %{
            "lib/my_app/repo.ex" => """
            defmodule MyApp.Repo do
              use Ecto.Repo, otp_app: :my_app
            end
            """
          }
        )
        |> refuse()

      assert issue =~ "AshPostgres"
      assert issue =~ "--repo"
    end

    test "does not discover an AshPostgres repo defined only under test support" do
      issue =
        test_project(
          app_name: :my_app,
          files: %{
            "test/support/test_repo.ex" => """
            defmodule MyApp.TestRepo do
              use AshPostgres.Repo, otp_app: :my_app
            end
            """
          }
        )
        |> refuse()

      assert issue =~ "no AshPostgres repo"
    end

    test "refuses an explicit repo that is not an AshPostgres repo in the project" do
      issue = refuse(project(), ["--repo", "MyApp.TypoRepo"])

      assert issue =~ "--repo"
      refute issue =~ "TypoRepo"
    end

    test "refuses when the project has several repos and none was named" do
      issue =
        project(%{
          "lib/my_app/mirror_repo.ex" => """
          defmodule MyApp.MirrorRepo do
            use AshPostgres.Repo, otp_app: :my_app
          end
          """
        })
        |> refuse()

      assert issue =~ "--repo"
      assert issue =~ "MyApp."
    end

    test "refuses an illegal replication slot name" do
      issue = refuse(project(), ["--slot", "Shop-Orders"])

      assert issue =~ "lower-case"
      assert issue =~ "--slot"
    end

    test "refuses to overwrite a foreign module at a target name" do
      issue =
        project(%{
          "lib/my_app/replicant/checkpoint.ex" => """
          defmodule MyApp.Replicant.Checkpoint do
            @moduledoc "Someone else's module."
            def hello, do: :world
          end
          """
        })
        |> refuse()

      assert issue =~ "MyApp.Replicant.Checkpoint"
      assert issue =~ "--checkpoint"
    end

    test "refuses to re-key an existing sink onto a different slot" do
      issue =
        project(%{
          "lib/my_app/replicant/sink.ex" => """
          defmodule MyApp.Replicant.Sink do
            use AshReplicant.Sink,
              repo: MyApp.Repo,
              domains: [],
              checkpoint_resource: MyApp.Replicant.Checkpoint,
              slot_name: "already_live"
          end
          """
        })
        |> refuse(["--slot", "shop_orders"])

      assert issue =~ "already_live"
      assert issue =~ "shop_orders"
      assert issue =~ "checkpoint"
    end

    test "refuses to re-point an existing checkpoint at a different repo" do
      issue =
        project(%{
          "lib/my_app/mirror_repo.ex" => """
          defmodule MyApp.MirrorRepo do
            use AshPostgres.Repo, otp_app: :my_app
          end
          """,
          "lib/my_app/replicant/checkpoint.ex" => """
          defmodule MyApp.Replicant.Checkpoint do
            use AshReplicant.Checkpoint, repo: MyApp.Repo, domain: MyApp.Replicant
          end
          """
        })
        |> refuse(["--repo", "MyApp.MirrorRepo"])

      assert issue =~ "MyApp.Repo"
      assert issue =~ "MyApp.MirrorRepo"
      assert issue =~ "watermark"
    end

    for {label, prelude, use_line} <- [
          {"a module attribute", "@binding MyApp.Repo",
           "use AshReplicant.Checkpoint, repo: @binding, domain: MyApp.Replicant"},
          {"a computed expression", "",
           "use AshReplicant.Checkpoint, repo: Module.concat(MyApp, Repo), domain: MyApp.Replicant"},
          {"a wrong-type literal", "",
           ~s(use AshReplicant.Checkpoint, repo: "MyApp.Repo", domain: MyApp.Replicant)},
          {"a missing key", "", "use AshReplicant.Checkpoint, domain: MyApp.Replicant"},
          {"a missing options argument", "", "use AshReplicant.Checkpoint"}
        ] do
      test "refuses checkpoint binding expressed as #{label}" do
        issue =
          project(%{
            "lib/my_app/replicant/checkpoint.ex" => """
            defmodule MyApp.Replicant.Checkpoint do
              #{unquote(prelude)}
              #{unquote(use_line)}
            end
            """
          })
          |> refuse()

        assert issue =~ "MyApp.Replicant.Checkpoint"
        assert issue =~ "--checkpoint"
        assert issue =~ "literal"
      end
    end

    test "resolves a bare repo alias before comparing an existing checkpoint binding" do
      igniter =
        project(%{
          "lib/my_app/replicant/checkpoint.ex" => """
          defmodule MyApp.Replicant.Checkpoint do
            alias MyApp.Repo
            use AshReplicant.Checkpoint, repo: Repo, domain: MyApp.Replicant
          end
          """
        })
        |> install()

      assert igniter.issues == []
      assert_unchanged(igniter, "lib/my_app/replicant/checkpoint.ex")
    end

    test "refuses a __MODULE__-relative binding without crashing" do
      issue =
        project(%{
          "lib/my_app/replicant/checkpoint.ex" => """
          defmodule MyApp.Replicant.Checkpoint do
            use AshReplicant.Checkpoint,
              repo: __MODULE__.Repo,
              domain: MyApp.Replicant
          end
          """
        })
        |> refuse()

      assert issue =~ "--checkpoint"
      assert issue =~ "literal"
    end

    for {label, prelude, use_line} <- [
          {"a module attribute", ~s(@binding "my_app_replicant"),
           "use AshReplicant.Sink, slot_name: @binding"},
          {"a computed expression", "",
           ~s|use AshReplicant.Sink, slot_name: String.downcase("MY_APP_REPLICANT")|},
          {"a wrong-type literal", "", "use AshReplicant.Sink, slot_name: :my_app_replicant"},
          {"a missing key", "", "use AshReplicant.Sink, repo: MyApp.Repo"},
          {"a missing options argument", "", "use AshReplicant.Sink"}
        ] do
      test "refuses sink binding expressed as #{label}" do
        issue =
          project(%{
            "lib/my_app/replicant/sink.ex" => """
            defmodule MyApp.Replicant.Sink do
              #{unquote(prelude)}
              #{unquote(use_line)}
            end
            """
          })
          |> refuse()

        assert issue =~ "MyApp.Replicant.Sink"
        assert issue =~ "--sink"
        assert issue =~ "literal"
      end
    end

    for {role, path, module, use_target, flag} <- [
          {:domain, "lib/my_app/replicant.ex", "MyApp.Replicant", "Ash.Domain", "--domain"},
          {:checkpoint, "lib/my_app/replicant/checkpoint.ex", "MyApp.Replicant.Checkpoint",
           "AshReplicant.Checkpoint", "--checkpoint"},
          {:sink, "lib/my_app/replicant/sink.ex", "MyApp.Replicant.Sink", "AshReplicant.Sink",
           "--sink"},
          {:pipeline, "lib/my_app/replicant/pipeline.ex", "MyApp.Replicant.Pipeline",
           "AshReplicant.Pipeline", "--pipeline"}
        ] do
      test "a nested #{role} use does not legitimize the foreign target module" do
        path = unquote(path)
        module = unquote(module)

        issue =
          project(%{
            path => """
            defmodule #{module} do
              defmodule Nested do
                use #{unquote(use_target)}
              end
            end
            """
          })
          |> refuse()

        assert issue =~ module
        assert issue =~ unquote(flag)
      end
    end

    test "a later module's use does not legitimize the foreign target module" do
      issue =
        project(%{
          "lib/my_app/replicant/checkpoint.ex" => """
          defmodule MyApp.Replicant.Checkpoint do
            def foreign, do: true
          end

          defmodule MyApp.LaterCheckpoint do
            use AshReplicant.Checkpoint, repo: MyApp.Repo, domain: MyApp.Replicant
          end
          """
        })
        |> refuse()

      assert issue =~ "MyApp.Replicant.Checkpoint"
      assert issue =~ "--checkpoint"
    end

    test "a later module's resource call does not fake a tied-out target domain" do
      igniter =
        project(%{
          "lib/my_app/replicant.ex" => """
          defmodule MyApp.Replicant do
            use Ash.Domain
          end

          defmodule MyApp.LaterDomain do
            use Ash.Domain

            resources do
              resource MyApp.Replicant.Checkpoint
            end
          end
          """
        })
        |> install()
        |> apply_igniter!()

      target = content(igniter, "lib/my_app/replicant.ex")

      [target_module, _later_module] =
        String.split(target, "defmodule MyApp.LaterDomain", parts: 2)

      assert target_module =~ ~r/resource(?:\(|\s+)MyApp\.Replicant\.Checkpoint\)?/
    end

    test "a refused run exits non-zero instead of reporting success" do
      # Igniter's default `run/1` prints the issues and returns `:issues`, which
      # would leave the task exiting 0 — `mix ash_replicant.install &&
      # mix ecto.migrate` would then migrate against a project that was never
      # installed. Exercising `run/1` itself would run the installer against THIS
      # repo, so the decision it delegates to is what is pinned here.
      assert catch_exit(Task.exit_status(:issues)) == {:shutdown, 1}

      assert Task.exit_status(:changes_made) == :changes_made
      assert Task.exit_status(:dry_run_with_no_changes) == :dry_run_with_no_changes
    end

    test "a refusal writes nothing at all" do
      igniter = install(project(), ["--slot", "Shop-Orders"])

      assert igniter.issues != []
      refute_creates(igniter, "lib/my_app/replicant/checkpoint.ex")
      refute_creates(igniter, "lib/my_app/replicant/sink.ex")
      refute_creates(igniter, "lib/my_app/replicant/pipeline.ex")
      assert igniter.tasks == []
      refute_creates(igniter, "config/config.exs")
    end
  end

  describe "the igniter-absent fallback" do
    @task_source "lib/mix/tasks/ash_replicant.install.ex"

    # This repo always has Igniter, so the `else` branch of the task's
    # `Code.ensure_loaded?(Igniter)` guard NEVER compiles here — yet it is the
    # branch every consumer without Igniter gets. Compile it under a different
    # name so a shipped, otherwise-unexercised path cannot rot silently.
    defp fallback_module do
      [_with_igniter, fallback] = String.split(File.read!(@task_source), "\nelse\n", parts: 2)

      source =
        fallback
        |> String.trim_trailing()
        |> String.trim_trailing("end")
        |> String.replace(
          "defmodule Mix.Tasks.AshReplicant.Install do",
          "defmodule AshReplicant.InstallTaskTest.Fallback do"
        )

      [{module, _binary}] = Code.compile_string(source, @task_source)
      module
    end

    test "compiles, and tells the operator how to proceed without igniter" do
      module = fallback_module()

      assert function_exported?(module, :run, 1)

      previous = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      try do
        assert catch_exit(module.run([])) == {:shutdown, 1}
      after
        Mix.shell(previous)
        :code.purge(module)
        :code.delete(module)
      end

      assert_received {:mix_shell, :error, [message]}

      assert message =~ "igniter"
      assert message =~ "mix igniter.install ash_replicant"
      assert message =~ "Manual installation"
    end
  end

  describe "the documented manual path and the installer agree" do
    @manual_start "<!-- ash-replicant-manual-install-modules:start -->"
    @manual_end "<!-- ash-replicant-manual-install-modules:end -->"

    # `{module, use_target, sorted_use_options}` for every `defmodule` in a
    # source, with all AST metadata stripped. Formatting, line numbers, comments,
    # and option ORDER are free to differ; the bindings are not.
    defp contracts(source) do
      source
      |> Code.string_to_quoted!()
      |> strip_meta()
      |> collect_modules()
      |> Enum.sort()
    end

    defp strip_meta(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _meta -> [] end))

    defp collect_modules(ast) do
      {_ast, modules} =
        Macro.prewalk(ast, [], fn
          {:defmodule, _, [name, [do: body]]} = node, acc ->
            {node, [{alias_name(name), uses(body)} | acc]}

          node, acc ->
            {node, acc}
        end)

      modules
    end

    defp uses(body) do
      {_ast, found} =
        Macro.prewalk(body, [], fn
          {:use, _, [target | rest]} = node, acc ->
            {node, [{alias_name(target), options(rest)} | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.sort(found)
    end

    defp options([options]) when is_list(options), do: Enum.sort(options)
    defp options(_none), do: []

    defp alias_name({:__aliases__, _, parts}), do: Module.concat(parts)
    defp alias_name(other), do: other

    defp manual_block do
      readme = File.read!("README.md")

      [_before, rest] = String.split(readme, @manual_start, parts: 2)
      [block, _after] = String.split(rest, @manual_end, parts: 2)

      block
      |> String.trim()
      |> String.trim_leading("```elixir")
      |> String.trim_trailing("```")
    end

    test "the README's manual block declares exactly what the installer generates" do
      igniter = project() |> install() |> apply_igniter!()

      generated =
        [
          "lib/my_app/replicant.ex",
          "lib/my_app/replicant/checkpoint.ex",
          "lib/my_app/replicant/sink.ex",
          "lib/my_app/replicant/pipeline.ex"
        ]
        |> Enum.flat_map(&contracts(content(igniter, &1)))
        |> Enum.sort()

      assert contracts(manual_block()) == generated
    end

    test "the manual block is not vacuous" do
      contracts = contracts(manual_block())

      assert length(contracts) == 4

      assert {MyApp.Replicant.Sink,
              [
                {AshReplicant.Sink,
                 [
                   {:checkpoint_resource, _},
                   {:domains, []},
                   {:repo, _},
                   {:slot_name, "my_app_replicant"}
                 ]}
              ]} = List.keyfind(contracts, MyApp.Replicant.Sink, 0)
    end
  end

  describe "the generated code compiles against the shipped macros" do
    # Resolved at RUNTIME: these modules exist only once `Code.compile_string`
    # has run, so a compile-time reference would warn about an undefined module.
    defp generated(suffix), do: Module.concat([AshReplicant, :Generated, suffix])

    test "the four generated modules load and expose the real contract" do
      igniter =
        project(%{
          "lib/ash_replicant/test_repo.ex" => """
          defmodule AshReplicant.TestRepo do
            use AshPostgres.Repo, otp_app: :ash_replicant
          end
          """
        })
        |> install([
          "--repo",
          "AshReplicant.TestRepo",
          "--domain",
          "AshReplicant.Generated.Domain",
          "--checkpoint",
          "AshReplicant.Generated.Checkpoint",
          "--sink",
          "AshReplicant.Generated.Sink",
          "--pipeline",
          "AshReplicant.Generated.Pipeline",
          "--slot",
          "generated_install_slot"
        ])
        |> apply_igniter!()

      source =
        Enum.map_join(
          [
            "lib/ash_replicant/generated/domain.ex",
            "lib/ash_replicant/generated/checkpoint.ex",
            "lib/ash_replicant/generated/sink.ex",
            "lib/ash_replicant/generated/pipeline.ex"
          ],
          "\n",
          &content(igniter, &1)
        )

      # Compiling a domain outside this suite's own `ash_domains` config warns on
      # stderr; a real host has it registered by the installer's config step.
      capture =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(self(), {:compiled, Code.compile_string(source)})
        end)

      assert is_binary(capture)
      assert_received {:compiled, compiled}
      modules = Enum.map(compiled, fn {module, _binary} -> module end)

      for suffix <- [:Domain, :Checkpoint, :Sink, :Pipeline] do
        assert generated(suffix) in modules
      end

      checkpoint = generated(:Checkpoint)
      sink = generated(:Sink)
      pipeline = generated(:Pipeline)

      # The sink really is a Replicant.Sink bound to the requested slot.
      assert %{slot_name: "generated_install_slot"} = sink.__ash_replicant_config__()

      # The checkpoint really is the bundled AshPostgres resource.
      assert Ash.Resource.Info.data_layer(checkpoint) == AshPostgres.DataLayer
      assert AshPostgres.DataLayer.Info.table(checkpoint) == "ash_replicant_checkpoints"

      # And the pipeline really boots as a no-op until an operator configures it.
      assert pipeline.children() == []
    end
  end
end
