defmodule AshReplicant.DecoderOptionTest do
  @moduledoc """
  Pipeline and doctor admission for the supported Replicant decoders.
  The port-1 fixtures exercise deferred preflight; the integration lanes
  verify the PostgreSQL catalogs and live delivery.
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

    test "pglogical without replication sets fails with the config atom" do
      assert {:error, :config_invalid} =
               AshReplicant.start_link(
                 start_opts(decoder: :pglogical)
                 |> Keyword.delete(:publication)
               )

      assert :none == pipeline_entry()
    end

    test "a removed decoder is refused before activation and by the doctor" do
      opts =
        start_opts()
        |> Keyword.delete(:publication)
        |> Keyword.merge(decoder: :wal2json, tables: [{"public", "orders"}])

      assert {:error, :config_invalid} = AshReplicant.start_link(opts)
      assert :none == pipeline_entry()

      report = AshReplicant.preflight(opts)
      assert report.status == :invalid
      assert report.exit_code == 3
    end

    test "the doctor plan admits pglogical and skips checks for an unreachable source" do
      opts =
        start_opts()
        |> Keyword.delete(:publication)
        |> Keyword.merge(decoder: :pglogical, replication_sets: ["default"])

      report = AshReplicant.preflight(opts)

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
    end

    test "removed decoder options fail before activation and invalidate doctor invocations" do
      removed = [
        tables: [{"public", "orders"}],
        allow_keyless_tables: true,
        schema_check_interval: 5_000
      ]

      for option <- removed do
        config = start_opts([option])

        assert {:error, :config_invalid} = AshReplicant.start_link(config)
        assert :none == pipeline_entry()
        assert AshReplicant.preflight(config).status == :invalid
      end
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
