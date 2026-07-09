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
end
