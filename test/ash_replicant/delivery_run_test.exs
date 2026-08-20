defmodule AshReplicant.DeliveryRunTest do
  @moduledoc """
  The V1 delivery-run id (S02, ADR-0017): one 256-bit random id per
  `AshReplicant.PipelineOwner` activation, carried on the admitted generation
  and into every runtime config the sink delivers under.

  It is the axis that makes an operator-authorized snapshot retry under a LATER
  owner rotate the attempt even when PostgreSQL hands back the same consistent
  point — so it must be minted per ACTIVATION, never derived from the slot, the
  sink, or the LSN.
  """
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Destination.Generation
  alias AshReplicant.Snapshot.State
  alias AshReplicant.Test.AdmittedGeneration

  defmodule Sink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "delivery_run_slot"
  end

  setup do
    on_exit(fn -> :persistent_term.erase({AshReplicant, "delivery_run_slot"}) end)
    :ok
  end

  test "the generation carries a 256-bit delivery run" do
    generation = AdmittedGeneration.put!(Sink)

    assert %Generation{delivery_run: run} = generation
    assert is_binary(run)
    assert byte_size(run) == State.id_bytes()
  end

  test "a second activation of the SAME sink and slot mints a DIFFERENT run" do
    first = AdmittedGeneration.put!(Sink)
    second = AdmittedGeneration.put!(Sink)

    refute first.delivery_run == second.delivery_run
  end

  test "the runtime config carries the run plus the identities the attempt binds to" do
    generation = AdmittedGeneration.put!(Sink)

    config =
      AshReplicant.runtime_config(generation)

    assert config.delivery_run == generation.delivery_run
    assert config.code_fingerprint == generation.code_fingerprint
    assert config.sink_config_digest == generation.sink_config_digest

    # All four admitted identities are present, so the attempt's contract digest
    # resolves rather than failing closed.
    assert {:ok, digest} = State.contract_digest(config)
    assert byte_size(digest) == 32
  end

  test "a config whose delivery run diverges from the live generation fails the guard" do
    generation = AdmittedGeneration.put!(Sink)
    config = AshReplicant.runtime_config(generation)

    assert :ok = AshReplicant.guard_generation(config)

    forged = %{config | delivery_run: :crypto.strong_rand_bytes(State.id_bytes())}

    assert {:error, %AshReplicant.Error{}} = AshReplicant.guard_generation(forged)
  end
end
