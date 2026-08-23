defmodule AshReplicant.Test.Messages do
  @moduledoc """
  C1 fixtures: logical-message route targets and their sinks.

  The outbox resources follow the closed message-route profile (ADR-0015):
  a `:create` action carrying the private `operation_key` / `content_digest`
  arguments plus an accepted `content` attribute, protected by an
  idempotency claim whose fingerprint is exactly the content digest. The
  peer variant declares an `external_effect`; the malformed variants pin
  the admission rejections.
  """

  alias AshReplicant.TestRepo
  alias Ecto.Adapters.SQL

  @outbox "repl_message_outbox"
  @peer "repl_peer_outbox"
  @reject "repl_reject_outbox"

  def outbox, do: @outbox
  def peer, do: @peer
  def reject, do: @reject

  def peer_mode_key, do: {__MODULE__, :peer_mode}
  def peer_recover_mode_key, do: {__MODULE__, :peer_recover_mode}
  def peer_calls_key, do: {__MODULE__, :peer_calls}
  def observer_key, do: {__MODULE__, :observer}

  @doc "Create (or reset) the outbox tables. Raw SQL, like the marquee fixtures."
  def setup_schema! do
    for table <- [@outbox, @peer, @reject, "repl_transient_outbox"] do
      q!("DROP TABLE IF EXISTS #{table}")
      q!("CREATE TABLE #{table} (id uuid primary key, content text)")
    end

    :ok
  end

  def teardown_schema! do
    for table <- [@outbox, @peer, @reject, "repl_transient_outbox"] do
      q!("DROP TABLE IF EXISTS #{table}")
    end

    :ok
  end

  def rows(table), do: q!("SELECT content FROM #{table} ORDER BY content").rows

  def q!(sql, params \\ []), do: SQL.query!(TestRepo, sql, params)

  @doc """
  Install message digest keys, restoring whatever was there before on exit
  (delete when previously unset — config-env hygiene).
  """
  def put_digest_keys!(keys) do
    previous = Application.get_env(:ash_replicant, :message_digest_keys, :unset)

    Application.put_env(:ash_replicant, :message_digest_keys, keys)

    on_exit = fn ->
      case previous do
        :unset -> Application.delete_env(:ash_replicant, :message_digest_keys)
        value -> Application.put_env(:ash_replicant, :message_digest_keys, value)
      end
    end

    {keys, on_exit}
  end

  def with_digest_keys!(keys, fun) do
    {_keys, restore} = put_digest_keys!(keys)

    try do
      fun.()
    after
      restore.()
    end
  end

  def peer_mode!(mode) do
    :persistent_term.put(peer_mode_key(), mode)
    :persistent_term.put(peer_recover_mode_key(), mode)
    mode
  end

  def reset_peer! do
    :persistent_term.put(peer_mode_key(), :ok)
    :persistent_term.put(peer_recover_mode_key(), :ok)
    :persistent_term.put(peer_calls_key(), [])
    :ok
  end

  def peer_calls do
    :persistent_term.get(peer_calls_key(), [])
  end

  defmodule StoreResponse do
    @moduledoc false
    @behaviour AshOnetime.ResponseClassifier
    @behaviour AshReplicant.DestinationParticipant

    @impl AshOnetime.ResponseClassifier
    def classify(result, _context), do: {:store, result}

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %AshReplicant.DestinationParticipant.Context{}),
      do: {:ok, :no_database}
  end

  # The external peer: a pure process-side effect (no destination-repo write —
  # that is the point of the class), with its three-state outcome driven by a
  # persistent_term mode the test controls and every call recorded for asserts.
  defmodule PeerEffect do
    @moduledoc false
    @behaviour AshOnetime.ExternalEffect

    alias AshReplicant.Test.Messages

    @impl AshOnetime.ExternalEffect
    def execute(_operation_key, _subject, _context) do
      record(:execute)

      case :persistent_term.get(Messages.peer_mode_key(), :ok) do
        :ok -> {:ok, %{peer_id: "peer-" <> Integer.to_string(record_count())}}
        :unknown -> {:error, :outcome_unknown}
      end
    end

    @impl AshOnetime.ExternalEffect
    def recover(_operation_key, _subject, _context) do
      record(:recover)

      case :persistent_term.get(Messages.peer_recover_mode_key(), :ok) do
        :ok -> {:ok, %{peer_id: "peer-" <> Integer.to_string(record_count())}}
        :absent -> :absent
        :unknown -> :unknown
      end
    end

    defp record(kind) do
      calls = :persistent_term.get(Messages.peer_calls_key(), [])
      :persistent_term.put(Messages.peer_calls_key(), calls ++ [kind])
    end

    defp record_count,
      do: :persistent_term.get(Messages.peer_calls_key(), []) |> length()
  end

  defmodule Outbox do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Messages.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "repl_message_outbox"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :content, :string, public?: true
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        accept [:content]
        argument :operation_key, :string, allow_nil?: false, public?: false
        argument :content_digest, :string, allow_nil?: false, public?: false
      end
    end

    onetime do
      protect :record do
        strategy :idempotency

        scope([
          {:static, "ash_replicant:message-route:1"},
          {:static, Atom.to_string(__MODULE__)}
        ])

        key({:argument, :operation_key})
        fingerprint(arguments: [:content_digest])

        response(AshOnetime.Codec.Resource,
          fields: [:id],
          classify: AshReplicant.Test.Messages.StoreResponse
        )

        retention({1, :day})
      end
    end
  end

  defmodule PeerOutbox do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Messages.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "repl_peer_outbox"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :content, :string, public?: true
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        accept [:content]
        argument :operation_key, :string, allow_nil?: false, public?: false
        argument :content_digest, :string, allow_nil?: false, public?: false
      end
    end

    onetime do
      protect :record do
        strategy :idempotency
        external_effect(AshReplicant.Test.Messages.PeerEffect)

        scope([
          {:static, "ash_replicant:message-route:1"},
          {:static, Atom.to_string(__MODULE__)}
        ])

        key({:argument, :operation_key})
        fingerprint(arguments: [:content_digest])

        response(AshOnetime.Codec.JSON,
          classify: AshReplicant.Test.Messages.StoreResponse
        )

        retention({1, :day})
      end
    end
  end

  # --- malformed route targets: each pins one admission rejection ---

  defmodule NonceProofVerifier do
    @moduledoc false
    @behaviour AshOnetime.Verifier
    @behaviour AshReplicant.DestinationParticipant

    @impl AshOnetime.Verifier
    def verify(_token, _context), do: {:error, :unverified}

    @impl AshOnetime.Verifier
    def algorithm, do: :hmac_sha256

    @impl AshOnetime.Verifier
    def trust_model, do: :same_service

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, %AshReplicant.DestinationParticipant.Context{}),
      do: {:ok, :no_database}
  end

  defmodule NonceOutbox do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Messages.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "repl_reject_outbox"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :content, :string, public?: true
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        accept [:content]
        argument :proof, :string, allow_nil?: false, public?: false
      end
    end

    onetime do
      protect :record do
        strategy :one_time_nonce

        scope([
          {:static, "ash_replicant:message-route:1"},
          {:static, Atom.to_string(__MODULE__)}
        ])

        key({:verified, :proof, AshReplicant.Test.Messages.NonceProofVerifier})
        window(max_age: {5, :minute}, clock_skew: {1, :minute})
      end
    end
  end

  defmodule UnprotectedOutbox do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Messages.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "repl_reject_outbox"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :content, :string, public?: true
    end

    actions do
      defaults [:read]

      create :record do
        accept [:content]
        argument :operation_key, :string, allow_nil?: false, public?: false
        argument :content_digest, :string, allow_nil?: false, public?: false
      end
    end
  end

  defmodule BadFingerprintOutbox do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Messages.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "repl_reject_outbox"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :content, :string, public?: true
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        accept [:content]
        argument :operation_key, :string, allow_nil?: false, public?: false
        argument :content_digest, :string, allow_nil?: false, public?: false
      end
    end

    onetime do
      protect :record do
        strategy :idempotency

        scope([
          {:static, "ash_replicant:message-route:1"},
          {:static, Atom.to_string(__MODULE__)}
        ])

        key({:argument, :operation_key})
        fingerprint(arguments: [:operation_key])

        response(AshOnetime.Codec.Resource,
          fields: [:id],
          classify: AshReplicant.Test.Messages.StoreResponse
        )

        retention({1, :day})
      end
    end
  end

  # The retention probe: identical to Outbox but its claim protection lasts
  # one second — a re-delivery past retention re-executes by package design
  # (the operator sizes retention against the crash/restart window).
  defmodule TransientOutbox do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.Test.Messages.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "repl_transient_outbox"
      repo AshReplicant.TestRepo
    end

    attributes do
      uuid_primary_key :id
      attribute :content, :string, public?: true
    end

    actions do
      defaults [:read]

      create :record do
        transaction? true
        accept [:content]
        argument :operation_key, :string, allow_nil?: false, public?: false
        argument :content_digest, :string, allow_nil?: false, public?: false
      end
    end

    onetime do
      protect :record do
        strategy :idempotency

        scope([
          {:static, "ash_replicant:message-route:1"},
          {:static, Atom.to_string(__MODULE__)}
        ])

        key({:argument, :operation_key})
        fingerprint(arguments: [:content_digest])

        response(AshOnetime.Codec.Resource,
          fields: [:id],
          classify: AshReplicant.Test.Messages.StoreResponse
        )

        retention({1, :second})
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.Test.Messages.Outbox
      resource AshReplicant.Test.Messages.PeerOutbox
      resource AshReplicant.Test.Messages.NonceOutbox
      resource AshReplicant.Test.Messages.UnprotectedOutbox
      resource AshReplicant.Test.Messages.TransientOutbox
      resource AshReplicant.Test.Messages.BadFingerprintOutbox
      resource AshReplicant.Test.Checkpoint
    end
  end

  defmodule Sink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Messages.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "message_actions_slot",
      message_routes: [
        {"outbox", AshReplicant.Test.Messages.Outbox, :record},
        {"peer", AshReplicant.Test.Messages.PeerOutbox, :record},
        {"transient", AshReplicant.Test.Messages.TransientOutbox, :record}
      ],
      ignored_message_prefixes: ["noise"],
      recovery_horizon: {1, :second}
  end

  defmodule MarqueeSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Marquee.Domain, AshReplicant.Test.Messages.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "message_marquee_slot",
      message_routes: [
        {"outbox", AshReplicant.Test.Messages.Outbox, :record},
        {"peer", AshReplicant.Test.Messages.PeerOutbox, :record},
        {"transient", AshReplicant.Test.Messages.TransientOutbox, :record}
      ],
      ignored_message_prefixes: ["noise"],
      recovery_horizon: {1, :second}
  end
end
