defmodule AshReplicant.NotifierSuppressionTest do
  @moduledoc """
  Locks the sink contract (`lib/ash_replicant/sink/impl.ex:8-13`, AGENTS Rule 1):
  Ash notifiers / PubSub do NOT fire for MIRRORED changes. Both write paths rely on
  it — the upsert passes `return_notifications?: true` (Ash bundles-and-discards),
  and the F14 delete (`Ash.bulk_destroy!`) relies on `notify?` defaulting to false.
  The suite otherwise has zero notifiers, so this is the only guard a future edit
  that flips notifications on (or a dependency default change) would turn RED.
  """
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Apply

  defmodule EchoNotifier do
    @moduledoc false
    use Ash.Notifier

    @impl Ash.Notifier
    def notify(%Ash.Notifier.Notification{action: action, data: data}) do
      case Application.get_env(:ash_replicant, :notifier_probe_pid) do
        nil -> :ok
        pid -> send(pid, {:notified, action.type, Map.get(data, :id)})
      end
    end
  end

  defmodule NotifierDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  # A replicant resource whose create + destroy actions carry a notifier. Reuses the
  # existing `orders` table (no migration) and is NOT in `ash_domains` (no
  # migration-drift), the same fixture pattern as `ApplyTest.MirrorTruncateOrder`.
  defmodule NotifierOrder do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.NotifierSuppressionTest.NotifierDomain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      notifiers: [AshReplicant.NotifierSuppressionTest.EchoNotifier],
      extensions: [AshReplicant.Resource]

    postgres do
      table "orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("orders")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  # An SCD2 version resource WITH a notifier, mirroring `Test.OrderVersion`'s shape
  # exactly (reuses the existing `order_versions` table — NOT in `ash_domains`, no
  # migration). Differs from `Test.OrderVersion` ONLY by domain + the `EchoNotifier`.
  # The notifier is what makes the SCD2 `refute_receive` NON-VACUOUS: the open path
  # (`Ash.create!` upsert) and the close path (`Ash.bulk_update!`) both dispatch to
  # THIS resource's notifier unless the sink suppresses them — the exact contract
  # under test. `Test.OrderVersion` has NO notifier, so a refute over it would pass
  # vacuously; this fixture can genuinely go RED.
  defmodule NotifierOrderVersion do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.NotifierSuppressionTest.NotifierDomain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      notifiers: [AshReplicant.NotifierSuppressionTest.EchoNotifier],
      extensions: [AshReplicant.Resource]

    postgres do
      table "order_versions"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("orders")
      history_strategy(:scd2)
      history_business_key([:order_id])
      upsert_identity(:order_version)
      history_close_action(:close_version)
      history_current_attribute(:is_current)
      history_valid_from_timestamp_attribute(:valid_from_ts)
      history_valid_to_timestamp_attribute(:valid_to_ts)
    end

    attributes do
      uuid_primary_key :id
      attribute :order_id, :string, allow_nil?: false, public?: true
      attribute :amount, :string, public?: true
      attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
      attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
      attribute :valid_from_ts, :utc_datetime_usec, allow_nil?: true, public?: true
      attribute :valid_to_ts, :utc_datetime_usec, allow_nil?: true, public?: true
      attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true
    end

    identities do
      identity :order_version, [:order_id, :valid_from_lsn]
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      update :close_version do
        accept [:valid_to_lsn, :valid_to_ts, :is_current]
      end
    end
  end

  setup do
    Application.put_env(:ash_replicant, :notifier_probe_pid, self())
    on_exit(fn -> Application.delete_env(:ash_replicant, :notifier_probe_pid) end)

    cfg = %{
      resolver_index: %{{"public", "orders"} => NotifierOrder},
      repo: AshReplicant.TestRepo,
      authorize?: false
    }

    {:ok, cfg: cfg}
  end

  defp change(op, record, old_record \\ nil) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: "orders",
      record: record,
      old_record: old_record,
      unchanged: []
    }
  end

  test "a mirrored insert and delete fire NO Ash notifier (sink suppresses notifications)",
       %{cfg: cfg} do
    # NON-VACUITY CONTROL: a NON-mirrored create DOES dispatch to the notifier — this
    # proves the notifier pipeline is wired, so the `refute_receive` below can
    # genuinely go RED if the sink ever stops suppressing.
    Ash.create!(NotifierOrder, %{id: "control", note: "c"}, authorize?: false)
    assert_receive {:notified, :create, "control"}, 500

    # CONTRACT: the mirrored insert (upsert, `return_notifications?: true`) and the
    # mirrored delete (`bulk_destroy!`, `notify?` default false) dispatch NOTHING to
    # the notifier. Keyed on the mirrored PK "m1" so a stray control message can't
    # mask a real leak.
    assert :ok = Apply.apply_change(cfg, change(:insert, %{"id" => "m1", "note" => "n"}))
    assert :ok = Apply.apply_change(cfg, change(:delete, nil, %{"id" => "m1"}))

    refute_receive {:notified, _type, "m1"}, 300
  end

  test "SCD2 open and close fire NO notifier (bulk_update close + create! open both gated)" do
    config = %{
      resolver_index: %{{"public", "orders"} => NotifierOrderVersion},
      repo: AshReplicant.TestRepo,
      authorize?: false
    }

    # NON-VACUITY CONTROL: a direct create on the SCD2 version resource DOES dispatch to
    # the notifier — proves the pipeline is wired for THIS resource (a uuid-PK'd version
    # row, distinct from the SCD1 `NotifierOrder` control above), so the `refute_receive`s
    # below can genuinely go RED if the sink ever stops suppressing.
    Ash.create!(NotifierOrderVersion, %{order_id: "ctl", amount: "0", valid_from_lsn: 1},
      authorize?: false
    )

    assert_receive {:notified, :create, _}, 500

    # SCD2 insert = OPEN (`Ash.create!` upsert, `return_notifications?: true`) → NO dispatch.
    AshReplicant.Apply.apply_change(
      config,
      %Replicant.Change{
        op: :insert,
        schema: "public",
        table: "orders",
        record: %{"order_id" => "n1", "amount" => "1"},
        commit_lsn: 100
      },
      nil
    )

    refute_receive {:notified, _type, _id}, 300

    # SCD2 update = CLOSE (`Ash.bulk_update!`, `return_notifications?: true`) + OPEN → NO
    # dispatch. If THIS refute goes red, the close `bulk_update` leaked a notification
    # despite `return_notifications?: true` — the bulk_update-gating spike, answered by test.
    AshReplicant.Apply.apply_change(
      config,
      %Replicant.Change{
        op: :update,
        schema: "public",
        table: "orders",
        record: %{"order_id" => "n1", "amount" => "2"},
        commit_lsn: 200
      },
      nil
    )

    refute_receive {:notified, _type, _id}, 300
  end
end
