defmodule AshReplicant.InstallPlanTest do
  @moduledoc """
  The install PLANNER (I01) — the pure half of `mix ash_replicant.install`.

  Every structural refusal the installer can raise is decided here, with no
  Igniter, no filesystem, and no project: the task's only job is to gather the
  facts (`existing`, `repos`) and render the decision. That keeps the refusals —
  the part whose failure is quiet and expensive — testable at unit speed.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Install
  alias AshReplicant.Install.Error

  defp plan(overrides \\ []) do
    [
      otp_app: :my_app,
      prefix: MyApp,
      options: %{},
      repos: [MyApp.Repo],
      existing: %{}
    ]
    |> Keyword.merge(overrides)
    |> Install.plan()
  end

  describe "artifact names" do
    test "default to the app prefix's Replicant namespace" do
      assert %{
               domain: MyApp.Replicant,
               checkpoint: MyApp.Replicant.Checkpoint,
               sink: MyApp.Replicant.Sink,
               pipeline: MyApp.Replicant.Pipeline
             } = Install.artifacts(MyApp, %{})
    end

    test "each name is individually overridable by its flag" do
      artifacts =
        Install.artifacts(MyApp, %{
          domain: "MyApp.Mirror",
          checkpoint: "MyApp.Mirror.Watermark",
          sink: "MyApp.Mirror.OrdersSink",
          pipeline: "MyApp.Mirror.OrdersPipeline"
        })

      assert artifacts == %{
               domain: MyApp.Mirror,
               checkpoint: MyApp.Mirror.Watermark,
               sink: MyApp.Mirror.OrdersSink,
               pipeline: MyApp.Mirror.OrdersPipeline
             }
    end

    test "an Elixir.-prefixed flag value parses to the same module" do
      assert %{sink: MyApp.Mirror.OrdersSink} =
               Install.artifacts(MyApp, %{sink: "Elixir.MyApp.Mirror.OrdersSink"})
    end
  end

  describe "a clean project" do
    test "plans every artifact for creation and derives the slot name from the app" do
      assert {:ok, plan} = plan()

      assert plan.otp_app == :my_app
      assert plan.repo == MyApp.Repo
      assert plan.slot_name == "my_app_replicant"

      assert plan.domain == %{module: MyApp.Replicant, create?: true}
      assert plan.checkpoint == %{module: MyApp.Replicant.Checkpoint, create?: true}
      assert plan.sink == %{module: MyApp.Replicant.Sink, create?: true}
      assert plan.pipeline == %{module: MyApp.Replicant.Pipeline, create?: true}
    end

    test "an explicit --slot wins over the derived name" do
      assert {:ok, plan} = plan(options: %{slot: "shop_orders"})
      assert plan.slot_name == "shop_orders"
    end

    test "an explicit --repo wins over discovery" do
      assert {:ok, plan} = plan(options: %{repo: "MyApp.Mirror.Repo"}, repos: [MyApp.Repo])
      assert plan.repo == MyApp.Mirror.Repo
    end
  end

  describe "slot name refusal" do
    for {label, slot} <- [
          {"upper case", "ShopOrders"},
          {"a hyphen", "shop-orders"},
          {"a dot", "shop.orders"},
          {"whitespace", "shop orders"},
          {"empty", ""},
          {"a quote", ~s(shop"orders)}
        ] do
      test "refuses a slot name containing #{label}" do
        assert {:error, %Error{reason: :slot_name_invalid} = error} =
                 plan(options: %{slot: unquote(slot)})

        message = Exception.message(error)
        assert message =~ "--slot"
        assert message =~ "lower-case"
      end
    end

    test "refuses a slot name longer than PostgreSQL's 63-character limit" do
      assert {:error, %Error{reason: :slot_name_invalid}} =
               plan(options: %{slot: String.duplicate("a", 64)})

      assert {:ok, plan} = plan(options: %{slot: String.duplicate("a", 63)})
      assert plan.slot_name == String.duplicate("a", 63)
    end

    test "accepts the legal alphabet" do
      assert {:ok, plan} = plan(options: %{slot: "shop_orders_9"})
      assert plan.slot_name == "shop_orders_9"
    end
  end

  describe "repo refusal" do
    test "refuses when the project has no repo and none was named" do
      assert {:error, %Error{reason: :repo_required} = error} = plan(repos: [])

      message = Exception.message(error)
      assert message =~ "--repo"
      assert message =~ "AshPostgres"
    end

    test "refuses when the project has several repos and none was named" do
      assert {:error, %Error{reason: :repo_ambiguous} = error} =
               plan(repos: [MyApp.Repo, MyApp.OtherRepo])

      message = Exception.message(error)
      assert message =~ "--repo"
      assert message =~ "MyApp.OtherRepo"
    end

    test "an explicit --repo resolves both refusals" do
      assert {:ok, %{repo: MyApp.Repo}} = plan(repos: [], options: %{repo: "MyApp.Repo"})

      assert {:ok, %{repo: MyApp.OtherRepo}} =
               plan(repos: [MyApp.Repo, MyApp.OtherRepo], options: %{repo: "MyApp.OtherRepo"})
    end
  end

  describe "pre-existing module refusal" do
    for {role, flag} <- [
          domain: "--domain",
          checkpoint: "--checkpoint",
          sink: "--sink",
          pipeline: "--pipeline"
        ] do
      test "refuses to overwrite a foreign #{role} module" do
        role = unquote(role)

        assert {:error, %Error{reason: :module_conflict, artifact: artifact} = error} =
                 plan(existing: %{role => :foreign})

        assert artifact == Map.fetch!(Install.artifacts(MyApp, %{}), role)

        message = Exception.message(error)
        assert message =~ inspect(artifact)
        assert message =~ unquote(flag)
      end
    end

    test "reuses an artifact this installer already generated" do
      assert {:ok, plan} =
               plan(
                 existing: %{
                   domain: :ash_domain,
                   checkpoint: {:ash_replicant, MyApp.Repo},
                   sink: {:ash_replicant, "my_app_replicant"},
                   pipeline: {:ash_replicant, MyApp.Replicant.Sink}
                 }
               )

      assert plan.domain == %{module: MyApp.Replicant, create?: false}
      assert plan.checkpoint == %{module: MyApp.Replicant.Checkpoint, create?: false}
      assert plan.sink == %{module: MyApp.Replicant.Sink, create?: false}
      assert plan.pipeline == %{module: MyApp.Replicant.Pipeline, create?: false}
    end

    test "an existing artifact whose binding cannot be read is reused, not rewritten" do
      assert {:ok, plan} =
               plan(
                 existing: %{
                   checkpoint: {:ash_replicant, nil},
                   sink: {:ash_replicant, nil},
                   pipeline: {:ash_replicant, nil}
                 }
               )

      assert plan.checkpoint.create? == false
      assert plan.sink.create? == false
      assert plan.pipeline.create? == false
    end
  end

  describe "binding-drift refusal" do
    test "refuses to re-point an existing checkpoint at a different repo" do
      assert {:error, %Error{reason: :checkpoint_repo_mismatch} = error} =
               plan(
                 options: %{repo: "MyApp.OtherRepo"},
                 existing: %{checkpoint: {:ash_replicant, MyApp.Repo}}
               )

      message = Exception.message(error)
      assert message =~ inspect(MyApp.Repo)
      assert message =~ inspect(MyApp.OtherRepo)
      assert message =~ "--repo"
      assert message =~ "watermark"
    end

    test "refuses to re-key an existing sink onto a different slot" do
      assert {:error, %Error{reason: :sink_slot_mismatch} = error} =
               plan(
                 options: %{slot: "shop_orders"},
                 existing: %{sink: {:ash_replicant, "my_app_replicant"}}
               )

      message = Exception.message(error)
      assert message =~ "my_app_replicant"
      assert message =~ "shop_orders"
      assert message =~ "--slot"
      assert message =~ "checkpoint"
    end

    test "refuses to re-point an existing pipeline at a different sink" do
      assert {:error, %Error{reason: :pipeline_sink_mismatch} = error} =
               plan(
                 options: %{sink: "MyApp.Mirror.OrdersSink"},
                 existing: %{pipeline: {:ash_replicant, MyApp.Replicant.Sink}}
               )

      message = Exception.message(error)
      assert message =~ inspect(MyApp.Replicant.Sink)
      assert message =~ inspect(MyApp.Mirror.OrdersSink)
      assert message =~ "--sink"
    end

    test "an existing sink bound to the requested slot is not drift" do
      assert {:ok, plan} =
               plan(
                 options: %{slot: "my_app_replicant"},
                 existing: %{sink: {:ash_replicant, "my_app_replicant"}}
               )

      assert plan.sink.create? == false
    end

    test "a pipeline bound to an explicitly renamed sink is not drift" do
      assert {:ok, plan} =
               plan(
                 options: %{sink: "MyApp.Mirror.OrdersSink"},
                 existing: %{pipeline: {:ash_replicant, MyApp.Mirror.OrdersSink}}
               )

      assert plan.pipeline.create? == false
    end
  end

  describe "refusal precedence" do
    test "an illegal slot is reported before any project-state refusal" do
      assert {:error, %Error{reason: :slot_name_invalid}} =
               plan(options: %{slot: "BAD"}, repos: [], existing: %{checkpoint: :foreign})
    end

    test "a missing repo is reported before a module conflict" do
      assert {:error, %Error{reason: :repo_required}} =
               plan(repos: [], existing: %{checkpoint: :foreign})
    end
  end

  describe "value-free messages" do
    test "no refusal message carries a connection, publication, or secret" do
      errors = [
        plan(options: %{slot: "BAD"}),
        plan(repos: []),
        plan(repos: [MyApp.Repo, MyApp.OtherRepo]),
        plan(existing: %{checkpoint: :foreign}),
        plan(
          options: %{repo: "MyApp.OtherRepo"},
          existing: %{checkpoint: {:ash_replicant, MyApp.Repo}}
        ),
        plan(
          options: %{slot: "shop_orders"},
          existing: %{sink: {:ash_replicant, "my_app_replicant"}}
        )
      ]

      for {:error, error} <- errors do
        message = Exception.message(error)

        refute message =~ ~r/password|hostname|secret|source_identity|system_identifier/i
        assert message =~ ~r/[a-z]/
      end
    end
  end
end
