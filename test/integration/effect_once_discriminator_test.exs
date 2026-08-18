defmodule AshReplicant.EffectOnceDiscriminatorTest.D1Auxiliary do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.EffectOnceDiscriminatorTest.D1Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table "d1_auxiliary"
    repo AshReplicant.TestRepo
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]

    create :record do
      transaction? true
      argument :operation_key, :string, allow_nil?: false, public?: false
      accept []
    end
  end

  onetime do
    protect :record do
      strategy :idempotency

      scope([
        {:static, "ash_replicant:destination-participant:1"},
        {:static, "d1_auxiliary"}
      ])

      key({:argument, :operation_key})
      fingerprint(arguments: [:operation_key])

      response(AshOnetime.Codec.Resource,
        fields: [:id],
        classify: AshReplicant.Test.Marquee.StoreResponse
      )

      retention({1, :day})
    end
  end
end

defmodule AshReplicant.EffectOnceDiscriminatorTest.D1Version do
  @moduledoc false
  # SCD2 mirror whose BUSINESS KEY (order_id) differs from the source PRIMARY
  # KEY (id) — the only shape where one change can retire key A's version and
  # re-key onto an EXISTING key B, firing two ROW-MATCHING closes in ONE
  # change (one ordinal).
  use Ash.Resource,
    domain: AshReplicant.EffectOnceDiscriminatorTest.D1Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshReplicant.Resource]

  postgres do
    table "d1_versions"
    repo AshReplicant.TestRepo

    custom_indexes do
      index [:order_id],
        unique: true,
        where: "valid_to_lsn IS NULL",
        name: "d1_versions_open_uniq"

      index [:order_id, :valid_from_lsn],
        unique: true,
        name: "d1_versions_identity"
    end
  end

  replicant do
    source_table("d1_src")
    # The source surrogate PK is not mirrored (the version PK is its own uuid;
    # the business key carries identity).
    skip([:sid])
    history_strategy(:scd2)
    history_business_key([:order_id])
    upsert_identity(:d1_version)
    history_close_action(:close_version)
  end

  attributes do
    uuid_primary_key :id
    attribute :order_id, :string, allow_nil?: false, public?: true
    attribute :amount, :string, public?: true
    attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
    attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
  end

  identities do
    identity :d1_version, [:order_id, :valid_from_lsn]
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :create do
      primary? true

      accept [:order_id, :amount, :valid_from_lsn, :valid_to_lsn]

      touches_resources [AshReplicant.EffectOnceDiscriminatorTest.D1Auxiliary]

      change {AshReplicant.Test.Marquee.RecordAuxiliary,
              resource: AshReplicant.EffectOnceDiscriminatorTest.D1Auxiliary,
              participant: :d1_auxiliary,
              escape_table: "d1_auxiliary",
              fault_key: {AshReplicant.Test.Marquee, :scd2_between_effects_fault},
              observer_key: {AshReplicant.Test.Marquee, :observer}}
    end

    update :close_version do
      accept [:valid_to_lsn]

      touches_resources [AshReplicant.EffectOnceDiscriminatorTest.D1Auxiliary]

      change {AshReplicant.Test.Marquee.RecordAuxiliary,
              resource: AshReplicant.EffectOnceDiscriminatorTest.D1Auxiliary,
              participant: :d1_auxiliary,
              escape_table: "d1_auxiliary",
              fault_key: {AshReplicant.Test.Marquee, :scd2_between_effects_fault},
              observer_key: {AshReplicant.Test.Marquee, :observer}}
    end
  end
end

defmodule AshReplicant.EffectOnceDiscriminatorTest.D1Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.EffectOnceDiscriminatorTest.D1Version
    resource AshReplicant.EffectOnceDiscriminatorTest.D1Auxiliary
    resource AshReplicant.Test.Checkpoint
  end
end

defmodule AshReplicant.EffectOnceDiscriminatorTest.D1Sink do
  @moduledoc false
  use AshReplicant.Sink,
    repo: AshReplicant.TestRepo,
    domains: [AshReplicant.EffectOnceDiscriminatorTest.D1Domain],
    checkpoint_resource: AshReplicant.Test.Checkpoint,
    slot_name: "d1_discriminator_slot"
end

defmodule AshReplicant.EffectOnceDiscriminatorTest do
  @moduledoc """
  The U3/D1 headline marquee: the intra-change operation-key collision. One
  change (one ordinal) fires close_prior + close_current + open through the
  SAME history_close_action twice — pre-discriminator the two operation keys
  COLLIDE, AshOnetime replays the first close's stored response for the
  second, and the declared close effect never runs: o2's prior version stays
  open and the subsequent open violates the open-version unique index (the
  transaction rolls back and the pipeline wedges fail-closed — the declared
  effect silently missing one layer up). The per-invocation discriminator
  gives every invocation its own key: both closes claim, the update applies
  cleanly, exactly one version per business key stays open.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.{DestinationObserver, Marquee}
  alias AshReplicant.Test.PG
  alias Ecto.Adapters.SQL.Sandbox

  @slot "d1_discriminator_slot"
  @publication "repl_d1_pub"
  @src "d1_src"

  setup do
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)
    Sandbox.mode(AshReplicant.TestRepo, :auto)

    Marquee.setup_schema!()
    Marquee.drop_slot!(@slot)
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
    Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
    Marquee.q!("DROP TABLE IF EXISTS #{@src}")
    Marquee.q!("DROP TABLE IF EXISTS d1_versions")
    Marquee.q!("DROP TABLE IF EXISTS d1_auxiliary")

    Marquee.q!("CREATE TABLE #{@src} (sid text primary key, order_id text, amount text)")
    Marquee.q!("ALTER TABLE #{@src} REPLICA IDENTITY FULL")
    Marquee.q!("CREATE PUBLICATION #{@publication} FOR TABLE #{@src}")

    Marquee.q!("""
    CREATE TABLE d1_versions (
      id uuid primary key,
      order_id text not null,
      amount text,
      valid_from_lsn bigint not null,
      valid_to_lsn bigint
    )
    """)

    Marquee.q!(
      "CREATE UNIQUE INDEX d1_versions_open_uniq ON d1_versions (order_id) WHERE valid_to_lsn IS NULL"
    )

    Marquee.q!(
      "CREATE UNIQUE INDEX d1_versions_identity ON d1_versions (order_id, valid_from_lsn)"
    )

    Marquee.q!("CREATE TABLE d1_auxiliary (id uuid primary key)")

    run_id = "d1-#{System.unique_integer([:positive])}"

    DestinationObserver.setup!(run_id, [
      %{table: "d1_versions", participant: "mapped", operations: [:insert, :update, :delete]},
      %{table: "d1_auxiliary", participant: "auxiliary", operations: [:insert]}
    ])

    :persistent_term.put(Marquee.scd2_fault_key(), false)
    :persistent_term.put(Marquee.observer_key(), self())

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

      DestinationObserver.teardown!([
        %{table: "d1_versions", participant: "mapped", operations: [:insert, :update, :delete]},
        %{table: "d1_auxiliary", participant: "auxiliary", operations: [:insert]}
      ])

      Marquee.q!("DROP PUBLICATION IF EXISTS #{@publication}")
      Marquee.q!("DROP TABLE IF EXISTS #{@src}")
      Marquee.q!("DROP TABLE IF EXISTS d1_versions")
      Marquee.q!("DROP TABLE IF EXISTS d1_auxiliary")
      Marquee.teardown_schema!()
      :persistent_term.erase(Marquee.scd2_fault_key())
      :persistent_term.erase(Marquee.observer_key())
    end)

    {:ok, run_id: run_id}
  end

  defp start! do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _meta, _cfg -> send(test_pid, {:slot_active, ref}) end,
      nil
    )

    {:ok, _pid} =
      AshReplicant.start_link(
        sink: AshReplicant.EffectOnceDiscriminatorTest.D1Sink,
        connection: Marquee.conn(),
        slot_name: @slot,
        publication: @publication,
        source_identity: Marquee.source_identity(),
        go_forward_only: true
      )

    receive do
      {:slot_active, ^ref} -> :ok
    after
      15_000 -> flunk("pipeline never reached slot_active for #{@slot}")
    end

    :telemetry.detach({__MODULE__, ref})
  end

  defp versions(key) do
    Marquee.q!(
      "SELECT order_id, valid_from_lsn, valid_to_lsn FROM d1_versions ORDER BY valid_from_lsn"
    ).rows
    |> Enum.filter(&match?([^key, _, _], &1))
  end

  test "both closes of one key-changing change claim and apply (the discriminator)", %{
    run_id: run_id
  } do
    start!()

    Marquee.q!("INSERT INTO #{@src} (sid, order_id, amount) VALUES ('1', 'o1', '1')")
    Marquee.q!("INSERT INTO #{@src} (sid, order_id, amount) VALUES ('2', 'o2', '2')")
    PG.wait_until(fn -> length(versions("o1")) == 1 end)
    PG.wait_until(fn -> length(versions("o2")) == 1 end)

    # Re-key row 1 onto the EXISTING business key o2: close_prior (o1's
    # version) + close_current (o2's prior open version) + open (o2 v2) — one
    # change, one ordinal, THREE invocations, two of them the same action.
    Marquee.q!("UPDATE #{@src} SET order_id = 'o2' WHERE sid = '1'")

    PG.wait_until(fn -> length(versions("o2")) == 2 end)

    o2 = versions("o2")
    assert length(o2) == 2, "anti-vacuity: the re-key must produce o2's second version"

    assert Enum.count(o2, &match?([_, _, nil], &1)) == 1,
           "exactly one open o2 version: the prior one must be CLOSED by its own close invocation, not left open by a replayed-away claim"

    refute Enum.any?(versions("o1"), &match?([_, _, nil], &1)),
           "o1's version must be terminally closed by close_prior"

    # Both close invocations recorded their auxiliary effect — the second
    # close's claim is NOT replayed away (the observer's auxiliary rows for
    # this update: 2 closes + 1 open).
    PG.wait_until(fn -> DestinationObserver.effect_count(run_id, "auxiliary", "INSERT") == 5 end)

    assert DestinationObserver.effect_count(run_id, "auxiliary", "INSERT") == 5,
           "2 opens (initial) + 2 closes + 1 open (re-key) — every invocation claims"
  end
end
