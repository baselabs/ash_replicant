defmodule AshReplicant.DecoderAdmissionTest do
  @moduledoc """
  The plugin-decoder admission lane (ADR-0026): pglogical and wal2json
  mirroring against a REAL pre-15 source (PostgreSQL 9.6 or 12 with the
  plugins — `test/support/pg_old.dockerfile`), destination on the ordinary
  test database. Proves, per decoder: the decoder-scoped census + contract
  admission (preflight and doctor), insert/update/delete delivery through the
  host's own actions, the pre-15 empty-transaction suppression tolerance, and
  the effect-once watermark across a stop/resume.

  Gated on BOTH `ASH_REPLICANT_TEST_URL` (the destination, like every
  integration test) and `ASH_REPLICANT_PGOLD_URL` (the old-major source); CI
  runs one cell per major, so each cell exercises both decoders on its major.
  """

  use ExUnit.Case, async: false

  # The decoder lanes carry ONLY :pgold (not :integration): a CLI
  # `--include integration` re-includes excluded tests carrying the included
  # tag, so piggybacking on :integration would defeat the exclusion in every
  # ordinary live run. The lanes run where the substrate exists — the
  # decoder-old-majors CI cells and local `--include pgold` runs with
  # ASH_REPLICANT_PGOLD_URL set.
  @moduletag :pgold

  alias AshReplicant.Test.{PG, PgOld}
  alias Ecto.Adapters.SQL.Sandbox

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

    unless decoder in [:pgoutput, :pglogical, :wal2json] do
      raise "decoder lane requires a @tag decoder: :pgoutput | :pglogical | :wal2json"
    end

    # The pipeline's processes write to the destination for real: auto mode
    # (the effect_once_test precedent), restoring :manual afterward.
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    lane_setup(decoder)
    {:ok, decoder: decoder}
  end

  defp lane_setup(decoder) do
    PgOld.setup_source!(@source_table, decoder)

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
      PgOld.teardown_source!(@source_table, "decoder_lane", decoder)
      AshReplicant.TestRepo.query!("DROP TABLE IF EXISTS #{@mirror_table}")

      AshReplicant.TestRepo.query!(
        "DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1",
        ["decoder_lane"]
      )
    end)
  end

  defp drop_lane_slot do
    PG.wait_until(fn ->
      case PgOld.query(
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
      connection: PgOld.connection(),
      source_identity: PgOld.identity!(),
      go_forward_only: true,
      snapshot: false,
      census: [enabled?: false]
    ]

    case decoder do
      :pgoutput -> Keyword.merge(base, publication: "decoder_lane_pub")
      :pglogical -> Keyword.merge(base, decoder: :pglogical, replication_sets: ["lane_set"])
      :wal2json -> Keyword.merge(base, decoder: :wal2json, tables: [{"public", @source_table}])
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
  test "pglogical: the decoder-scoped census admits, mirrors CRUD, and tolerates the pre-15 empty-transaction suppression",
       %{decoder: decoder} do
    assert_plugin_lane(decoder)
  end

  @tag decoder: :wal2json
  test "wal2json: the decoder-scoped census admits, mirrors CRUD, and tolerates the pre-15 empty-transaction suppression",
       %{decoder: decoder} do
    assert_plugin_lane(decoder)
  end

  @tag decoder: :pgoutput
  test "pgoutput on an old major: publication mirroring where the floor admits it, refusal where it does not",
       %{decoder: decoder} do
    if PgOld.release!() >= 100_000 do
      # The publication path on the old major (12 is the pgoutput floor).
      assert_plugin_lane(decoder)
    else
      # Pre-10 has no publications at all — and the release floor is
      # ENFORCED, not advisory (ADR-0026): the release probe answers on this
      # server, the floor gate refuses pgoutput below 12 BY NAME, and the
      # doctor mirrors the same verdict (the check fails
      # :source_release_unsupported; every other source check skips with
      # that reason, never a guessed pass). The runtime enforces the same
      # floor at ACTIVATION — synchronously, before the transport ever
      # connects, instead of the transport's later connect halt.
      report = AshReplicant.preflight(lane_opts(decoder))

      release = Enum.find(report.checks, &(&1.name == :source_release))

      assert release.status == :fail
      assert release.reason == :source_release_unsupported

      for name <- [:source_plugin, :source_privileges, :source_identity, :source_coverage] do
        check = Enum.find(report.checks, &(&1.name == name))

        assert check.status == :skipped
        assert check.reason == :source_release_unsupported
      end

      assert {:error, %AshReplicant.Error{reason: :source_release_unsupported}} =
               AshReplicant.start_link(lane_opts(decoder))
    end
  end

  defp assert_plugin_lane(decoder) do
    # 1. The doctor's plugin-source diagnosis: the decoder-scoped census runs
    #    against the old server (coverage, privileges, RIF, release floor,
    #    the plugin check's honest answer per decoder).
    report = AshReplicant.preflight(lane_opts(decoder))

    # Every SOURCE check passes; the report's overall verdict may still warn
    # for the pre-start facts (the slot does not exist yet: :slot_absent,
    # :retention_unknown) — those clear once the pipeline creates it.
    assert report.status in [:pass, :warn], inspect(report.checks, pretty: true)

    for name <- [:source_coverage, :source_release, :source_privileges, :source_replica_identity] do
      check = Enum.find(report.checks, &(&1.name == name))
      assert check.status == :pass, "#{name}: #{inspect(check)}"
    end

    plugin_check = Enum.find(report.checks, &(&1.name == :source_plugin))

    case decoder do
      :pglogical ->
        assert plugin_check.status == :pass
        assert plugin_check.reason == :ok

      :wal2json ->
        assert plugin_check.status == :skipped
        assert plugin_check.reason == :plugin_presence_not_provable

      :pgoutput ->
        assert plugin_check.status == :pass
        assert plugin_check.reason == :ok
    end

    release_check = Enum.find(report.checks, &(&1.name == :source_release))
    assert release_check.status == :pass

    # 2. Live mirroring through the host's own actions.
    start_pipeline!(decoder)

    PgOld.insert_row!(@source_table, "lane-1", "inserted")
    assert_mirrored!("lane-1", "inserted")

    PgOld.update_row!(@source_table, "lane-1", "updated")
    assert_mirrored!("lane-1", "updated")

    # 3. The pre-15 empty-transaction suppression (every catalog-touching
    #    transaction is BEGIN/COMMIT with zero published changes on this
    #    server): the pipeline must not rely on empty transactions — the next
    #    real change still mirrors and the row count stays exact.
    PgOld.empty_catalog_txn!(@source_table)
    PgOld.insert_row!(@source_table, "lane-2", "after-empty")
    assert_mirrored!("lane-2", "after-empty")

    # 4. Delete carries the old record (REPLICA IDENTITY FULL) and mirrors.
    PgOld.delete_row!(@source_table, "lane-1")
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

    PgOld.update_row!(@source_table, "lane-2", "resumed")
    assert_mirrored!("lane-2", "resumed")
  end
end
