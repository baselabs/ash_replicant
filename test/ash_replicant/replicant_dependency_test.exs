defmodule AshReplicant.ReplicantDependencyTest do
  use ExUnit.Case, async: true

  test "the resolved Hex dependency exposes the coordinated major contract" do
    assert Code.ensure_loaded?(Replicant.SessionIdentity)
    assert function_exported?(Replicant.Sink, :accept_session_identity, 3)
    assert function_exported?(Replicant.Sink, :supports_batch?, 1)
    assert function_exported?(Replicant.Sink, :supports_messages?, 1)
    assert function_exported?(Replicant.Sink, :supports_incremental_snapshot?, 1)

    version = Application.spec(:replicant, :vsn) |> List.to_string()
    assert Version.match?(version, ">= 1.0.0 and < 2.0.0-0")
  end
end
