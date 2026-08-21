defmodule AshReplicant.InstallPipelineTest do
  @moduledoc """
  `AshReplicant.Pipeline` (I01) — the generated operator wiring.

  The installer puts a three-line module in the host app and this macro carries
  the behaviour, so a host never hand-rolls (and never drifts from) the
  supervision contract in ADR-0014. Two properties matter and both are proven
  here: a FRESH install boots as a no-op (nothing is started until the operator
  supplies real connection facts), and a HALF-supplied configuration fails
  closed and loud instead of quietly supervising nothing.
  """

  use ExUnit.Case, async: false

  defmodule Sink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "install_pipeline_slot"
  end

  defmodule OtherSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "install_pipeline_other_slot"
  end

  defmodule Pipeline do
    @moduledoc false
    use AshReplicant.Pipeline, otp_app: :ash_replicant, sink: Sink
  end

  @connection [hostname: "standby.example.test", database: "source_db"]
  @identity [system_identifier: "7378697629483820647", database: "source_db"]

  @complete [
    connection: @connection,
    publication: "install_pipeline_pub",
    source_identity: @identity
  ]

  setup do
    previous = Application.get_env(:ash_replicant, Pipeline, :__absent__)

    on_exit(fn ->
      # Restore DELETES when the key was unset — putting :__absent__ back would
      # leave a poisoned value behind for the next test.
      case previous do
        :__absent__ -> Application.delete_env(:ash_replicant, Pipeline)
        value -> Application.put_env(:ash_replicant, Pipeline, value)
      end
    end)

    :ok
  end

  defp configure(value), do: Application.put_env(:ash_replicant, Pipeline, value)

  describe "a fresh install supervises nothing" do
    test "an unconfigured pipeline reports no children" do
      Application.delete_env(:ash_replicant, Pipeline)

      assert Pipeline.start_options() == :not_configured
      assert Pipeline.children() == []
    end

    for {label, value} <- [{"an empty keyword list", []}, {"false", false}, {"nil", nil}] do
      test "#{label} is treated as not configured" do
        configure(unquote(Macro.escape(value)))

        assert Pipeline.start_options() == :not_configured
        assert Pipeline.children() == []
      end
    end

    test "it starts and stops as a live no-op supervisor" do
      Application.delete_env(:ash_replicant, Pipeline)

      assert {:ok, supervisor} = Pipeline.start_link()
      assert Supervisor.which_children(supervisor) == []
      assert Supervisor.count_children(supervisor).active == 0

      :ok = Supervisor.stop(supervisor)
    end
  end

  describe "a configured pipeline" do
    test "hands the owner the operator options with the sink injected" do
      configure(@complete)

      assert {:ok, options} = Pipeline.start_options()
      assert Keyword.fetch!(options, :sink) == Sink
      assert Keyword.fetch!(options, :connection) == @connection
      assert Keyword.fetch!(options, :publication) == "install_pipeline_pub"
      assert Keyword.fetch!(options, :source_identity) == @identity
    end

    test "passes optional start options through untouched" do
      configure(@complete ++ [go_forward_only: true, census: [interval_ms: 60_000]])

      assert {:ok, options} = Pipeline.start_options()
      assert Keyword.fetch!(options, :go_forward_only) == true
      assert Keyword.fetch!(options, :census) == [interval_ms: 60_000]
    end

    test "supervises exactly one temporary owner child" do
      configure(@complete)

      assert [child] = Pipeline.children()
      assert %{start: {AshReplicant.PipelineOwner, :start_link, [options]}} = child

      # ADR-0014: a halt is permanent — the owner is :temporary under the host
      # supervisor, never restarted into a source it already refused.
      assert child.restart == :temporary
      assert child.id == {AshReplicant.PipelineOwner, "install_pipeline_slot"}
      assert Keyword.fetch!(options, :sink) == Sink
    end

    test "the declared sink may be restated but never contradicted" do
      configure(@complete ++ [sink: Sink])
      assert {:ok, options} = Pipeline.start_options()
      assert Keyword.fetch!(options, :sink) == Sink
    end
  end

  describe "a half-configured pipeline fails closed" do
    for {label, dropped} <- [
          {"connection", :connection},
          {"publication", :publication},
          {"source identity", :source_identity}
        ] do
      test "raises when #{label} is missing" do
        configure(Keyword.delete(@complete, unquote(dropped)))

        error = assert_raise ArgumentError, fn -> Pipeline.start_options() end
        message = Exception.message(error)

        assert message =~ to_string(unquote(dropped))
        assert message =~ inspect(Pipeline)
        assert message =~ ":ash_replicant"
      end
    end

    test "names every missing key at once" do
      configure(publication: "install_pipeline_pub")

      error = assert_raise ArgumentError, fn -> Pipeline.start_options() end
      assert Exception.message(error) =~ inspect([:connection, :source_identity])
    end

    for {label, empty} <- [
          {"an empty string", ""},
          {"an empty list", []},
          {"nil", nil},
          {"false", false}
        ] do
      test "treats a required key present as #{label} as missing" do
        configure(Keyword.put(@complete, :publication, unquote(Macro.escape(empty))))

        error = assert_raise ArgumentError, fn -> Pipeline.start_options() end
        assert Exception.message(error) =~ inspect([:publication])
      end
    end

    test "children/0 raises rather than silently supervising nothing" do
      configure(Keyword.delete(@complete, :publication))

      assert_raise ArgumentError, fn -> Pipeline.children() end
    end

    test "refuses a configured sink that contradicts the declared one" do
      configure(@complete ++ [sink: OtherSink])

      error = assert_raise ArgumentError, fn -> Pipeline.start_options() end
      message = Exception.message(error)

      assert message =~ inspect(Sink)
      assert message =~ inspect(OtherSink)
    end

    test "refuses a configuration that is not a keyword list" do
      configure(%{connection: @connection})

      error = assert_raise ArgumentError, fn -> Pipeline.start_options() end
      assert Exception.message(error) =~ "keyword list"
    end
  end

  describe "value-free diagnosis" do
    test "a fail-closed message names keys, never their values" do
      configure(Keyword.delete(@complete, :publication))

      error = assert_raise(ArgumentError, fn -> Pipeline.start_options() end)
      message = Exception.message(error)

      refute message =~ "standby.example.test"
      refute message =~ "source_db"
      refute message =~ "7378697629483820647"
    end

    test "a non-keyword message does not inspect the offending value" do
      configure(%{connection: [password: "hunter2"]})

      error = assert_raise(ArgumentError, fn -> Pipeline.start_options() end)
      message = Exception.message(error)

      refute message =~ "hunter2"
      refute message =~ "password"
    end
  end

  describe "compile-time option refusal" do
    test "rejects an unknown option so a removed key cannot silently no-op" do
      assert_raise ArgumentError, ~r/:census_interval/, fn ->
        Code.compile_string("""
        defmodule AshReplicant.InstallPipelineTest.UnknownOption do
          use AshReplicant.Pipeline,
            otp_app: :ash_replicant,
            sink: AshReplicant.InstallPipelineTest.Sink,
            census_interval: 1000
        end
        """)
      end
    end

    test "requires :otp_app" do
      assert_raise KeyError, fn ->
        Code.compile_string("""
        defmodule AshReplicant.InstallPipelineTest.MissingOtpApp do
          use AshReplicant.Pipeline, sink: AshReplicant.InstallPipelineTest.Sink
        end
        """)
      end
    end

    test "requires :sink" do
      assert_raise KeyError, fn ->
        Code.compile_string("""
        defmodule AshReplicant.InstallPipelineTest.MissingSink do
          use AshReplicant.Pipeline, otp_app: :ash_replicant
        end
        """)
      end
    end
  end
end
