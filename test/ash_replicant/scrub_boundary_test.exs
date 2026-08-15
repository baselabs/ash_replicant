defmodule AshReplicant.ScrubBoundaryTest do
  @moduledoc """
  U3/D3 — the completed value-free boundary. `rescue` does not catch `throw`/`
  `exit`; DBConnection re-raises them after rollback. Every sink boundary body
  gains `catch :throw/:exit` routing into the SAME scrub/halt path, and the
  schema-change body — the only callback with NO boundary today — gains the
  full rescue+catch AND fires the sink's own `[:ash_replicant, :sink, :halted]`
  (design C2: replicant's wrapper scrubs a faulting sink value-free but
  MISLABELS it `:decode_failure`; the sink's catch reclassifies to the
  structural reason).

  HARNESS (pinned per plan F2): the matrix drives callbacks DIRECTLY (the
  schema_change_test.exs:58 pattern), never through replicant's wrapper.

  RED-CELL CALIBRATION under direct drive: the throw/exit cells of ALL six
  bodies are RED pre-fix (`rescue` misses them; schema-change is bare); the
  schema-change RAISE cell is RED pre-fix (no boundary at all); the five
  delivery bodies' raise cells are GREEN pre-fix (already rescued) — recorded
  as already-closed depth. Bind's :exit cell is drivable in-unit (round 3):
  the reconnect gate DEFERS its census connection faults to the destination
  transaction by design (:unreachable -> :ok), so with an empty
  source_connection bind proceeds to repo.transaction — a faulting repo
  carrying an :exit sentinel reaches the catch clause there. Schema-change's
  :throw/:exit cells ride Spark's
  fetch_opt/2 direct_fn seam (a fault there escapes Spark's rescue-only
  wrapper into the sink's catch); its :raise is re-wrapped by Spark into the
  structural polished ArgumentError. Bind's :throw has no seam (the gate's
  reachable paths raise or exit only) — clause-identical coverage.

  The PIPELINE-driven classification case (plan F2's live leg): the mislabel
  surface (replicant handle_message's :decode_failure on a RAISING sink) is
  closed BY CONSTRUCTION — the sink's own containment means the wrapper's
  rescue never engages on this path; a test would have to inject a fault the
  sink can no longer produce. The wrapper's lines are cited at
  assembler.ex:241-249; the unit cells pin the containment that makes them
  unreachable.

  The sentinel rule: a unique string sentinel appears in NO captured log, NO
  returned error message/inspect, and NO telemetry payload.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias AshReplicant.Sink.Impl
  alias AshReplicant.Telemetry
  alias AshReplicant.Test.Checkpoint

  @sentinel_raise "SENTINEL-RIDGE-RAISE-4f2a"
  @sentinel_throw "SENTINEL-RIDGE-THROW-9c1d"
  @sentinel_exit "SENTINEL-RIDGE-EXIT-7b3e"

  # Fault flavor: every repo-ish callback the boundaries can reach faults
  # with the chosen shape, carrying the SHAPE'S SENTINEL as the payload (the
  # thing a leak would render). transaction/2 is the seam for transaction/
  # snapshot/snapshot_complete; the read path for checkpoint; the Spark info
  # accessor for schema-change.
  defmodule FaultyRepo do
    @moduledoc false
    def fault do
      case Process.get({__MODULE__, :shape}) do
        {:raise, sentinel} -> raise ArgumentError, sentinel
        {:throw, sentinel} -> throw(sentinel)
        {:exit, sentinel} -> exit(sentinel)
      end
    end

    def transaction(_fun, _opts \\ []), do: fault()
    def rollback(_value), do: fault()
    def all(_query, _opts \\ []), do: fault()
    def query(_sql, _params, _opts \\ []), do: fault()
    def start_link(_opts \\ []), do: fault()
  end

  # Schema-change injection via Spark's REAL seam: the compiled
  # `fetch_opt(path, key)` on the mapped module is the info accessor's
  # direct_fn. A :throw/:exit from it escapes Spark's rescue-only wrapper
  # into the sink's catch — the CARRIED sentinel proves the scrub; a raise
  # is re-wrapped by Spark into its polished "not a Spark DSL module"
  # ArgumentError (structural — the raise cell pins containment without a
  # sentinel). (Diff-review round 2: an accessor like
  # `replicant_on_schema_change/0` is unreachable — the Info chain never
  # calls it.)
  defmodule FaultyFetchOpt do
    @moduledoc false
    def fetch_opt(_path, _key), do: FaultyRepo.fault()
  end

  # A REAL replicant resource for the policy path (mapped, additive → :ok).
  defmodule CalmMirror do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.ScrubBoundaryTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReplicant.Resource]

    replicant do
      source_table("scrub_boundary_tbl")
    end

    attributes do
      attribute :id, :string do
        primary_key? true
        allow_nil? false
        public? true
      end
    end

    actions do
      defaults([:read, :destroy, create: :*])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  @index %{{"public", "scrub_boundary_tbl"} => CalmMirror}
  @faulty_index %{{"public", "scrub_boundary_tbl"} => FaultyFetchOpt}

  defp config(opts \\ []) do
    %{
      repo: FaultyRepo,
      resolver_index: Keyword.get(opts, :index, @index),
      checkpoint_resource: Checkpoint,
      slot_name: "scrub_boundary_slot",
      publication: "scrub_boundary_pub",
      source_identity: %{system_identifier: "sys", database: "db"},
      authorize?: false
    }
    |> Map.merge(Map.new(opts[:extra] || []))
  end

  defp sc(kind, table, detail \\ "d") do
    %Replicant.SchemaChange{kind: kind, schema: "public", table: table, change: detail}
  end

  defp txn_change(record) do
    %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "scrub_boundary_tbl",
      record: record,
      old_record: nil,
      unchanged: []
    }
  end

  defp set_shape(shape) do
    sentinel =
      %{raise: @sentinel_raise, throw: @sentinel_throw, exit: @sentinel_exit}
      |> Map.fetch!(shape)

    Process.put({FaultyRepo, :shape}, {shape, sentinel})
  end

  # The sink: run the boundary under a fault shape, capture logs, collect the
  # returned error and every telemetry payload, and assert the sentinel is
  # absent everywhere.
  defp assert_value_free(boundary) do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:ash_replicant, :sink, :halted],
        [:ash_replicant, :sink, :applied],
        [:ash_replicant, :sink, :skipped]
      ])

    {result, logs} =
      with_log(fn ->
        boundary.()
      end)

    payloads = collect_telemetry(ref)
    rendered = logs <> inspect(result) <> inspect(payloads)

    assert rendered =~ "halted" or match?({:error, _}, result),
           "the fault must surface as an error/halt, got: #{inspect(result)}"

    for {shape, sentinel} <- [
          raise: @sentinel_raise,
          throw: @sentinel_throw,
          exit: @sentinel_exit
        ] do
      refute rendered =~ sentinel,
             "sentinel for #{shape} leaked into logs/error/telemetry: #{inspect(rendered)}"
    end

    {result, payloads}
  end

  defp collect_telemetry(ref) do
    Enum.reduce_while(Stream.repeatedly(fn -> :ok end), [], fn _i, acc ->
      receive do
        {event, ^ref, measurements, meta} -> {:cont, [{event, measurements, meta} | acc]}
      after
        20 -> {:halt, Enum.reverse(acc)}
      end
    end)
  end

  describe "the six boundary bodies, direct drive (mutation matrix)" do
    test "bind: raise (missing manifest KeyError) and :exit (unreachable source) scrub value-free" do
      # The drivable unit seams (diff-review rounds 2-3): (a) a
      # source_contract without :manifest raises KeyError INSIDE the body —
      # scrubbed by the rescue; (b) an EMPTY source_connection makes the
      # reconnect gate's census checkout exit noproc — the census's first
      # query runs Postgrex.query against the :unreachable placeholder and
      # DBConnection's checkout exits {:noproc, ...} (the gate's later
      # GenServer.stop is dead on this path) — a REAL :exit caught by the
      # catch clause with a structural reason.
      cfg_raise = config(extra: [source_contract: %{}])

      {{:error, %AshReplicant.Error{reason: :sink_failed}}, _} =
        assert_value_free(fn ->
          Impl.handle_session_identity(cfg_raise, session_identity(), %{
            slot_name: "scrub_boundary_slot",
            publication: "scrub_boundary_pub"
          })
        end)

      # The exit leg: the gate DEFERS its census faults (:unreachable
      # defers to the destination transaction by design), so bind proceeds
      # to repo.transaction — where the FaultyRepo's :exit carries the
      # sentinel INTO the catch clause.
      cfg_exit = config(extra: [source_contract: %{manifest: %{}}, source_connection: []])
      set_shape(:exit)

      {{:error, %AshReplicant.Error{reason: :sink_failed}}, _} =
        assert_value_free(fn ->
          Impl.handle_session_identity(cfg_exit, session_identity(), %{
            slot_name: "scrub_boundary_slot",
            publication: "scrub_boundary_pub"
          })
        end)
    end

    test "checkpoint: raise/throw/exit all scrub value-free" do
      for shape <- [:raise, :throw, :exit] do
        set_shape(shape)

        {{:error, %AshReplicant.Error{reason: :sink_failed}}, _} =
          assert_value_free(fn -> Impl.checkpoint(config()) end)
      end
    end

    test "transaction: raise/throw/exit all scrub value-free and halt" do
      for shape <- [:raise, :throw, :exit] do
        set_shape(shape)

        {result, telemetry} =
          assert_value_free(fn ->
            Impl.handle_transaction(config(), %Replicant.Transaction{
              commit_lsn: 10,
              commit_timestamp: nil,
              changes: [txn_change(%{"id" => "1"})]
            })
          end)

        assert {:error, %AshReplicant.Error{reason: :sink_failed}} = result

        assert Enum.any?(telemetry, &match?({[:ash_replicant, :sink, :halted], _, _}, &1)),
               "the sink's own halt event must fire on the fault path"
      end
    end

    test "snapshot: raise/throw/exit all scrub value-free" do
      for shape <- [:raise, :throw, :exit] do
        set_shape(shape)

        {result, _telemetry} =
          assert_value_free(fn ->
            Impl.handle_snapshot(config(), [txn_change(%{"id" => "1"})], %{
              table: "public.scrub_boundary_tbl",
              first_for_table?: true,
              snapshot_lsn: 5
            })
          end)

        assert {:error, %AshReplicant.Error{reason: :sink_failed}} = result
      end
    end

    test "snapshot_complete: raise/throw/exit all scrub value-free" do
      for shape <- [:raise, :throw, :exit] do
        set_shape(shape)

        {result, _telemetry} =
          assert_value_free(fn -> Impl.handle_snapshot_complete(config(), 5) end)

        assert {:error, %AshReplicant.Error{reason: :sink_failed}} = result
      end
    end

    test "schema-change: throw/exit/raise body faults all scrub value-free AND fire the sink halt" do
      # :throw/:exit ride the fetch_opt seam with their sentinels; :raise is
      # re-wrapped by Spark into the structural polished ArgumentError (the
      # pre-fix raw escape was exactly that class). All three shapes land in
      # the sink's own containment with the halt event fired.
      for shape <- [:throw, :exit, :raise] do
        set_shape(shape)

        {result, telemetry} =
          assert_value_free(fn ->
            Impl.handle_schema_change(
              config(index: @faulty_index),
              sc(:destructive, "scrub_boundary_tbl"),
              %{}
            )
          end)

        assert {:error, %AshReplicant.Error{reason: :sink_failed}} = result

        assert Enum.any?(telemetry, &match?({[:ash_replicant, :sink, :halted], _, _}, &1)),
               "the sink's own halt event must fire on the fault path (#{shape})"
      end
    end

    test "schema-change: the non-fault paths are unchanged (additive :ok, destructive halt)" do
      assert :ok =
               Impl.handle_schema_change(config(), sc(:additive, "scrub_boundary_tbl"), %{})

      assert {:error, %AshReplicant.Error{reason: :schema_change_destructive}} =
               Impl.handle_schema_change(config(), sc(:destructive, "unmapped_tbl"), %{})
    end
  end

  defp session_identity do
    %Replicant.SessionIdentity{
      system_identifier: "sys",
      database: "db",
      timeline_id: 1,
      current_lsn: nil
    }
  end
end
