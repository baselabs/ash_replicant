defmodule AshReplicant.Test.Status.Order do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Test.Status.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "o02_status_mirror_orders"
    repo AshReplicant.TestRepo
  end

  replicant do
    source_table("o02_status_orders")
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

defmodule AshReplicant.Test.Status.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.Status.Order
  end
end

defmodule AshReplicant.Test.Status.Sink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.Test.Status.Domain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "o02_status_slot"
end

defmodule AshReplicant.StatusIntegrationTest do
  @moduledoc """
  O02 (issue #12) live acceptance: the states a database-free suite cannot
  reach — `:healthy` under a passing census — and the DURABLE tombstone
  legs: a real halt persists the value-free cause on the checkpoint row,
  the bind and the advance of a successor generation clear it, and a
  foreign persisted cause decodes to the closed fallback.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshReplicant.Test.Marquee
  alias AshReplicant.Test.Status.Sink
  alias Ecto.Adapters.SQL.Sandbox

  @slot "o02_status_slot"
  @publication "repl_o02_status_pub"
  @src "o02_status_orders"

  @census [interval_ms: 200, jitter_ratio: 0.0, timeout_ms: 1_000, max_consecutive_faults: 100]

  setup do
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)
    Sandbox.mode(AshReplicant.TestRepo, :auto)

    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("DROP TABLE IF EXISTS o02_status_mirror_orders")

    Marquee.q!("CREATE TABLE #{@src} (id text primary key, note text)")
    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")

    Marquee.q!("CREATE TABLE o02_status_mirror_orders (id text primary key, note text)")

    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS o02_status_mirror_orders")
      Marquee.teardown_schema!()
    end)

    :ok
  end

  defp start(census \\ @census) do
    AshReplicant.start_link(
      sink: Sink,
      connection: Marquee.conn(),
      publication: @publication,
      source_identity: Marquee.source_identity(),
      go_forward_only: true,
      census: census
    )
  end

  defp eventually(fun, polls \\ 200) do
    cond do
      fun.() -> :ok
      polls == 0 -> flunk("condition not reached within the poll budget")
      true -> Process.sleep(25) && eventually(fun, polls - 1)
    end
  end

  defp durable_tombstone do
    case Marquee.q!(
           "SELECT terminal_cause, terminal_class FROM ash_replicant_checkpoints WHERE slot_name = $1",
           [@slot]
         ) do
      %{rows: [[cause, class]]} -> %{cause: cause, class: class}
      _other -> nil
    end
  end

  test "a live pipeline under a passing census is healthy, and the terminal-clear round-trip holds" do
    assert {:ok, _owner} = start()

    # Bind happens on connect; the first census then proves the invariants.
    eventually(fn -> match?(:healthy, AshReplicant.status(Sink)) end)
    assert %{lifecycle: :ready} = AshReplicant.Status.derive(Sink)

    # An operator stop persists the durable stopped tombstone.
    assert :ok = AshReplicant.stop_supervised(@slot)
    assert %{cause: "operator_stopped", class: "stopped"} = durable_tombstone()
    assert :not_started = AshReplicant.status(Sink)

    # The successor generation's BIND is an admitted checkpoint write: the
    # stale terminal columns clear with it, even before any advance.
    assert {:ok, _owner2} = start()
    eventually(fn -> match?(:catching_up, AshReplicant.status(Sink)) end)
    eventually(fn -> is_nil(durable_tombstone()[:cause]) end)

    # The ADVANCE clear: a seeded terminal cause must not outlive the next
    # committed delivery (the delivery's checkpoint write clears it).
    Marquee.q!(
      "UPDATE ash_replicant_checkpoints SET terminal_cause = $1, terminal_class = $2 WHERE slot_name = $3",
      ["census_unverifiable", "halt", @slot]
    )

    assert %{cause: "census_unverifiable", class: "halt"} = durable_tombstone()
    assert {:halted, :census_unverifiable} = AshReplicant.status(Sink)

    Marquee.q!("INSERT INTO #{@src} VALUES ($1, $2)", ["o02-1", "note"])

    eventually(fn ->
      case Marquee.q!("SELECT note FROM o02_status_mirror_orders WHERE id = $1", ["o02-1"]) do
        %{rows: [["note"]]} -> true
        _other -> false
      end
    end)

    eventually(fn -> is_nil(durable_tombstone()[:cause]) end)
    eventually(fn -> match?(:healthy, AshReplicant.status(Sink)) end)

    assert :ok = AshReplicant.stop_supervised(@slot)
  end

  test "a census drift halt persists the value-free cause durably and reports misconfigured" do
    assert {:ok, _owner} = start()
    eventually(fn -> match?(:healthy, AshReplicant.status(Sink)) end)

    # Real substrate drift: the stored publication contract becomes
    # undecodable (the census_drift precedent), so the census's checkpoint
    # classification halts on the next run.
    Marquee.q!(
      "UPDATE ash_replicant_checkpoints SET publication_contract = $1 WHERE slot_name = $2",
      [<<0, 1, 2, 3>>, @slot]
    )

    eventually(fn ->
      match?({:misconfigured, :publication_contract_incompatible}, AshReplicant.status(Sink))
    end)

    assert %{cause: "publication_contract_incompatible", class: "misconfigured"} =
             durable_tombstone()

    assert %{lifecycle: :halted} = AshReplicant.Status.derive(Sink)
  end

  test "a foreign persisted cause decodes to the closed fallback without minting" do
    assert {:ok, _owner} = start()
    eventually(fn -> match?(:healthy, AshReplicant.status(Sink)) end)
    assert :ok = AshReplicant.stop_supervised(@slot)

    Marquee.q!(
      "UPDATE ash_replicant_checkpoints SET terminal_cause = $1 WHERE slot_name = $2",
      ["not_a_closed_reason_zq", @slot]
    )

    :persistent_term.erase({AshReplicant.Status, @slot})

    assert {:halted, :tombstone_unknown} = AshReplicant.status(Sink)
  end
end
