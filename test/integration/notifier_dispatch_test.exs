defmodule AshReplicant.NotifierDispatchTest do
  use AshReplicant.DataCase, async: false
  @moduletag :integration

  alias Ecto.Adapters.SQL

  alias AshReplicant.{Apply, Horizon, Messages, Status}
  alias AshReplicant.Snapshot.{Provenance, Retirement, Rows}
  alias AshReplicant.Test.Marquee

  defmodule Observer do
    use Ash.Notifier

    def notify(notification) do
      if pid = Application.get_env(:ash_replicant, :dispatch_witness_pid) do
        send(pid, {:dispatched, notification.resource, notification.action.name})
      end

      :ok
    end
  end

  defmodule DependencyObserver do
    alias AshReplicant.NotifierDispatchTest.Observer

    use Ash.Notifier
    use AshReplicant.Notifier
    @behaviour AshReplicant.DestinationParticipant
    @impl AshReplicant.Notifier
    def preload(_resource, _action), do: [:notification_dependency]
    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, _context), do: {:ok, :no_database}
    @impl Ash.Notifier
    def notify(notification), do: Observer.notify(notification)
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Event do
    use Ash.Resource,
      domain: AshReplicant.NotifierDispatchTest.Domain,
      validate_domain_inclusion?: false,
      notifiers: [AshReplicant.NotifierDispatchTest.Observer],
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "order_events"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("orders")
      append_log(true)
      on_truncate(:append)
    end

    attributes do
      uuid_primary_key :event_id

      attribute :source_system_id, :string, allow_nil?: false, public?: true
      attribute :source_database, :string, allow_nil?: false, public?: true
      attribute :slot_name, :string, allow_nil?: false, public?: true
      attribute :commit_lsn, :integer, allow_nil?: false, public?: true
      attribute :ordinal, :integer, allow_nil?: false, public?: true
      attribute :operation, :string, allow_nil?: false, public?: true
      attribute :origin, :string, allow_nil?: false, public?: true
      attribute :snapshot_attempt, :binary, public?: true

      attribute :id, :string, public?: true
      attribute :note, :string, public?: true
      attribute :body, :string, public?: true
      attribute :message_prefix, :string, public?: true
      attribute :message_content, :binary, public?: true
    end

    identities do
      identity :append_identity, [
        :source_system_id,
        :source_database,
        :slot_name,
        :commit_lsn,
        :ordinal
      ]
    end

    actions do
      defaults [:read]

      create :append do
        accept [
          :source_system_id,
          :source_database,
          :slot_name,
          :commit_lsn,
          :ordinal,
          :operation,
          :origin,
          :snapshot_attempt,
          :id,
          :note,
          :body,
          :message_prefix,
          :message_content
        ]
      end
    end
  end

  defmodule Row do
    use Ash.Resource,
      domain: AshReplicant.NotifierDispatchTest.Domain,
      validate_domain_inclusion?: false,
      notifiers: [AshReplicant.NotifierDispatchTest.DependencyObserver],
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "snap_orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("notifier_source")
      snapshot_provenance(true)
    end

    attributes do
      attribute :id, :string do
        primary_key? true
        allow_nil? false
        public? true
      end

      attribute :note, :string, public?: true

      attribute :replica_fingerprint, :binary, public?: false, writable?: false
      attribute :replica_seen_attempt, :binary, public?: false, writable?: false
    end

    calculations do
      calculate :notification_dependency, :boolean do
        calculation fn records, _context ->
          if pid = Application.get_env(:ash_replicant, :dispatch_witness_pid) do
            send(pid, {:dependency_loaded, __MODULE__})
          end

          Enum.map(records, &(!is_nil(Map.get(&1, :id))))
        end
      end
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      update :replicant_mark_seen do
        public? false
        accept []
        require_atomic? false
        change AshReplicant.Snapshot.MarkSeen
      end

      destroy :replicant_retire_unseen do
        public? false
      end
    end
  end

  defmodule Version do
    use Ash.Resource,
      domain: AshReplicant.NotifierDispatchTest.Domain,
      validate_domain_inclusion?: false,
      notifiers: [AshReplicant.NotifierDispatchTest.DependencyObserver],
      data_layer: AshPostgres.DataLayer,
      extensions: [AshReplicant.Resource]

    postgres do
      table "snap_versions"
      repo AshReplicant.TestRepo

      custom_indexes do
        index [:order_id],
          unique: true,
          where: "valid_to_lsn IS NULL",
          name: "snap_versions_open_uniq"
      end
    end

    replicant do
      source_table("snap_versions")
      history_strategy(:scd2)
      history_business_key([:order_id])
      upsert_identity(:snap_version)
      history_close_action(:close_version)
      history_current_attribute(:is_current)
      snapshot_provenance(true)
    end

    attributes do
      uuid_primary_key :id
      attribute :order_id, :string, allow_nil?: false, public?: true
      attribute :amount, :string, public?: true
      attribute :valid_from_lsn, :integer, allow_nil?: false, public?: true
      attribute :valid_to_lsn, :integer, allow_nil?: true, public?: true
      attribute :is_current, :boolean, allow_nil?: false, default: true, public?: true

      attribute :replica_fingerprint, :binary, public?: false, writable?: false
      attribute :replica_seen_attempt, :binary, public?: false, writable?: false
    end

    identities do
      identity :snap_version, [:order_id, :valid_from_lsn]
    end

    calculations do
      calculate :notification_dependency, :boolean do
        calculation fn records, _context ->
          if pid = Application.get_env(:ash_replicant, :dispatch_witness_pid) do
            send(pid, {:dependency_loaded, __MODULE__})
          end

          Enum.map(records, &(!is_nil(Map.get(&1, :id))))
        end
      end
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      update :close_version do
        accept [:valid_to_lsn, :is_current]
      end

      update :replicant_mark_seen do
        public? false
        accept []
        require_atomic? false
        change AshReplicant.Snapshot.MarkSeen
      end

      update :replicant_retire_unseen do
        public? false
        accept [:valid_to_lsn, :is_current]
      end
    end
  end

  # The real create boundary is tested directly: AshOnetime 1.5.0 refuses
  # notifiers on protected CRUD actions before message-route admission.
  defmodule Message do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.NotifierDispatchTest.Domain,
      validate_domain_inclusion?: false,
      notifiers: [AshReplicant.NotifierDispatchTest.Observer],
      data_layer: AshPostgres.DataLayer,
      extensions: []

    postgres do
      table "notifier_messages"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :content, :string, public?: true
    end

    actions do
      defaults [:read, create: :*]

      create :record do
        transaction? true
        accept [:content]
        argument :operation_key, :string, allow_nil?: false, public?: false
        argument :content_digest, :string, allow_nil?: false, public?: false
      end
    end
  end

  defmodule Checkpoint do
    use Ash.Resource,
      domain: AshReplicant.NotifierDispatchTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      notifiers: [AshReplicant.NotifierDispatchTest.Observer],
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table "ash_replicant_checkpoints"
      repo AshReplicant.TestRepo
    end

    attributes do
      for field <- [:source_system_id, :source_database, :slot_name] do
        attribute field, :string, primary_key?: true, allow_nil?: false
      end

      for field <- [:source_timeline, :commit_lsn, :origin_floor] do
        attribute field, :integer
      end

      for field <- [
            :publication_contract,
            :publication_fingerprint,
            :snapshot_progress,
            :snapshot_state,
            :digest_key_state
          ] do
        attribute field, :binary
      end

      attribute :terminal_cause, :string
      attribute :terminal_class, :string
      attribute :terminal_at, :utc_datetime_usec
      timestamps()
    end

    identities do
      identity :source_slot, [:source_system_id, :source_database, :slot_name]
    end

    actions do
      defaults [:read]

      create :upsert do
        upsert? true
        upsert_identity :source_slot

        accept [
          :source_system_id,
          :source_database,
          :slot_name,
          :source_timeline,
          :commit_lsn,
          :origin_floor,
          :publication_contract,
          :publication_fingerprint,
          :snapshot_progress,
          :snapshot_state,
          :digest_key_state,
          :terminal_cause,
          :terminal_class,
          :terminal_at
        ]
      end

      destroy :operator_reset
    end
  end

  defmodule Sink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.NotifierDispatchTest.Domain],
      checkpoint_resource: AshReplicant.NotifierDispatchTest.Checkpoint,
      slot_name: "notifier_operator_slot"
  end

  defmodule Mirror do
    use Ash.Resource,
      domain: AshReplicant.NotifierDispatchTest.MirrorDomain,
      data_layer: AshPostgres.DataLayer,
      notifiers: [AshReplicant.NotifierDispatchTest.DependencyObserver],
      extensions: [AshReplicant.Resource]

    postgres do
      table "snap_orders"
      repo AshReplicant.TestRepo
    end

    replicant do
      source_table("notifier_source")
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :note, :string, public?: true
    end

    calculations do
      calculate :notification_dependency, :boolean do
        calculation fn records, _context ->
          if pid = Application.get_env(:ash_replicant, :dispatch_witness_pid) do
            send(pid, {:dependency_loaded, __MODULE__})
          end

          Enum.map(records, &(!is_nil(Map.get(&1, :id))))
        end
      end
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]
    end
  end

  defmodule MirrorDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.NotifierDispatchTest.Mirror
    end
  end

  defmodule MirrorSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.NotifierDispatchTest.MirrorDomain],
      checkpoint_resource: AshReplicant.NotifierDispatchTest.Checkpoint,
      slot_name: "notifier_pipeline_slot"
  end

  setup do
    previous = Application.get_env(:ash_replicant, :dispatch_witness_pid, :unset)
    Application.put_env(:ash_replicant, :dispatch_witness_pid, self())

    on_exit(fn ->
      case previous do
        :unset -> Application.delete_env(:ash_replicant, :dispatch_witness_pid)
        value -> Application.put_env(:ash_replicant, :dispatch_witness_pid, value)
      end
    end)

    identity = Map.new(Marquee.source_identity())

    {:ok,
     identity: identity,
     config: %{
       repo: TestRepo,
       authorize?: false,
       source_identity: identity,
       resolver_index: %{{"public", "notifier_source"} => Row},
       slot_name: "notifier_operator_slot",
       checkpoint_resource: Checkpoint
     }}
  end

  defp checkpoint_inputs(identity, slot) do
    %{
      source_system_id: identity.system_identifier,
      source_database: identity.database,
      slot_name: slot
    }
  end

  defp checkpoint_control(identity) do
    Ash.create!(Checkpoint, checkpoint_inputs(identity, "notifier_control"),
      action: :upsert,
      authorize?: false
    )

    assert_receive {:dispatched, Checkpoint, :upsert}
  end

  test "checkpoint adoption suppresses dispatch", %{identity: identity} do
    checkpoint_control(identity)

    assert :ok =
             observe_collection([{:create!, 3}], fn ->
               AshReplicant.adopt_checkpoint(Sink, Map.to_list(identity), 10)
             end)

    assert_receive {:notification_collection, Checkpoint, true}
    refute_receive {:notification_collection, Checkpoint, false}

    assert [%{commit_lsn: 10}] =
             Ash.read!(Checkpoint, authorize?: false)
             |> Enum.filter(&(&1.slot_name == "notifier_operator_slot"))

    refute_receive {:dispatched, Checkpoint, _}
  end

  test "checkpoint reset suppresses dispatch", %{identity: identity} do
    checkpoint_control(identity)
    assert :ok = AshReplicant.adopt_checkpoint(Sink, Map.to_list(identity), 10)

    assert :ok =
             observe_collection([{:destroy!, 2}], fn ->
               AshReplicant.reset_checkpoint(Sink, Map.to_list(identity))
             end)

    assert_receive {:notification_collection, Checkpoint, true}
    refute_receive {:notification_collection, Checkpoint, false}

    assert [] =
             Ash.read!(Checkpoint, authorize?: false)
             |> Enum.filter(&(&1.slot_name == "notifier_operator_slot"))

    refute_receive {:dispatched, Checkpoint, _}
  end

  test "timeline acknowledgement suppresses dispatch", %{identity: identity} do
    inputs = Map.put(checkpoint_inputs(identity, "notifier_operator_slot"), :source_timeline, 1)
    Ash.create!(Checkpoint, inputs, action: :upsert, authorize?: false)
    assert_receive {:dispatched, Checkpoint, :upsert}

    assert :ok =
             observe_collection([{:create!, 3}], fn ->
               AshReplicant.acknowledge_checkpoint_timeline(Sink, Map.to_list(identity), 2)
             end)

    assert_receive {:notification_collection, Checkpoint, true}
    refute_receive {:notification_collection, Checkpoint, false}

    assert [%{source_timeline: 2}] =
             Ash.read!(Checkpoint, authorize?: false)
             |> Enum.filter(&(&1.slot_name == "notifier_operator_slot"))

    refute_receive {:dispatched, Checkpoint, _}
  end

  test "durable status suppresses dispatch", %{identity: identity} do
    Ash.create!(Checkpoint, checkpoint_inputs(identity, "notifier_operator_slot"),
      action: :upsert,
      authorize?: false
    )

    assert_receive {:dispatched, Checkpoint, :upsert}

    tombstone = %Status.Tombstone{
      cause: :operator_stopped,
      class: :stopped,
      at: DateTime.utc_now()
    }

    assert :ok =
             observe_collection([{:create!, 3}], fn ->
               Status.record_durable("notifier_operator_slot", Sink, identity, tombstone)
             end)

    assert_receive {:notification_collection, Checkpoint, true}
    refute_receive {:notification_collection, Checkpoint, false}

    assert [%{terminal_cause: "operator_stopped"}] =
             Ash.read!(Checkpoint, authorize?: false)
             |> Enum.filter(&(&1.slot_name == "notifier_operator_slot"))

    refute_receive {:dispatched, Checkpoint, _}
  end

  test "horizon witness suppresses dispatch", %{identity: identity, config: config} do
    Ash.create!(Checkpoint, checkpoint_inputs(identity, "notifier_operator_slot"),
      action: :upsert,
      authorize?: false
    )

    assert_receive {:dispatched, Checkpoint, :upsert}
    assert :ok = observe_collection([{:create!, 3}], fn -> Horizon.rebind_key_state(config) end)
    assert_receive {:notification_collection, Checkpoint, true}
    refute_receive {:notification_collection, Checkpoint, false}

    assert [%{digest_key_state: state}] =
             Ash.read!(Checkpoint, authorize?: false)
             |> Enum.filter(&(&1.slot_name == "notifier_operator_slot"))

    assert is_binary(state)
    refute_receive {:dispatched, Checkpoint, _}
  end

  test "append suppresses dispatch", %{identity: identity, config: config} do
    control =
      Map.merge(checkpoint_inputs(identity, "notifier_operator_slot"), %{
        commit_lsn: 1,
        ordinal: 0,
        operation: "insert",
        origin: "stream",
        id: "control"
      })

    Ash.create!(Event, control, action: :append, authorize?: false)
    assert_receive {:dispatched, Event, :append}
    config = Map.put(config, :resolver_index, %{{"public", "orders"} => Event})

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "orders",
      record: %{"id" => "append"},
      commit_lsn: 10,
      ordinal: 0
    }

    assert :ok = Apply.apply_change(config, change)
    assert 2 == length(Ash.read!(Event, authorize?: false))
    refute_receive {:dispatched, Event, _}
  end

  test "message route suppresses dispatch", %{config: config} do
    SQL.query!(
      TestRepo,
      "CREATE TABLE notifier_messages (id uuid PRIMARY KEY, content text)"
    )

    Ash.create!(Message, %{content: "control"}, action: :create, authorize?: false)
    assert_receive {:dispatched, Message, :create}

    message = %Replicant.Decoder.Messages.Message{
      prefix: "outbox",
      content: "message",
      lsn: 10,
      ordinal: 0,
      transactional?: false
    }

    assert :ok = Messages.apply(config, message, %{resource: Message, action: :record}, nil)
    assert 2 == length(Ash.read!(Message, authorize?: false))
    refute_receive {:dispatched, Message, _}
  end

  test "snapshot provenance marks suppress dispatch", %{config: config} do
    Ash.create!(Row, %{id: "control"}, authorize?: false)
    assert_receive {:dispatched, Row, :create}
    {:ok, keys} = Provenance.keys()
    attempt = %{attempt: :crypto.strong_rand_bytes(32), keys: keys, key_version: 1}

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "notifier_source",
      record: %{"id" => "seen", "note" => "same"},
      commit_lsn: 10
    }

    assert :ok = Rows.apply_batch!(config, Row, [change], 10, 0, attempt)
    flush_dependencies(Row)

    assert :ok =
             observe_collection([{:bulk_update!, 4}], fn ->
               Rows.apply_batch!(config, Row, [change], 10, 0, attempt)
             end)

    assert_receive {:notification_collection, Row, true}
    assert_receive {:dependency_loaded, Row}

    assert [%{replica_seen_attempt: seen}] =
             Ash.read!(Row, authorize?: false) |> Enum.filter(&(&1.id == "seen"))

    assert seen == attempt.attempt
    refute_receive {:dispatched, Row, _}
  end

  test "snapshot retirement suppresses dispatch", %{config: config} do
    Ash.create!(Version, %{order_id: "retired", amount: "1", valid_from_lsn: 1},
      authorize?: false
    )

    assert_receive {:dispatched, Version, :create}
    flush_dependencies(Version)
    config = Map.put(config, :resolver_index, %{{"public", "snap_versions"} => Version})
    assert :ok = Retirement.retire_unseen!(config, :crypto.strong_rand_bytes(32), 10)
    assert_receive {:dependency_loaded, Version}
    assert [%{valid_to_lsn: 10, is_current: false}] = Ash.read!(Version, authorize?: false)
    refute_receive {:dispatched, Version, _}
  end

  test "mirror insert and delete suppress dispatch", %{config: config} do
    Ash.create!(Mirror, %{id: "mirror-control"}, authorize?: false)
    assert_receive {:dispatched, Mirror, :create}
    config = Map.put(config, :resolver_index, %{{"public", "notifier_source"} => Mirror})

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "notifier_source",
      record: %{"id" => "mirror-applied"}
    }

    assert :ok = Apply.apply_change(config, change)

    assert :ok =
             Apply.apply_change(config, %{
               change
               | op: :delete,
                 old_record: change.record,
                 record: nil
             })

    assert [] = Ash.read!(Mirror, authorize?: false) |> Enum.filter(&(&1.id == "mirror-applied"))
    refute_receive {:dispatched, Mirror, _}
  end

  test "history open and close suppress dispatch", %{config: config} do
    Ash.create!(Version, %{order_id: "history-control", amount: "0", valid_from_lsn: 1},
      authorize?: false
    )

    assert_receive {:dispatched, Version, :create}
    flush_dependencies(Version)
    config = Map.put(config, :resolver_index, %{{"public", "snap_versions"} => Version})

    change = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "snap_versions",
      record: %{"order_id" => "history-applied", "amount" => "1"},
      commit_lsn: 10
    }

    assert :ok =
             observe_collection([{:create!, 3}], fn ->
               Apply.apply_change(config, change)
             end)

    assert_receive {:notification_collection, Version, true}
    refute_receive {:notification_collection, Version, false}
    assert_receive {:dependency_loaded, Version}
    flush_dependencies(Version)

    assert :ok =
             observe_collection([{:bulk_update!, 4}], fn ->
               Apply.apply_change(config, %{
                 change
                 | op: :update,
                   record: %{"order_id" => "history-applied", "amount" => "2"},
                   commit_lsn: 20
               })
             end)

    assert_receive {:notification_collection, Version, true}
    refute_receive {:notification_collection, Version, false}
    assert_receive {:dependency_loaded, Version}

    assert [_, _] =
             Ash.read!(Version, authorize?: false)
             |> Enum.filter(&(&1.order_id == "history-applied"))

    refute_receive {:dispatched, Version, _}
  end

  @tag :no_sandbox
  test "steady-state tombstone clear suppresses dispatch", %{identity: identity} do
    Marquee.drop_slot!("notifier_pipeline_slot")
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = 'notifier_pipeline_slot'")
    Marquee.q!("CREATE TABLE notifier_source (id text PRIMARY KEY, note text)")
    Marquee.q!("CREATE PUBLICATION notifier_tombstone_pub FOR TABLE notifier_source")

    on_exit(fn ->
      AshReplicant.stop_supervised("notifier_pipeline_slot")
      Marquee.drop_slot!("notifier_pipeline_slot")
      Marquee.q!("DROP PUBLICATION IF EXISTS notifier_tombstone_pub")
      Marquee.q!("DROP TABLE IF EXISTS notifier_source")

      Marquee.q!(
        "DELETE FROM ash_replicant_checkpoints WHERE slot_name = 'notifier_pipeline_slot'"
      )

      Status.clear_node_local("notifier_pipeline_slot")
    end)

    checkpoint = fn ->
      Ash.read!(Checkpoint, authorize?: false)
      |> Enum.find(&(&1.slot_name == "notifier_pipeline_slot"))
    end

    start = fn ->
      AshReplicant.start_link(
        sink: MirrorSink,
        connection: Marquee.conn(),
        publication: ["notifier_tombstone_pub"],
        source_identity: Map.to_list(identity),
        go_forward_only: true,
        census: [enabled?: false]
      )
    end

    assert {:ok, _owner} = start.()

    eventually(fn ->
      match?(%{publication_contract: contract} when is_binary(contract), checkpoint.())
    end)

    assert :ok = AshReplicant.stop_supervised("notifier_pipeline_slot")

    assert %{terminal_cause: "operator_stopped", terminal_class: "stopped"} =
             bound = checkpoint.()

    assert %DateTime{} = bound.terminal_at

    assert :ok =
             observe_collection([{:create!, 3}], fn ->
               assert {:ok, _successor} = start.()

               eventually(fn ->
                 match?(
                   %{terminal_cause: nil, terminal_class: nil, terminal_at: nil},
                   checkpoint.()
                 )
               end)

               :ok
             end)

    assert_receive {:notification_collection, Checkpoint, true}
    refute_receive {:notification_collection, Checkpoint, false}
    refute_receive {:dispatched, Checkpoint, _}
    rebound = checkpoint.()
    assert rebound.publication_contract == bound.publication_contract
    assert rebound.publication_fingerprint == bound.publication_fingerprint
    assert rebound.source_timeline == bound.source_timeline
    assert rebound.commit_lsn == bound.commit_lsn
  end

  @tag :no_sandbox
  test "live snapshot and checkpoint writes suppress dispatch", %{identity: identity} do
    Marquee.q!("CREATE TABLE notifier_source (id text PRIMARY KEY, note text)")
    Marquee.q!("CREATE PUBLICATION notifier_dispatch_pub FOR TABLE notifier_source")
    Marquee.q!("INSERT INTO notifier_source VALUES ('notifier-snapshot', 'snapshot')")

    on_exit(fn ->
      AshReplicant.stop_supervised("notifier_pipeline_slot")
      Marquee.drop_slot!("notifier_pipeline_slot")
      Marquee.q!("DROP PUBLICATION IF EXISTS notifier_dispatch_pub")
      Marquee.q!("DROP TABLE IF EXISTS notifier_source")

      Marquee.q!(
        "DELETE FROM snap_orders WHERE id IN ('notifier-snapshot', 'notifier-stream', 'notifier-control')"
      )

      Marquee.q!(
        "DELETE FROM ash_replicant_checkpoints WHERE slot_name = 'notifier_pipeline_slot'"
      )

      Status.clear_node_local("notifier_pipeline_slot")
    end)

    Ash.create!(Mirror, %{id: "notifier-control"}, authorize?: false)
    assert_receive {:dispatched, Mirror, :create}

    assert :ok =
             observe_collection([{:create!, 3}, {:bulk_create, 4}], fn ->
               assert {:ok, _owner} =
                        AshReplicant.start_link(
                          sink: MirrorSink,
                          connection: Marquee.conn(),
                          publication: ["notifier_dispatch_pub"],
                          source_identity: Map.to_list(identity),
                          snapshot: true
                        )

               eventually(fn ->
                 match?({:ok, %Mirror{}}, Ash.get(Mirror, "notifier-snapshot", authorize?: false))
               end)

               assert_receive {:dependency_loaded, Mirror}
               Marquee.q!("INSERT INTO notifier_source VALUES ('notifier-stream', 'stream')")

               eventually(fn ->
                 match?({:ok, %Mirror{}}, Ash.get(Mirror, "notifier-stream", authorize?: false))
               end)

               refute_receive {:dispatched, Mirror, _}
               refute_receive {:dispatched, Checkpoint, _}
               assert :ok = AshReplicant.stop_supervised("notifier_pipeline_slot")
             end)

    assert_receive {:notification_collection, Checkpoint, true}
    refute_receive {:notification_collection, Checkpoint, false}
    assert_receive {:notification_collection, Mirror, true}
    refute_receive {:notification_collection, Mirror, false}
  end

  defp eventually(predicate) do
    assert Enum.reduce_while(1..300, false, fn _, _ ->
             if predicate.() do
               {:halt, true}
             else
               Process.sleep(50)
               {:cont, false}
             end
           end)
  end

  defp flush_dependencies(resource) do
    receive do
      {:dependency_loaded, ^resource} -> flush_dependencies(resource)
    after
      0 -> :ok
    end
  end

  # Observe the real Ash calls without replacing their bodies or destinations.
  # An enclosing Repo transaction can defer dispatch, and return_records?
  # can preserve a bulk pre-load. Check collection as well as row effects.
  defp observe_collection(functions, fun) do
    observer = self()
    tracer = spawn_link(fn -> forward_collection_option(observer) end)

    for {function, arity} <- functions do
      :erlang.trace_pattern({Ash, function, arity}, true, [:local])
    end

    :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, tracer}])
    # Replicant starts delivery workers through its existing supervisor.
    :erlang.trace(:new, true, [:call, :set_on_spawn, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(:new, false, [:call, :set_on_spawn])
      :erlang.trace(self(), false, [:call, :set_on_spawn])
      reference = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^reference} -> :ok
      end

      for {function, arity} <- functions do
        :erlang.trace_pattern({Ash, function, arity}, false, [:local])
      end

      send(tracer, {:stop, self()})

      receive do
        :collection_trace_stopped -> :ok
      end
    end
  end

  defp forward_collection_option(observer) do
    receive do
      {:trace, _, :call, {Ash, function, arguments}} ->
        input = if function == :bulk_create, do: Enum.at(arguments, 1), else: hd(arguments)

        resource =
          case input do
            %Ash.Query{resource: resource} -> resource
            %{__struct__: resource} -> resource
            resource -> resource
          end

        options = List.last(arguments)

        send(
          observer,
          {:notification_collection, resource,
           Keyword.get(options, :return_notifications?, false)}
        )

        forward_collection_option(observer)

      {:stop, caller} ->
        send(caller, :collection_trace_stopped)
    end
  end
end
