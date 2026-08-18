defmodule AshReplicant.TelemetryConformanceTest.ConfMirrorOrder do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.TelemetryConformanceTest.ConfMirrorDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "conf_mirror_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("conf_src_orders")
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

defmodule AshReplicant.TelemetryConformanceTest.ConfMirrorDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.TelemetryConformanceTest.ConfMirrorOrder
  end
end

defmodule AshReplicant.TelemetryConformanceTest.ConfMirrorSink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.TelemetryConformanceTest.ConfMirrorDomain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "conf_telemetry_slot"
end

defmodule AshReplicant.TelemetryConformanceTest do
  @moduledoc """
  U3/D5 telemetry conformance gate (the c1 graft): handlers attached to EVERY
  event name the library emits — `Telemetry.emitted_event_names/0` is the
  authoritative inventory — and each observed payload is re-validated through
  the enforcement point itself in the handler. A future call site emitting an
  off-type value or a value-bearing measurement raises INSIDE the handler,
  turning a silent downstream leak into a red test at the emission site.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshReplicant.Telemetry
  alias AshReplicant.Test.{Marquee, PG}
  alias Ecto.Adapters.SQL.Sandbox

  @slot "conf_telemetry_slot"
  @publication "repl_conf_telemetry_pub"
  @src "conf_src_orders"

  setup do
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("DROP TABLE IF EXISTS conf_mirror_orders")

    Marquee.q!("CREATE TABLE #{@src} (id text primary key, note text)")
    Marquee.q!("CREATE TABLE conf_mirror_orders (id text primary key, note text)")
    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    test_pid = self()

    # The conformance handlers: every emission is validated by the SAME
    # enforcement point that gates direct calls — self-checking, so a bad
    # shape cannot pass silently no matter which internal path emits it.
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach_many(
      handler_id,
      Telemetry.emitted_event_names(),
      fn event, measurements, meta, _c ->
        Telemetry.validate_measurements!(measurements)
        Telemetry.validate!(meta)
        send(test_pid, {:conform, event})
      end,
      nil
    )

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS conf_mirror_orders")
      Marquee.teardown_schema!()
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  test "every live emission across a full pipeline cycle conforms to the closed types" do
    Marquee.q!("INSERT INTO #{@src} VALUES ('1', 'a')")

    assert {:ok, _pid} =
             AshReplicant.start_link(
               sink: AshReplicant.TelemetryConformanceTest.ConfMirrorSink,
               connection: Marquee.conn(),
               publication: @publication,
               source_identity: Marquee.source_identity(),
               snapshot: true
             )

    PG.wait_until(fn ->
      Marquee.q!("SELECT id, note FROM conf_mirror_orders ORDER BY id").rows == [["1", "a"]]
    end)

    # Streaming leg: a fresh change drives the applied/applied-shape path.
    Marquee.q!("INSERT INTO #{@src} VALUES ('2', 'b')")
    PG.wait_until(fn -> row_count() == 2 end)

    observed = collect_conformances()

    # The cycle must have exercised at least the identity, snapshot, and
    # applied emissions — a handler that never fires proves nothing.
    assert [:ash_replicant, :sink, :session_identity_accepted] in observed
    assert [:ash_replicant, :snapshot, :batch] in observed
    assert [:ash_replicant, :snapshot, :complete] in observed
    assert [:ash_replicant, :sink, :applied] in observed
  end

  defp row_count do
    Marquee.q!("SELECT count(*) FROM conf_mirror_orders").rows |> List.first() |> List.first()
  end

  defp collect_conformances do
    Enum.reduce_while(Stream.repeatedly(fn -> :ok end), [], fn _i, acc ->
      receive do
        {:conform, event} -> {:cont, [event | acc]}
      after
        50 -> {:halt, Enum.reverse(acc)}
      end
    end)
  end
end
