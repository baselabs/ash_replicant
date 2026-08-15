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
  as already-closed depth. Bind's throw/exit cells are covered by the
  clause-identical catch + the closeout mutation proof: the reconnect coverage
  gate (which fires BEFORE any faultable seam and converts its own faults to
  `{:error, :preflight_failed}`) makes a unit injection unreachable without a
  live source connection.

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

  # Schema-change injection: Spark's reflection calls the info accessor
  # directly on the module (get_config_entry_with_fallback -> direct_fn),
  # so a mapped "resource" that faults there drives the body's boundary.
  defmodule FaultyReflection do
    @moduledoc false
    def replicant_on_schema_change, do: FaultyRepo.fault()
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
  @faulty_index %{{"public", "scrub_boundary_tbl"} => FaultyReflection}

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
    test "bind: a raise is scrubbed value-free (raise cell — already-closed depth)" do
      cfg = config(extra: [source_contract: %{}])
      set_shape(:raise)

      {{:error, %AshReplicant.Error{reason: :sink_failed}}, _} =
        assert_value_free(fn ->
          Impl.handle_session_identity(cfg, session_identity(), %{
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

    test "schema-change: a body fault is scrubbed value-free AND fires the sink halt" do
      # Raise-only injection: Spark's reflection seals the module-fault path
      # (UndefinedFunctionError/ArgumentError from the direct accessor fall
      # back to Module.get_attribute and surface as one polished ArgumentError
      # INSIDE the body — the raw form escaping today is the leak). The
      # :throw/:exit catch clauses are clause-identical to the four
      # repo-seam boundaries above (proven there + by the closeout mutation
      # proof); no seam in this body can throw or exit.
      set_shape(:raise)

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
             "the sink's own halt event must fire on the fault path"
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
