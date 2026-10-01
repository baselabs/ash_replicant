defmodule AshReplicant.DecoderOptionTest do
  @moduledoc """
  The Replicant 1.4 decoder-option contract (ADR-0026): every transport
  option Replicant 1.4 accepts is FORWARDED (`decoder:`, `replication_sets:`,
  `tables:`, `allow_keyless_tables:`, `schema_check_interval:`), and the one
  adapter-side admission rule — the decoder must be `:pgoutput`, because the
  adapter's coverage census, contract manifest, and doctor statements are
  publication-scoped — refuses a plugin decoder with the named structural
  error `:decoder_unsupported` at BOTH the activation and the doctor plan,
  before the nil-publication `:config_invalid` could mislabel it.
  """

  use ExUnit.Case, async: false

  # The unreachable-port fixture (port 1) lets Postgrex fail to connect and
  # retry; its protocol-level [error] logs are expected test behavior.
  @moduletag capture_log: true

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

  describe "the admission rule" do
    test "a wal2json decoder is refused with the named error, not the nil-publication config error" do
      # wal2json's real configuration shape: `tables:`, NO publication — the
      # shape the pre-rule chain would have mislabeled {:error, :config_invalid}.
      opts =
        start_opts()
        |> Keyword.delete(:publication)
        |> Keyword.merge(decoder: :wal2json, tables: [{"public", "orders"}])

      assert {:error, :decoder_unsupported} = AshReplicant.start_link(opts)
      assert :persistent_term.get({AshReplicant, "decoder_slot"}, :none) == :none
    end

    test "a pglogical decoder is refused even when a publication is present" do
      opts = start_opts(decoder: :pglogical, replication_sets: ["default"])

      assert {:error, :decoder_unsupported} = AshReplicant.start_link(opts)
      assert :persistent_term.get({AshReplicant, "decoder_slot"}, :none) == :none
    end

    test "the doctor plan refuses a plugin decoder with the same named error" do
      opts =
        start_opts()
        |> Keyword.delete(:publication)
        |> Keyword.merge(decoder: :wal2json, tables: [{"public", "orders"}])

      report = AshReplicant.preflight(opts)

      assert report.status == :invalid
      assert report.exit_code == 3

      assert [%AshReplicant.Doctor.Check{name: :invocation, reason: :decoder_unsupported}] =
               report.checks
    end
  end

  describe "the pass-through" do
    # Load-budget class (the start_link_test note): every port-1 activation
    # walks the code fingerprint through the serialized code server.
    @tag timeout: 180_000
    test "an explicit :pgoutput decoder is admitted unchanged" do
      assert {:ok, _pid} = AshReplicant.start_link(start_opts(decoder: :pgoutput))
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

    test "an unknown decoder value is forwarded, not re-validated in the adapter" do
      # The decoder GRAMMAR is the transport's: only the admission of the two
      # plugin atoms is ours, so a misspelled decoder reaches upstream's
      # :config_invalid rather than a lookalike local error.
      assert {:error, :config_invalid} =
               AshReplicant.start_link(start_opts(decoder: :pg_logical))
    end
  end
end
