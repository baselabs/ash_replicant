defmodule AshReplicant.MessagesTest do
  @moduledoc """
  C1 unit tier: the versioned host-keyed digest, prefix routing, and the
  message operation-identity shape. Pure (no DB).
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Apply.Context
  alias AshReplicant.Messages
  alias AshReplicant.Test.Messages, as: Fixtures

  @keys [{2, "second-version-digest-key"}, {1, "first-version-digest!!"}]

  describe "digest_keys/0" do
    test "accepts a non-empty list of unique positive versions with adequately sized binary keys" do
      assert {:ok, keys} = Messages.digest_keys()
      assert keys == Enum.sort(keys)
    end

    test "rejects the malformed shapes fail-closed" do
      for bad <- [
            nil,
            [],
            [{0, "zero-version-key-16bytes"}],
            [{1, "short"}],
            [{1, :not_a_binary}],
            [{1, "valid-key-sixteen-bytes!!"}, {1, "duplicate-version-key!!"}],
            ["not-a-tuple"],
            [{:one, :two}]
          ] do
        Fixtures.with_digest_keys!(bad, fn ->
          assert :error = Messages.digest_keys(),
                 "expected #{inspect(bad)} to be rejected"
        end)
      end
    end
  end

  describe "digest/3" do
    test "is deterministic per (version, key, content) and differs across all three" do
      assert {:ok, d1a} = Messages.digest("payload", 1, @keys)
      assert {:ok, d1b} = Messages.digest("payload", 1, @keys)
      assert d1a == d1b
      assert String.starts_with?(d1a, "v1:")

      assert {:ok, d2} = Messages.digest("payload", 2, @keys)
      assert String.starts_with?(d2, "v2:")
      refute d1a == d2

      assert {:ok, other} = Messages.digest("other payload", 1, @keys)
      refute d1a == other
    end

    test "is HMAC-shaped (keyed), never a bare digest of the content" do
      {:ok, digest} = Messages.digest("payload", 1, @keys)
      bare = Base.encode16(:crypto.hash(:sha256, "payload"), case: :lower)
      refute digest =~ bare
      assert byte_size(digest) >= 3 + 64
    end

    test "an unknown version and malformed keys are rejected" do
      assert :error = Messages.digest("payload", 3, @keys)
      assert :error = Messages.digest("payload", 1, [])
      assert :error = Messages.digest("payload", :bad, @keys)
    end
  end

  describe "digest_order/1" do
    test "mints under the active (highest) version first, retained versions descending" do
      assert {:ok, [active | retained]} = Messages.digest_order(@keys)
      assert active == 2
      assert retained == [1]
    end
  end

  describe "resolve_route/2" do
    @config %{
      message_routes: [
        {"outbox", Fixtures.Outbox, :record},
        {"peer", Fixtures.PeerOutbox, :record}
      ],
      ignored_message_prefixes: ["noise"]
    }

    test "resolves a routed prefix to its resource and action" do
      assert {:ok, %{resource: Fixtures.Outbox, action: :record}} =
               Messages.resolve_route(@config, "outbox")

      assert {:ok, %{resource: Fixtures.PeerOutbox, action: :record}} =
               Messages.resolve_route(@config, "peer")
    end

    test "an explicitly ignored prefix is :ignored, an unknown prefix is :unmapped" do
      assert :ignored = Messages.resolve_route(@config, "noise")
      assert {:error, :unmapped} = Messages.resolve_route(@config, "evil")
      assert {:error, :unmapped} = Messages.resolve_route(@config, "outbo")
    end

    test "an absent routing surface resolves everything to :unmapped (fail-closed default)" do
      assert {:error, :unmapped} = Messages.resolve_route(%{}, "outbox")
    end
  end

  describe "operation identity (freeze-row style)" do
    test "a transactional message mints the :message invocation under the txn commit LSN and its own ordinal" do
      config = %{
        source_identity: %{system_identifier: "system", database: "source"},
        slot_name: "freeze_slot"
      }

      message = %Replicant.Decoder.Messages.Message{
        transactional?: true,
        lsn: 90,
        prefix: "outbox",
        content: "m",
        ordinal: 1
      }

      assert {:ok, operation} = Messages.operation_context(config, message, 100)

      assert operation == %{
               source_system_identifier: "system",
               source_database: "source",
               slot_name: "freeze_slot",
               commit_lsn: 100,
               ordinal: 1,
               invocation: :message
             }

      assert {:ok, key} =
               AshReplicant.DestinationParticipant.operation_key(
                 operation,
                 Fixtures.Outbox
               )

      assert is_binary(key)

      # Distinct from a change at the same LSN: the ordinal space is shared,
      # so a change and a message can never mint the same key.
      change = %Replicant.Change{commit_lsn: 100, ordinal: 0}

      {:ok, change_operation} = Context.operation_context(config, change, :upsert)

      assert {:ok, change_key} =
               AshReplicant.DestinationParticipant.operation_key(change_operation, Fixtures.Outbox)

      refute key == change_key
    end

    test "a standalone message mints under its OWN LSN with ordinal 0" do
      config = %{
        source_identity: %{system_identifier: "system", database: "source"},
        slot_name: "freeze_slot"
      }

      message = %Replicant.Decoder.Messages.Message{
        transactional?: false,
        lsn: 555,
        prefix: "outbox",
        content: "m"
      }

      assert {:ok, operation} = Messages.operation_context(config, message, nil)
      assert operation.commit_lsn == 555
      assert operation.ordinal == 0
      assert operation.invocation == :message
    end
  end
end
