defmodule AshReplicant.Test.PerformanceBounds.Order do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.PerformanceBounds.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "perf_bounds_mirror_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("perf_bounds_src_orders")
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :create do
      primary? true
      accept [:id, :note]
    end
  end
end

defmodule AshReplicant.Test.PerformanceBounds.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.PerformanceBounds.Order
  end
end

defmodule AshReplicant.Test.PerformanceBounds.Sink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.PerformanceBounds.Domain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "perf_bounds_slot"
end

defmodule AshReplicant.PerformanceBoundsTest do
  @moduledoc """
  B01 / ADR-0021 (roadmap D5): measured performance bounds as release
  correctness constraints.

  Two artifacts from one harness:

  - the CI SENTINELS — wide floors (roughly an order of magnitude above
    measured steady state) that stay stable under runner noise and still
    trip on the regressions that matter: a lost single-pass stream, an
    accidental O(n²) apply, an unbounded materialization, a batch that
    stops amortizing commits;
  - the BASELINE RECEIPT — with `ASH_REPLICANT_BENCH_RECEIPT=path` set,
    each leg appends its measurement (rows, wall ms, statements, total
    BEAM memory) to the file: the reproducible baseline evidence the
    release candidate publishes. Changing a protected bound is an ADR
    amendment, not a test tweak.

  Modes: per-transaction streaming, sink-owned batch delivery, SCD2
  versioning, append-log delivery — every row through the REAL pipeline
  (live slot, publication, walsender) on the shared integration
  substrate. Statements are counted per destination SQL execution via
  the repo's query telemetry, so the receipt's statement column is the
  actual database round-trip traffic.
  """

  use ExUnit.Case, async: false

  # :performance ONLY (deliberately not :integration): an --include on the
  # command line lifts configure-excludes for dual-tagged tests, so these
  # heavy legs could never be excluded from the integration batteries if
  # they also carried :integration. They run when --include performance is
  # passed (the dedicated CI job; local full batteries opt in via the
  # runner) and are excluded everywhere else — including db-free runs.
  @moduletag :performance
  @moduletag capture_log: true

  alias AshReplicant.Test.{AppendMarquee, Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "perf_bounds_slot"
  @publication "repl_perf_bounds_pub"
  @src "perf_bounds_src_orders"
  @mirror "perf_bounds_mirror_orders"

  # Sentinel floors at ~1/3 of the MEASURED 2026-08-24 baseline
  # (Apple-silicon laptop, throwaway PG16 container; all four modes
  # measured 49–66 rows/s — the per-change generation-guard
  # re-validation dominates delivery cost, the `run_transaction`
  # timeout note's "guard overhead alone" class; the receipt carries the
  # per-mode numbers). The 3x margin is the noise tolerance (ADR-0021):
  # floors catch CLASS regressions — a lost single-pass stream, an O(n²)
  # apply, an unbounded materialization, a batch that stops amortizing —
  # never percent drift.
  @txn_rows 1_000
  @txn_floor_rows_per_s 15

  @batch_rows 1_000
  @batch_floor_rows_per_s 15

  @scd2_rows 1_000
  @scd2_floor_rows_per_s 10

  @append_events 1_000
  @append_floor_events_per_s 15

  # Anti-blowup tripwire (total BEAM bytes after a leg), not a memory
  # budget: an unbounded materialization or a leak accumulates here long
  # before a CI runner dies.
  @memory_ceiling_mb 1_024

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("CREATE TABLE #{@src} (id text primary key, note text)")
    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    Marquee.q!("DROP TABLE IF EXISTS #{@mirror}")
    Marquee.q!("CREATE TABLE #{@mirror} (id text primary key, note text)")
    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS #{@mirror}")
    end)

    :ok
  end

  # Benchmark legs stream thousands of rows through the guarded delivery
  # path (~15-25ms/row steady state) — they outgrow ExUnit's default 60s
  # per test by design, so every leg carries an explicit budget.
  @tag timeout: 240_000
  test "per-transaction streaming stays above the class floor" do
    %{rows_per_s: rows_per_s} =
      run_leg(
        family: "streaming/per-transaction",
        rows: @txn_rows,
        start: fn -> start_sink!(batch: false) end,
        insert: fn -> insert_rows(@txn_rows, 10) end,
        applied: fn -> mirror_count() == @txn_rows end
      )

    assert rows_per_s >= @txn_floor_rows_per_s
  end

  @tag timeout: 240_000
  test "sink-owned batch delivery amortizes commits and stays above the class floor" do
    %{rows_per_s: rows_per_s} =
      run_leg(
        family: "streaming/batch-20",
        rows: @batch_rows,
        start: fn -> start_sink!(batch: true) end,
        insert: fn -> insert_rows(@batch_rows, 10) end,
        applied: fn -> mirror_count() == @batch_rows end
      )

    assert rows_per_s >= @batch_floor_rows_per_s
  end

  @tag timeout: 240_000
  test "SCD2 versioned delivery stays above the class floor" do
    Marquee.setup_scd2_schema!()
    Marquee.drop_slot!(Marquee.Scd2Sink.__ash_replicant_config__().slot_name)

    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [
      Marquee.Scd2Sink.__ash_replicant_config__().slot_name
    ])

    on_exit(fn ->
      AshReplicant.stop_supervised(Marquee.Scd2Sink.__ash_replicant_config__().slot_name)
      Marquee.drop_slot!(Marquee.Scd2Sink.__ash_replicant_config__().slot_name)

      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [
        Marquee.Scd2Sink.__ash_replicant_config__().slot_name
      ])

      Marquee.q!("DROP PUBLICATION IF EXISTS #{Marquee.scd2_publication()}")
      Marquee.q!("DROP TABLE IF EXISTS #{Marquee.scd2_src()}")
      Marquee.q!("DROP TABLE IF EXISTS #{Marquee.scd2_version()}")
      Marquee.q!("DROP TABLE IF EXISTS #{Marquee.scd2_auxiliary()}")
    end)

    %{rows_per_s: rows_per_s} =
      run_leg(
        family: "scd2/versioned",
        rows: @scd2_rows,
        start: fn ->
          start_pipeline!(
            sink: AshReplicant.Test.Marquee.Scd2Sink,
            publication: Marquee.scd2_publication()
          )
        end,
        insert: fn ->
          Marquee.q!(
            "INSERT INTO #{Marquee.scd2_src()} (order_id, amount) SELECT 'o' || g, 'a' || g FROM generate_series(1, $1) g",
            [@scd2_rows]
          )
        end,
        applied: fn ->
          [[count]] = Marquee.q!("SELECT count(*) FROM #{Marquee.scd2_version()}").rows
          count == @scd2_rows
        end
      )

    assert rows_per_s >= @scd2_floor_rows_per_s
  end

  @tag timeout: 240_000
  test "append-log delivery stays above the class floor" do
    AppendMarquee.setup_schema!()
    Marquee.drop_slot!(AppendMarquee.stream_slot())

    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [
      AppendMarquee.stream_slot()
    ])

    on_exit(fn ->
      AshReplicant.stop_supervised(AppendMarquee.stream_slot())
      Marquee.drop_slot!(AppendMarquee.stream_slot())

      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [
        AppendMarquee.stream_slot()
      ])

      AppendMarquee.teardown_schema!()
    end)

    %{rows_per_s: events_per_s} =
      run_leg(
        family: "append/log",
        rows: @append_events,
        start: fn ->
          start_pipeline!(
            sink: AshReplicant.Test.AppendMarquee.StreamSink,
            publication: AppendMarquee.publication()
          )
        end,
        insert: fn ->
          Marquee.q!(
            "INSERT INTO #{AppendMarquee.src()} (id, note) SELECT 'e' || g, 'n' || g FROM generate_series(1, $1) g",
            [@append_events]
          )
        end,
        applied: fn ->
          [[count]] =
            Marquee.q!("SELECT count(*) FROM #{AppendMarquee.events_table()}").rows

          count == @append_events
        end
      )

    assert events_per_s >= @append_floor_events_per_s
  end

  # --- the harness ---

  defp run_leg(family: family, rows: rows, start: start, insert: insert, applied: applied) do
    start.()
    sink = registered_sink()
    await_slot_active(sink)

    ref = make_ref()
    me = self()

    :telemetry.attach(
      {__MODULE__, ref, :statements},
      [:ash_replicant, :test_repo, :query],
      fn _event, _m, _meta, _c -> send(me, {:stmt, ref}) end,
      nil
    )

    {micros, :ok} =
      :timer.tc(fn ->
        insert.()
        PG.wait_until(applied, 4_800)
      end)

    :telemetry.detach({__MODULE__, ref, :statements})
    statements = harvest(ref)

    wall_ms = micros / 1000
    memory_mb = :erlang.memory(:total) / 1024 / 1024

    record_receipt(family, rows, wall_ms, statements, memory_mb)

    assert memory_mb < @memory_ceiling_mb

    %{rows_per_s: rows / (micros / 1_000_000), statements: statements, memory_mb: memory_mb}
  end

  defp registered_sink do
    case :persistent_term.get({AshReplicant, @slot}, :none) do
      %{sink: sink} -> sink
      :none -> @slot
    end
  end

  defp start_sink!(batch: batch) do
    # `batch_delivery: false` is not a lawful value — the option is
    # OMITTED for per-transaction mode, never passed as false.
    opts =
      [sink: AshReplicant.Test.PerformanceBounds.Sink] ++
        [
          connection: Marquee.conn(),
          publication: @publication,
          source_identity: Marquee.source_identity(),
          go_forward_only: true
        ] ++
        if batch,
          do: [batch_delivery: [max_transactions: 20, max_delay_ms: 100]],
          else: []

    {:ok, _} = AshReplicant.start_link(opts)

    AshReplicant.Test.PerformanceBounds.Sink
  end

  defp start_pipeline!(sink: sink, publication: publication) do
    slot = sink.__ash_replicant_config__().slot_name

    {:ok, _} =
      AshReplicant.start_link(
        sink: sink,
        connection: Marquee.conn(),
        publication: publication,
        source_identity: Marquee.source_identity(),
        go_forward_only: true
      )

    slot
  end

  defp await_slot_active(sink) do
    slot =
      (is_atom(sink) && sink.__ash_replicant_config__().slot_name) || sink

    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref, :active},
      [:replicant, :connection, :slot_active],
      fn _event, _m, _meta, _c -> send(test_pid, {:slot_active, ref}) end,
      nil
    )

    receive do
      {:slot_active, ^ref} -> :ok
    after
      15_000 -> flunk("pipeline never reached slot_active for #{slot}")
    end

    :telemetry.detach({__MODULE__, ref, :active})
  end

  defp insert_rows(rows, batch) do
    for i <- 1..div(rows, batch) do
      values =
        1..batch
        |> Enum.map_join(", ", fn j ->
          offset = (i - 1) * batch + j
          "('r#{offset}', 'n#{offset}')"
        end)

      Marquee.q!("INSERT INTO #{@src} (id, note) VALUES #{values}")
    end

    :ok
  end

  defp mirror_count do
    [[count]] = Marquee.q!("SELECT count(*) FROM #{@mirror}").rows
    count
  end

  # Telemetry handlers run synchronously in the emitting process, so by
  # the time the measured fun returns every send has happened; the
  # 100ms grace drains any last in-flight delivery.
  defp harvest(ref) do
    receive do
      {:stmt, ^ref} -> 1 + harvest(ref)
    after
      100 -> 0
    end
  end

  defp record_receipt(family, rows, wall_ms, statements, memory_mb) do
    if path = System.get_env("ASH_REPLICANT_BENCH_RECEIPT") do
      File.write!(
        path,
        "- #{family}: rows=#{rows} wall_ms=#{round(wall_ms)} " <>
          "rows_per_s=#{round(rows / (wall_ms / 1000))} " <>
          "statements=#{statements} beam_mb=#{round(memory_mb)} " <>
          "at=#{Date.to_string(Date.utc_today())}\n",
        [:append]
      )
    end
  end
end
