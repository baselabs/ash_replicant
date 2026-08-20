defmodule AshReplicant.SnapshotMarkSeenTest do
  @moduledoc """
  S01 runtime tier for `AshReplicant.Snapshot.MarkSeen` (ADR-0017): the only
  write path to the two protected provenance attributes.

  The compile-time verifier proves no ACTION can accept them
  (`AshReplicant.ValidateSnapshotProvenanceTest`); these prove the change
  actually stamps them from the sink-supplied context, that a caller cannot
  reach them as input at runtime either, and that an absent or malformed
  context fails the changeset CLOSED rather than silently marking nothing —
  a silent no-op would let completion retire a row the attempt had just seen.

  Runs on ETS: no DB, no server.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Error
  alias AshReplicant.Snapshot.MarkSeen

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Mirror do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.SnapshotMarkSeenTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReplicant.Resource]

    replicant do
      source_table("orders")
      snapshot_provenance(true)
    end

    attributes do
      uuid_primary_key :id
      attribute :note, :string, public?: true
      attribute :replica_fingerprint, :binary, public?: false, writable?: false
      attribute :replica_seen_attempt, :binary, public?: false, writable?: false
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

  # A distinctive sentinel, so the value-free assertion below probes for a real
  # row value rather than a substring that happens to occur in the error text.
  @row_value "sentinel-row-value-4111111111111111"

  setup do
    {:ok, record} = Ash.create(Mirror, %{note: @row_value}, action: :create, authorize?: false)
    %{record: record}
  end

  defp mark(record, provenance) do
    Ash.update(record, %{},
      action: :replicant_mark_seen,
      authorize?: false,
      context: %{MarkSeen.context_key() => provenance}
    )
  end

  describe "stamping from the sink-supplied context" do
    test "stamps both protected attributes", %{record: record} do
      assert {:ok, marked} = mark(record, %{attempt: "attempt-1", fingerprint: "e1v1:abc"})
      assert marked.replica_seen_attempt == "attempt-1"
      assert marked.replica_fingerprint == "e1v1:abc"
    end

    test "an attempt WITHOUT a fingerprint stamps membership only, leaving the stored fingerprint",
         %{record: record} do
      {:ok, first} = mark(record, %{attempt: "attempt-1", fingerprint: "e1v1:abc"})

      assert {:ok, second} = mark(first, %{attempt: "attempt-2"})
      assert second.replica_seen_attempt == "attempt-2"
      assert second.replica_fingerprint == "e1v1:abc"
    end

    test "ROTATION: re-stamping an unchanged row under a new key replaces the fingerprint",
         %{record: record} do
      {:ok, first} = mark(record, %{attempt: "attempt-1", fingerprint: "e1v1:old"})
      assert {:ok, second} = mark(first, %{attempt: "attempt-1", fingerprint: "e1v2:new"})
      assert second.replica_fingerprint == "e1v2:new"
    end
  end

  describe "fails closed rather than silently marking nothing" do
    test "an ABSENT provenance context fails the changeset closed", %{record: record} do
      assert {:error, error} =
               Ash.update(record, %{}, action: :replicant_mark_seen, authorize?: false)

      assert provenance_failure?(error)
    end

    test "a malformed attempt fails closed", %{record: record} do
      for provenance <- [
            %{attempt: nil},
            %{attempt: ""},
            %{attempt: :not_a_binary},
            %{fingerprint: "e1v1:abc"},
            %{},
            :not_a_map
          ] do
        assert {:error, error} = mark(record, provenance),
               "expected #{inspect(provenance)} to fail closed"

        assert provenance_failure?(error)
      end
    end

    test "an attempt with a MALFORMED fingerprint fails closed, never stamps membership alone",
         %{record: record} do
      for bad <- [nil, "", :not_a_binary] do
        assert {:error, error} = mark(record, %{attempt: "attempt-1", fingerprint: bad}),
               "expected fingerprint #{inspect(bad)} to fail closed"

        assert provenance_failure?(error)
      end

      # And the row is untouched — a failed mark leaves no partial membership.
      reloaded = Ash.get!(Mirror, record.id, authorize?: false)
      assert reloaded.replica_seen_attempt == nil
    end

    test "the failure is value-free: a structural reason and op, no row value", %{record: record} do
      {:error, error} = mark(record, %{attempt: ""})
      %Error{} = replicant_error = find_replicant_error(error)

      assert replicant_error.reason == :config_invalid
      assert replicant_error.op == :snapshot_mark
      assert Exception.message(replicant_error) =~ "reason=:config_invalid"

      rendered = Exception.message(replicant_error) <> inspect(replicant_error)
      refute rendered =~ @row_value
      refute rendered =~ record.id
    end
  end

  describe "the protected attributes are not reachable as action input" do
    test "the mark action rejects them as params (accept [])", %{record: record} do
      assert_raise Ash.Error.Invalid, fn ->
        Ash.update!(record, %{replica_seen_attempt: "forged"},
          action: :replicant_mark_seen,
          authorize?: false,
          context: %{MarkSeen.context_key() => %{attempt: "attempt-1"}}
        )
      end
    end

    test "the host's own `accept :*` create cannot set them", %{record: _record} do
      assert_raise Ash.Error.Invalid, fn ->
        Ash.create!(Mirror, %{note: "n", replica_fingerprint: "forged"},
          action: :create,
          authorize?: false
        )
      end
    end

    test "the host's own `accept :*` update cannot set them", %{record: record} do
      assert_raise Ash.Error.Invalid, fn ->
        Ash.update!(record, %{replica_seen_attempt: "forged"}, action: :update, authorize?: false)
      end
    end
  end

  describe "the declared contract surface" do
    test "protected_attributes/0 names exactly the two ADR-0017 attributes" do
      assert MarkSeen.protected_attributes() == [:replica_fingerprint, :replica_seen_attempt]
    end
  end

  defp provenance_failure?(error), do: not is_nil(find_replicant_error(error))

  defp find_replicant_error(%Error{} = error), do: error

  defp find_replicant_error(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &find_replicant_error/1)

  defp find_replicant_error(_other), do: nil
end
