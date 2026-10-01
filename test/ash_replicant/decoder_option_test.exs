defmodule AshReplicant.DecoderOptionTest do
  @moduledoc """
  The Replicant 1.4 decoder-option contract (ADR-0026): every transport
  option Replicant 1.4 accepts is FORWARDED (`decoder:`, `replication_sets:`,
  `tables:`, `allow_keyless_tables:`, `schema_check_interval:`), and the
  adapter ADMITS all three decoders — the table-set key names the source for
  the adapter's own census (`AshReplicant.SourceSet`), the rest of the
  grammar is the transport's own validation surfaced raw. The port-1
  (unreachable) fixtures ride the deferred-preflight path, so admission is
  observable without a plugin substrate; the plugin census itself runs live
  in the integration decoder lane.
  """

  use ExUnit.Case, async: false

  # The unreachable-port fixture (port 1) lets Postgrex fail to connect and
  # retry; its protocol-level [error] logs are expected test behavior — the
  # ADMITTED starts are wrapped in capture_log so the retry logs stay inside
  # a window and the pipeline is stopped before it ends (the structural
  # harness counts uncontrolled [error] lines).
  @moduletag capture_log: true

  import ExUnit.CaptureLog

  defmodule DecoderSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "decoder_slot"
  end

  @source_identity [system_identifier: "741852963", database: "postgres"]

  defp start_opts(extra \\ []) do
    Keyword.merge(
      [
        sink: DecoderSink,
        connection: [
          hostname: "127.0.0.1",
          port: 1,
          username: "postgres",
          database: "postgres",
          # Tight queue bounds make the port-1 refusal deterministic (the
          # start_link_test fixture precedent): nothing under test depends on
          # how long the refusal takes.
          queue_target: 5,
          queue_interval: 50,
          pool_timeout: 250,
          timeout: 250
        ],
        publication: "decoder_pub",
        source_identity: @source_identity,
        go_forward_only: true
      ],
      extra
    )
  end

  setup do
    on_exit(fn ->
      AshReplicant.stop_supervised("decoder_slot")
      :persistent_term.erase({AshReplicant, "decoder_slot"})
    end)

    AshReplicant.stop_supervised("decoder_slot")
    :persistent_term.erase({AshReplicant, "decoder_slot"})
    :ok
  end

  describe "the admission rule — one table-set key per decoder" do
    # Load-budget class (the start_link_test note): every port-1 activation
    # walks the code fingerprint through the serialized code server.
    @tag timeout: 180_000
    test "a wal2json config with tables: (and no publication) is admitted" do
      capture_log(fn ->
        opts =
          start_opts()
          |> Keyword.delete(:publication)
          |> Keyword.merge(decoder: :wal2json, tables: [{"public", "orders"}])

        assert {:ok, _pid} = AshReplicant.start_link(opts)
        assert match?(%AshReplicant.Destination.Generation{}, pipeline_entry())
        assert entry_source_set().decoder == :wal2json

        :ok = AshReplicant.stop_supervised("decoder_slot")
        assert :none == pipeline_entry()
      end)
    end

    @tag timeout: 180_000
    test "a pglogical config with replication_sets: is admitted" do
      capture_log(fn ->
        opts =
          start_opts()
          |> Keyword.delete(:publication)
          |> Keyword.merge(decoder: :pglogical, replication_sets: ["default"])

        assert {:ok, _pid} = AshReplicant.start_link(opts)
        assert entry_source_set().decoder == :pglogical

        :ok = AshReplicant.stop_supervised("decoder_slot")
        assert :none == pipeline_entry()
      end)
    end

    test "a plugin config missing its table-set key fails with the config atom" do
      assert {:error, :config_invalid} =
               AshReplicant.start_link(
                 start_opts(decoder: :wal2json)
                 |> Keyword.delete(:publication)
               )

      assert {:error, :config_invalid} =
               AshReplicant.start_link(
                 start_opts(decoder: :pglogical)
                 |> Keyword.delete(:publication)
               )

      assert :persistent_term.get({AshReplicant, "decoder_slot"}, :none) == :none
    end

    test "a wal2json config with a malformed tables list fails closed" do
      assert {:error, :config_invalid} =
               AshReplicant.start_link(
                 start_opts(tables: ["public.orders"], decoder: :wal2json)
                 |> Keyword.delete(:publication)
               )
    end

    test "the doctor plan admits a plugin config (the unreachable source reports skipped, not invalid)" do
      opts =
        start_opts()
        |> Keyword.delete(:publication)
        |> Keyword.merge(decoder: :wal2json, tables: [{"public", "orders"}])

      report = AshReplicant.preflight(opts)

      # The plan BUILDS: an unreachable source is the probe-failure class
      # (exit 1/2 with skipped source checks), never exit 3 (undiagnosable).
      # The new :source_plugin check rides the same skip class; its
      # wal2json `:plugin_presence_not_provable` shape is asserted on the
      # reachable source in the integration decoder lane.
      assert report.status in [:fail, :warn]
      assert report.exit_code in [1, 2]

      assert Enum.any?(
               report.checks,
               &(&1.name == :source_plugin and &1.reason == :source_unreachable)
             )
    end

    test "the doctor plan rejects the missing table-set key with the config atom" do
      report =
        AshReplicant.preflight(start_opts(decoder: :pglogical) |> Keyword.delete(:publication))

      assert report.status == :invalid
      assert report.exit_code == 3

      assert [%AshReplicant.Doctor.Check{name: :invocation, reason: :config_invalid}] =
               report.checks
    end
  end

  describe "the pass-through" do
    @tag timeout: 180_000
    test "an explicit :pgoutput decoder is admitted unchanged" do
      capture_log(fn ->
        assert {:ok, _pid} = AshReplicant.start_link(start_opts(decoder: :pgoutput))
        :ok = AshReplicant.stop_supervised("decoder_slot")
      end)
    end

    test "cross-decoder table-set keys are forwarded to Replicant's grammar validation" do
      assert {:error, :config_invalid} =
               AshReplicant.start_link(start_opts(replication_sets: ["default"]))

      assert {:error, :config_invalid} =
               AshReplicant.start_link(start_opts(tables: [{"public", "orders"}]))
    end

    test "the wal2json-only knobs are forwarded to Replicant's grammar validation" do
      assert {:error, :config_invalid} =
               AshReplicant.start_link(start_opts(allow_keyless_tables: true))

      assert {:error, :config_invalid} =
               AshReplicant.start_link(start_opts(schema_check_interval: 5_000))
    end

    test "an unknown decoder value fails with the transport's own grammar atom" do
      assert {:error, :config_invalid} =
               AshReplicant.start_link(start_opts(decoder: :pg_logical))
    end
  end

  defp pipeline_entry, do: :persistent_term.get({AshReplicant, "decoder_slot"}, :none)

  defp entry_source_set do
    case pipeline_entry() do
      %AshReplicant.Destination.Generation{source_set: set} -> set
      other -> other
    end
  end
end
