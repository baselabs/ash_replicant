defmodule AshReplicant.Test.CheckpointBinding.ContractOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.CheckpointBinding.ContractADomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "checkpoint_binding_contract_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("contract_orders")
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.CheckpointBinding.ContractExtra do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.CheckpointBinding.ContractBDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "checkpoint_binding_contract_extras"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("contract_extras")
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshReplicant.Test.CheckpointBinding.ContractADomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.CheckpointBinding.ContractOrder
  end
end

defmodule AshReplicant.Test.CheckpointBinding.ContractBDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.CheckpointBinding.ContractOrder
    resource AshReplicant.Test.CheckpointBinding.ContractExtra
  end
end

defmodule AshReplicant.CheckpointBindingTest do
  @moduledoc """
  Roadmap B2 acceptance marquees: the actual replication-session identity binds
  the checkpoint row durably, timeline/liveness/contract guards halt fail-closed,
  and compatible contract transitions replace manifest/fingerprint without
  touching the watermark. Observed through durable row state and telemetry only.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "bind_slot"
  @fresh_slot "bind_fresh_slot"

  defmodule SinkA do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.CheckpointBinding.ContractADomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "bind_slot"
  end

  defmodule SinkB do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.CheckpointBinding.ContractBDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "bind_slot"
  end

  defmodule FreshSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "bind_fresh_slot"
  end

  setup do
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_schema!()

    for slot <- [@slot, @fresh_slot] do
      Marquee.drop_slot!(slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
    end

    on_exit(fn ->
      for slot <- [@slot, @fresh_slot] do
        AshReplicant.stop_supervised(slot)
        Marquee.drop_slot!(slot)
        Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [slot])
      end

      Marquee.teardown_schema!()
    end)

    :ok
  end

  test "fresh bind: the actual session identity, timeline, and contract durably bind the row" do
    ref = attach_events()

    assert {:ok, _pid} = start(FreshSink, @fresh_slot)

    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    identity = Marquee.source_identity()
    timeline = live_timeline()

    row = bound_row(@fresh_slot)

    assert row.source_system_id == identity[:system_identifier]
    assert row.source_database == identity[:database]
    assert row.source_timeline == timeline
    assert row.commit_lsn == nil

    {:ok, contract} =
      Identity.build_contract(FreshSink.__ash_replicant_config__(), [Marquee.publication()])

    assert row.publication_fingerprint == contract.fingerprint
    assert Identity.decode(row.publication_contract) == {:ok, contract.manifest}

    # First streamed transaction sets the watermark on the SAME row.
    Marquee.q!("INSERT INTO #{Marquee.src()} (id, note) VALUES ('bind-1', 'bound')")

    assert_receive {:telemetry, ^ref, [:ash_replicant, :sink, :applied], %{commit_lsn: lsn}},
                   15_000

    PG.wait_until(fn ->
      bound_row(@fresh_slot).commit_lsn == lsn
    end)
  end

  test "sibling halt: a foreign-identity row under the same slot halts :source_identity_rebound, value-free" do
    ref = attach_events()
    identity = Marquee.source_identity()

    # A DIFFERENT source's row already owns the slot name.
    plant_row(%{
      source_system_id: "sentinel-foreign-system",
      source_database: identity[:database],
      slot_name: @slot,
      commit_lsn: 5
    })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _pid} = start(SinkA, @slot)

        assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                        %{reason: :source_identity_rebound}},
                       15_000

        assert_receive {:telemetry, ^ref, [:replicant, :connection, :session_identity_rejected],
                        %{}},
                       15_000
      end)

    refute log =~ "sentinel-foreign-system"

    # The foreign row is untouched — no foreign watermark was continued or erased.
    row = bound_row(@slot)
    assert row.source_system_id == "sentinel-foreign-system"
    assert row.commit_lsn == 5
  end

  test "timeline halt: a stored timeline that differs from the session halts :source_timeline_changed" do
    ref = attach_events()
    identity = Marquee.source_identity()

    plant_row(%{
      source_system_id: identity[:system_identifier],
      source_database: identity[:database],
      slot_name: @slot,
      source_timeline: 99,
      commit_lsn: nil
    })

    assert {:ok, _pid} = start(SinkA, @slot)

    assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                    %{reason: :source_timeline_changed}},
                   15_000

    assert bound_row(@slot).source_timeline == 99
  end

  test "liveness halt: a watermark beyond the session's flush position halts :source_behind_watermark" do
    ref = attach_events()
    identity = Marquee.source_identity()

    planted_watermark = flush_lsn() + 1_000_000_000

    plant_row(%{
      source_system_id: identity[:system_identifier],
      source_database: identity[:database],
      slot_name: @slot,
      source_timeline: live_timeline(),
      commit_lsn: planted_watermark
    })

    assert {:ok, _pid} = start(SinkA, @slot)

    assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                    %{reason: :source_behind_watermark}},
                   15_000

    assert bound_row(@slot).commit_lsn == planted_watermark
  end

  test "compatible transition: an added relation replaces the contract atomically, LSN byte-identical" do
    ref = attach_events()

    # Phase 1: bind under contract A on a live slot, then advance the watermark
    # to the slot's confirmed flush (durable state a real deployment would have).
    assert {:ok, _pid} = start(SinkA, @slot)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    assert :ok = AshReplicant.stop_supervised(@slot)

    watermark = confirmed_flush(@slot)

    Marquee.q!("UPDATE ash_replicant_checkpoints SET commit_lsn = $1 WHERE slot_name = $2", [
      watermark,
      @slot
    ])

    # Phase 2: SinkB's contract ADDS a relation — set-monotone growth, compatible.
    assert {:ok, _pid} = start(SinkB, @slot)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    row = bound_row(@slot)
    contract_b = contract_for(SinkB)
    assert row.publication_fingerprint == contract_b.fingerprint
    assert Identity.decode(row.publication_contract) == {:ok, contract_b.manifest}
    assert row.commit_lsn == watermark
  end

  test "incompatible transition: a removed relation halts :publication_contract_incompatible, row untouched" do
    identity = Marquee.source_identity()

    contract_b = contract_for(SinkB)

    plant_row(%{
      source_system_id: identity[:system_identifier],
      source_database: identity[:database],
      slot_name: @slot,
      source_timeline: live_timeline(),
      commit_lsn: 12_345,
      publication_contract: contract_b.encoded,
      publication_fingerprint: contract_b.fingerprint
    })

    ref = attach_events()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # SinkA's contract REMOVES a relation — a recorded entry's removal halts.
        assert {:ok, _pid} = start(SinkA, @slot)

        assert_receive {:telemetry, ^ref, [:ash_replicant, :checkpoint, :conflict],
                        %{reason: :publication_contract_incompatible}},
                       15_000
      end)

    refute log =~ "contract_extras"

    row = bound_row(@slot)
    assert row.publication_fingerprint == contract_b.fingerprint
    assert row.commit_lsn == 12_345
  end

  test "steady-state reconnect: an unchanged contract and timeline write NOTHING" do
    ref = attach_events()

    assert {:ok, _pid} = start(SinkA, @slot)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    assert :ok = AshReplicant.stop_supervised(@slot)

    watermark = confirmed_flush(@slot)

    Marquee.q!("UPDATE ash_replicant_checkpoints SET commit_lsn = $1 WHERE slot_name = $2", [
      watermark,
      @slot
    ])

    before = bound_row(@slot)

    assert {:ok, _pid} = start(SinkA, @slot)
    assert_receive {:telemetry, ^ref, [:replicant, :connection, :slot_active], %{}}, 15_000

    after_start = bound_row(@slot)
    assert after_start.publication_fingerprint == before.publication_fingerprint
    assert after_start.updated_at == before.updated_at
    assert after_start.commit_lsn == watermark
  end

  # --- helpers ---

  defp start(sink, _slot) do
    AshReplicant.start_link(
      sink: sink,
      connection: Marquee.conn(),
      publication: Marquee.publication(),
      source_identity: Marquee.source_identity(),
      go_forward_only: true
    )
    |> case do
      {:ok, pid} -> {:ok, pid}
      other -> other
    end
  end

  defp attach_events do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:ash_replicant, :checkpoint, :conflict],
        [:ash_replicant, :sink, :applied],
        [:replicant, :connection, :session_identity_rejected],
        [:replicant, :connection, :slot_active]
      ],
      fn event, measurements, meta, _c ->
        send(test_pid, {:telemetry, ref, event, Map.merge(measurements, meta)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  defp contract_for(sink) do
    {:ok, contract} =
      Identity.build_contract(sink.__ash_replicant_config__(), [Marquee.publication()])

    contract
  end

  defp plant_row(values) do
    columns = Map.keys(values)
    placeholders = Enum.map(1..length(columns), &"$#{&1}")

    Marquee.q!(
      "INSERT INTO ash_replicant_checkpoints (" <>
        Enum.map_join(columns, ", ", &to_string/1) <>
        ", inserted_at, updated_at) VALUES (" <>
        Enum.join(placeholders, ", ") <> ", now(), now()) ON CONFLICT DO NOTHING",
      Enum.map(columns, &Map.get(values, &1))
    )
  end

  defp bound_row(slot) do
    [[sys, db, slot, timeline, lsn, contract, fingerprint, _inserted, updated]] =
      Marquee.q!(
        "SELECT source_system_id, source_database, slot_name, source_timeline, commit_lsn, " <>
          "publication_contract, publication_fingerprint, inserted_at, updated_at " <>
          "FROM ash_replicant_checkpoints WHERE slot_name = $1",
        [slot]
      ).rows

    %{
      source_system_id: sys,
      source_database: db,
      slot_name: slot,
      source_timeline: timeline,
      commit_lsn: lsn,
      publication_contract: contract,
      publication_fingerprint: fingerprint,
      updated_at: updated
    }
  end

  defp live_timeline do
    [[timeline]] = Marquee.q!("SELECT timeline_id FROM pg_control_checkpoint()").rows
    timeline
  end

  defp confirmed_flush(slot) do
    [[lsn]] =
      Marquee.q!(
        "SELECT confirmed_flush_lsn::text FROM pg_replication_slots WHERE slot_name = $1",
        [
          slot
        ]
      ).rows

    parse_lsn(lsn)
  end

  defp flush_lsn do
    [[lsn]] = Marquee.q!("SELECT pg_current_wal_flush_lsn()::text").rows
    parse_lsn(lsn)
  end

  defp parse_lsn(lsn) do
    [file, offset] = String.split(lsn, "/", parts: 2)
    String.to_integer(file, 16) * 4_294_967_296 + String.to_integer(offset, 16)
  end
end
