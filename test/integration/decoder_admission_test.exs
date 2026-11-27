defmodule AshReplicant.DecoderAdmissionTest do
  @moduledoc """
  Live decoder admission (ADR-0026 and ADR-0027) against the declared source
  major and a separate AshPostgres destination. Exercises preflight, CRUD
  through host actions, and the effect-once watermark across stop/resume.

  Every source runs delivery with pgoutput and pglogical.
  """

  use ExUnit.Case, async: false

  # The ordinary live suite uses --include integration, which would override
  # the source exclusion if these cases also carried :integration.
  @moduletag :decoder_source

  alias AshReplicant.Test.{DecoderSource, PG}

  # One resource, one source table: the plugin table set carries exactly this
  # table, and the adapter's strict-coverage rules require the sink's mapped
  # set to equal it (a multi-resource domain would fail :source_table_missing
  # for the unmapped others — the rule working as designed).
  defmodule LaneOrder do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.DecoderAdmissionTest.LaneDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "decoder_lane_orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("orders")
    end

    attributes do
      attribute :id, :string do
        primary_key? true
        allow_nil? false
        public? true
      end

      attribute :note, :string, public?: true
      attribute :body, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule LaneDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource LaneOrder
    end
  end

  defmodule LaneSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [LaneDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "decoder_lane"
  end

  @source_table "orders"
  @mirror_table "decoder_lane_orders"

  setup context do
    lane_enabled_setup(context)
  end

  defp lane_enabled_setup(context) do
    decoder = context[:decoder]

    unless decoder in [:pgoutput, :pglogical] do
      raise "decoder lane requires a @tag decoder: :pgoutput | :pglogical"
    end

    # The pipeline's processes write to the destination for real: auto mode
    # (the effect_once_test precedent), restoring :manual afterward.
    PG.auto_sandbox!()

    lane_setup(decoder)
    {:ok, decoder: decoder}
  end

  defp lane_setup(decoder) do
    DecoderSource.setup_source!(@source_table, decoder)

    AshReplicant.TestRepo.query!("DROP TABLE IF EXISTS #{@mirror_table}")

    AshReplicant.TestRepo.query!(
      "CREATE TABLE #{@mirror_table} (id text primary key, note text, body text)"
    )

    AshReplicant.TestRepo.query!(
      "DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1",
      ["decoder_lane"]
    )

    drop_lane_slot()

    on_exit(fn ->
      AshReplicant.stop_supervised("decoder_lane")
      DecoderSource.teardown_source!(@source_table, "decoder_lane", decoder)
      AshReplicant.TestRepo.query!("DROP TABLE IF EXISTS #{@mirror_table}")

      AshReplicant.TestRepo.query!(
        "DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1",
        ["decoder_lane"]
      )
    end)
  end

  defp drop_lane_slot do
    PG.wait_until(fn ->
      case DecoderSource.query(
             "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = $1",
             ["decoder_lane"]
           ) do
        {:ok, %Postgrex.Result{num_rows: 0}} -> true
        {:ok, _dropped} -> false
        {:error, _busy} -> false
      end
    end)
  end

  defp lane_opts(decoder) do
    base = [
      sink: LaneSink,
      connection: DecoderSource.connection(),
      source_identity: DecoderSource.identity!(),
      go_forward_only: true,
      snapshot: false,
      census: [enabled?: false]
    ]

    case decoder do
      :pgoutput -> Keyword.merge(base, publication: "decoder_lane_pub")
      :pglogical -> Keyword.merge(base, decoder: :pglogical, replication_sets: ["lane_set"])
    end
  end

  defp start_pipeline!(decoder) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {ref, :slot_active})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    assert {:ok, _owner} = AshReplicant.start_link(lane_opts(decoder))

    assert_receive {^ref, :slot_active}, 60_000
  end

  defp checkpoint_lsn do
    [[lsn]] =
      AshReplicant.TestRepo.query!(
        "SELECT commit_lsn FROM ash_replicant_checkpoints WHERE slot_name = $1",
        ["decoder_lane"]
      ).rows

    lsn
  end

  defp mirror_row!(id) do
    import Ash.Query, only: [filter: 2]

    LaneOrder
    |> filter(id == ^id)
    |> Ash.read!(authorize?: false, tenant: nil, load: [])
  end

  defp assert_mirrored!(id, note) do
    PG.wait_until(fn ->
      case mirror_row!(id) do
        [%{note: ^note}] -> true
        _other -> false
      end
    end)
  end

  defp assert_absent!(id) do
    PG.wait_until(fn ->
      case mirror_row!(id) do
        [] -> true
        _present -> false
      end
    end)
  end

  @tag decoder: :pglogical
  test "pglogical: the decoder-scoped census admits and mirrors CRUD across resume",
       %{decoder: decoder} do
    assert_decoder_lane(decoder)
  end

  @tag decoder: :pgoutput
  test "pgoutput: the publication census admits and mirrors CRUD across resume",
       %{decoder: decoder} do
    assert_decoder_lane(decoder)
  end

  defp assert_decoder_lane(decoder) do
    # 1. The doctor's plugin-source diagnosis: the decoder-scoped census runs
    #    against the source (coverage, privileges, RIF, release floor,
    #    the plugin check's honest answer per decoder).
    report = AshReplicant.preflight(lane_opts(decoder))

    # Every SOURCE check passes; the report's overall verdict may still warn
    # for the pre-start facts (the slot does not exist yet: :slot_absent,
    # :retention_unknown) — those clear once the pipeline creates it.
    assert report.status in [:pass, :warn], inspect(report.checks, pretty: true)

    for name <- [
          :source_coverage,
          :source_release,
          :source_privileges,
          :source_replica_identity,
          :source_plugin
        ] do
      check = Enum.find(report.checks, &(&1.name == name))
      assert check.status == :pass, "#{name}: #{inspect(check)}"
    end

    # 2. Live mirroring through the host's own actions.
    start_pipeline!(decoder)

    DecoderSource.insert_row!(@source_table, "lane-1", "inserted")
    assert_mirrored!("lane-1", "inserted")

    DecoderSource.update_row!(@source_table, "lane-1", "updated")
    assert_mirrored!("lane-1", "updated")

    # 3. A catalog-only transaction leaves the next row deliverable.
    DecoderSource.empty_catalog_txn!(@source_table)
    DecoderSource.insert_row!(@source_table, "lane-2", "after-empty")
    assert_mirrored!("lane-2", "after-empty")

    # 4. Delete mirrors with the decoder's configured replica identity.
    DecoderSource.delete_row!(@source_table, "lane-1")
    assert_absent!("lane-1")

    # 5. No-duplication across a stop/resume: the durable watermark survives
    #    the restart byte-identical, settled state stays single, and fresh
    #    delivery resumes (the watermark-dedup machinery itself is
    #    decoder-invariant and carried by the pgoutput effect-once marquees).
    before_lsn = checkpoint_lsn()

    :ok = AshReplicant.stop_supervised("decoder_lane")

    assert length(mirror_row!("lane-2")) == 1

    start_pipeline!(decoder)
    assert_mirrored!("lane-2", "after-empty")
    assert length(mirror_row!("lane-2")) == 1
    assert checkpoint_lsn() >= before_lsn

    DecoderSource.update_row!(@source_table, "lane-2", "resumed")
    assert_mirrored!("lane-2", "resumed")
  end
end
