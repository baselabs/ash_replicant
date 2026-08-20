defmodule AshReplicant.Test.Provenance do
  @moduledoc """
  S01 fixtures: snapshot-provenance key installation for rotation and
  key-loss tests (ADR-0017).

  Mirrors the C1 `AshReplicant.Test.Messages` digest-key helpers — the two
  keyed surfaces share one convention, so a change to key hygiene lands in
  both places by symmetry rather than by memory.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Install snapshot-provenance keys, restoring whatever was there before on
  exit. A previously UNSET value is restored by DELETING the key, never by
  writing back a placeholder.
  """
  def put_provenance_keys!(keys) do
    previous = Application.get_env(:ash_replicant, :snapshot_provenance_keys, :unset)

    Application.put_env(:ash_replicant, :snapshot_provenance_keys, keys)

    on_exit = fn ->
      case previous do
        :unset -> Application.delete_env(:ash_replicant, :snapshot_provenance_keys)
        value -> Application.put_env(:ash_replicant, :snapshot_provenance_keys, value)
      end
    end

    on_exit(on_exit)

    {keys, on_exit}
  end

  @doc "Run `fun` with `keys` installed, restoring the previous value afterwards."
  def with_provenance_keys!(keys, fun) do
    {_keys, restore} = put_provenance_keys!(keys)

    try do
      fun.()
    after
      restore.()
    end
  end
end
