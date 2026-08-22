defmodule AshReplicant.Pipeline do
  @moduledoc """
  The generated operator wiring: a host supervisor for one sink's pipeline owner.

      defmodule MyApp.Replicant.Pipeline do
        use AshReplicant.Pipeline, otp_app: :my_app, sink: MyApp.Replicant.Sink
      end

  Add it to the application's children once and never touch it again:

      children = [
        MyApp.Repo,
        MyApp.Replicant.Pipeline
      ]

  `mix ash_replicant.install` generates exactly the three lines above; the
  behaviour lives here so a host never hand-rolls (and never drifts from) the
  lifecycle contract in
  [ADR-0014](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0014-internal-trust-and-lifecycle-ownership.md).

  ## A fresh install starts nothing

  The connection, publication, and source identity are facts only the operator
  has, so a freshly installed pipeline supervises NOTHING until they are
  configured:

      config :my_app, MyApp.Replicant.Pipeline,
        connection: [hostname: "standby.example.com", database: "source_db"],
        publication: "shop_orders_pub",
        source_identity: [system_identifier: "7378697629483820647", database: "source_db"],
        go_forward_only: true

  Absent, `nil`, `false`, and `[]` all mean "not configured" — the supervisor
  boots with zero children, so a blank install compiles and runs. Every other key
  is passed to `AshReplicant.PipelineOwner` untouched (`snapshot:`, `census:`,
  `max_inflight_lag:`, …); this module owns no start-option vocabulary of its
  own beyond the three it requires.

  ## A half-configured pipeline fails closed

  A configuration that is present but missing `:connection`, `:publication`, or
  `:source_identity` RAISES rather than supervising nothing. Supervising nothing
  would be a silent outage: the app boots, the tree is healthy, and no data ever
  arrives. The same holds for a `sink:` in config that contradicts the sink the
  module declares.

  Those messages name the missing KEYS and never their values — pipeline
  configuration carries connection credentials, and the value-free rule covers
  this boundary like every other.

  ## Restart posture

  The pipeline supervisor is `:permanent`; the owner inside it is `:temporary`
  (`AshReplicant.PipelineOwner.child_spec/1`). A halt is a permanent decision, so
  a halted owner is not restarted into a source it already refused — the
  supervisor simply stays up with no children until the operator acts.
  """

  @required_options [:connection, :publication, :source_identity]

  @macro_options [:otp_app, :sink]

  @doc false
  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    sink = Keyword.fetch!(opts, :sink)

    # Fail closed on an unknown key, exactly as `AshReplicant.Sink` does: a
    # mistyped or removed option must be a compile error on the host, never a
    # silent no-op that leaves the pipeline configured differently than read.
    case Keyword.drop(opts, @macro_options) do
      [] ->
        :ok

      extra ->
        raise ArgumentError,
              "unknown AshReplicant.Pipeline option(s) #{inspect(Keyword.keys(extra))} — " <>
                "the generated pipeline admits only :otp_app and :sink. Pipeline start " <>
                "options are runtime configuration, not macro options."
    end

    quote do
      use Supervisor

      @ash_replicant_otp_app unquote(otp_app)
      @ash_replicant_sink unquote(sink)

      @doc """
      Start the pipeline supervisor. Supervises nothing until
      `config #{inspect(unquote(otp_app))}, #{inspect(__MODULE__)}` supplies the
      operator's connection facts.
      """
      def start_link(init_arg \\ []) do
        Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
      end

      @impl Supervisor
      def init(_init_arg) do
        Supervisor.init(children(), strategy: :one_for_one)
      end

      @doc """
      The child specs this pipeline supervises: one `:temporary`
      `AshReplicant.PipelineOwner`, or none while unconfigured.

      Raises when the configuration is present but incomplete.
      """
      def children do
        AshReplicant.Pipeline.children(
          @ash_replicant_otp_app,
          __MODULE__,
          @ash_replicant_sink
        )
      end

      @doc """
      The admitted owner start options — `:not_configured`, or `{:ok, options}`
      with this module's declared sink injected.

      Raises when the configuration is present but incomplete, or names a
      different sink.
      """
      def start_options do
        AshReplicant.Pipeline.start_options(
          @ash_replicant_otp_app,
          __MODULE__,
          @ash_replicant_sink
        )
      end
    end
  end

  @doc false
  @spec children(atom(), module(), module()) :: [Supervisor.child_spec()]
  def children(otp_app, module, sink) do
    case start_options(otp_app, module, sink) do
      :not_configured -> []
      {:ok, options} -> [Supervisor.child_spec({AshReplicant.PipelineOwner, options}, [])]
    end
  end

  @doc false
  @spec start_options(atom(), module(), module()) :: :not_configured | {:ok, keyword()}
  def start_options(otp_app, module, sink) do
    case Application.get_env(otp_app, module) do
      configured when configured in [nil, false, []] ->
        :not_configured

      configured ->
        if Keyword.keyword?(configured) do
          {:ok, admit(configured, otp_app, module, sink)}
        else
          raise ArgumentError, non_keyword_message(otp_app, module)
        end
    end
  end

  defp admit(options, otp_app, module, sink) do
    :ok = require_options!(options, otp_app, module)
    :ok = admit_sink!(options, module, sink)

    Keyword.put(options, :sink, sink)
  end

  defp require_options!(options, otp_app, module) do
    case Enum.reject(@required_options, &supplied?(options, &1)) do
      [] -> :ok
      missing -> raise ArgumentError, missing_message(missing, otp_app, module)
    end
  end

  # A key present but empty is not supplied: `publication: ""` would reach
  # activation as a config error far from the operator who wrote it.
  defp supplied?(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} when value in [nil, false, "", []] -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  defp admit_sink!(options, module, sink) do
    case Keyword.fetch(options, :sink) do
      :error -> :ok
      {:ok, ^sink} -> :ok
      {:ok, other} -> raise ArgumentError, sink_message(module, sink, other)
    end
  end

  defp missing_message(missing, otp_app, module) do
    """
    #{inspect(module)} is configured but incomplete: #{inspect(missing)} missing.

    AshReplicant will not supervise a partially-configured pipeline — an owner that \
    never starts is a silent outage, not a safe default. Supply every required key:

        config #{inspect(otp_app)}, #{inspect(module)},
          connection: [hostname: "...", database: "..."],
          publication: "...",
          source_identity: [system_identifier: "...", database: "..."]

    Only the PRESENCE of each key is checked here; the values are never read, \
    inspected, or logged.
    """
  end

  defp non_keyword_message(otp_app, module) do
    """
    #{inspect(module)} is configured with a value that is not a keyword list.

    Pipeline start options are the keyword list handed to \
    `AshReplicant.PipelineOwner`:

        config #{inspect(otp_app)}, #{inspect(module)},
          connection: [hostname: "...", database: "..."],
          publication: "...",
          source_identity: [system_identifier: "...", database: "..."]

    The offending value is not shown: pipeline configuration carries connection \
    credentials.
    """
  end

  defp sink_message(module, declared, _configured) do
    """
    #{inspect(module)} declares sink #{inspect(declared)}, but its configuration sets a \
    different `sink:` value.

    One generated pipeline supervises one sink's owner, and the declared sink is what \
    fixes the replication slot this pipeline serves. Remove the `sink:` key from \
    configuration, or generate a second pipeline for the other sink:

        mix ash_replicant.install --sink MyApp.OtherSink --pipeline #{inspect(module)}.Secondary
    """
  end
end
