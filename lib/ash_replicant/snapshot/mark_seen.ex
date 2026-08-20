defmodule AshReplicant.Snapshot.MarkSeen do
  @moduledoc """
  The package-owned change that stamps snapshot provenance onto a row (S01,
  ADR-0017).

  This is the ONLY write path to `replica_fingerprint` and
  `replica_seen_attempt`. Both attributes are `public?: false` and
  `writable?: false`, and
  `AshReplicant.Resource.Verifiers.ValidateSnapshotProvenance` rejects any
  action that would accept them as input or declare an argument named for
  them — so a host caller cannot forge provenance. The values reach this
  change through the sink-supplied **changeset context**, the same channel the
  operation identity already rides on, and land via
  `Ash.Changeset.force_change_attribute/3` (documented in Ash as *"Changes an
  attribute even if it isn't writable"*).

  Declare it on the host's private mark action:

      update :replicant_mark_seen do
        public? false
        accept []
        require_atomic? false
        change AshReplicant.Snapshot.MarkSeen
      end

  `require_atomic? false` is required: the stamped values come from the
  changeset context at runtime, so the change is not expressible as an atomic
  update.

  ## Context shape

      %{ash_replicant_snapshot_provenance: %{attempt: binary(), fingerprint: binary()}}

  `:attempt` is mandatory — a mark that stamps no membership is exactly the
  silent failure the contract exists to prevent, since the completion scan
  would then retire a row it had just seen. `:fingerprint` is optional: an
  unchanged row already carries a valid one, but supplying it lets a
  rotation-window sweep re-stamp the row under the active key so the retained
  key can eventually be dropped.

  A missing or malformed context fails the changeset closed with a value-free
  `AshReplicant.Error` (`reason: :config_invalid`). It never silently no-ops.
  """

  use Ash.Resource.Change

  alias AshReplicant.Error

  @context_key :ash_replicant_snapshot_provenance
  @attempt_attribute :replica_seen_attempt
  @fingerprint_attribute :replica_fingerprint

  @doc "The changeset-context key the sink supplies provenance under."
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @doc "The two protected attribute names, in the order the contract names them."
  @spec protected_attributes() :: [atom()]
  def protected_attributes, do: [@fingerprint_attribute, @attempt_attribute]

  @impl true
  def change(changeset, _opts, _context) do
    case Map.get(changeset.context || %{}, @context_key) do
      %{attempt: attempt} = provenance when is_binary(attempt) and byte_size(attempt) > 0 ->
        changeset
        |> Ash.Changeset.force_change_attribute(@attempt_attribute, attempt)
        |> stamp_fingerprint(provenance)

      _absent_or_malformed ->
        fail_closed(changeset)
    end
  end

  defp stamp_fingerprint(changeset, %{fingerprint: fingerprint})
       when is_binary(fingerprint) and byte_size(fingerprint) > 0 do
    Ash.Changeset.force_change_attribute(changeset, @fingerprint_attribute, fingerprint)
  end

  # A key present but unusable is a caller bug, not an omission: fail closed
  # rather than stamp membership against a stale fingerprint.
  defp stamp_fingerprint(changeset, provenance) when is_map_key(provenance, :fingerprint) do
    fail_closed(changeset)
  end

  defp stamp_fingerprint(changeset, _no_fingerprint), do: changeset

  defp fail_closed(changeset) do
    Ash.Changeset.add_error(
      changeset,
      Error.exception(
        reason: :config_invalid,
        resource: changeset.resource,
        op: :snapshot_mark
      )
    )
  end
end
