defmodule AshReplicant.StatusTest do
  @moduledoc """
  O02 (issue #12): the one state model's DERIVATION — precedence, the public
  five-state collapse, the cause classification table, the tombstone
  encoding, and the value-free closed sets. Database-free: the durable
  tombstone leg needs a running repo and is covered by the integration
  suite; here the node-local leg and the pure functions are the surface.

  A stub GenServer owner stands in for `AshReplicant.PipelineOwner`'s
  `:status` facts so every live-evidence branch is deterministic.
  """

  use ExUnit.Case, async: false

  alias AshReplicant.Status
  alias AshReplicant.Test.AdmittedGeneration

  defmodule StatusSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "status_slot"
  end

  # A minimal owner answering the derivation's `:status` call with fixed
  # facts — the internal contract PipelineOwner will implement.
  defmodule FactsOwner do
    @moduledoc false
    use GenServer

    def start(facts), do: GenServer.start(__MODULE__, facts)

    @impl GenServer
    def init(facts), do: {:ok, facts}

    @impl GenServer
    def handle_call(:ash_replicant_status, _from, facts), do: {:reply, facts, facts}
  end

  @slot "status_slot"
  @entry {AshReplicant, @slot}
  @tombstone_key {AshReplicant.Status, @slot}

  setup do
    :persistent_term.erase(@entry)
    :persistent_term.erase(@tombstone_key)

    on_exit(fn ->
      :persistent_term.erase(@entry)
      :persistent_term.erase(@tombstone_key)
    end)

    :ok
  end

  defp put_tombstone(cause, class) do
    :persistent_term.put(@tombstone_key, %Status.Tombstone{
      cause: cause,
      class: class,
      at: DateTime.utc_now()
    })
  end

  defp derive(extra \\ []) do
    Status.derive(StatusSink, Keyword.get(extra, :timeout, 50))
  end

  describe "precedence — an invalid sink is misconfigured before anything else" do
    test "a non-sink module reports misconfigured with the closed reason" do
      assert {:misconfigured, :sink_required} = AshReplicant.status(:not_a_sink)

      assert %{status: {:misconfigured, :sink_required}, lifecycle: :absent} =
               Status.derive(:not_a_sink)
    end
  end

  describe "precedence — no evidence is not started" do
    test "no entry and no tombstone" do
      assert :not_started = AshReplicant.status(StatusSink)
      assert %{status: :not_started, lifecycle: :absent} = derive()
    end
  end

  describe "precedence — a node-local tombstone is the answer once nothing is live" do
    test "a halt-class cause reports halted with that cause" do
      put_tombstone(:census_unverifiable, :halt)

      assert {:halted, :census_unverifiable} = AshReplicant.status(StatusSink)
      assert %{status: {:halted, :census_unverifiable}, lifecycle: :halted} = derive()
    end

    test "an operator stop reports not started publicly and stopped in the model" do
      put_tombstone(:operator_stopped, :stopped)

      assert :not_started = AshReplicant.status(StatusSink)
      assert %{status: :not_started, lifecycle: :stopped} = derive()
    end

    test "a misconfigured-class cause reports misconfigured" do
      put_tombstone(:publication_contract_incompatible, :misconfigured)

      assert {:misconfigured, :publication_contract_incompatible} =
               AshReplicant.status(StatusSink)
    end

    test "an unknown persisted cause decodes to the closed fallback" do
      put_tombstone(:tombstone_unknown, :halt)

      assert {:halted, :tombstone_unknown} = AshReplicant.status(StatusSink)
    end
  end

  describe "precedence — the generation entry outranks a durable tombstone" do
    test "a dead owner with no recorded cause is a fault (superseded), never ready and never not started" do
      dead = spawn(fn -> :ok end)
      AdmittedGeneration.put!(StatusSink, owner: dead)

      assert {:halted, :owner_lost} = AshReplicant.status(StatusSink)
      assert %{status: {:halted, :owner_lost}, lifecycle: :superseded} = derive()
    end

    test "a live owner that does not answer times out into catching_up, not owner loss" do
      # Alive but NOT a GenServer: the `:status` call can never be answered,
      # so the derivation must hit its timeout and re-check liveness.
      silent = spawn(:timer, :sleep, [:infinity])

      AdmittedGeneration.put!(StatusSink, owner: silent)

      assert :catching_up = AshReplicant.status(StatusSink)
      assert %{lifecycle: :degraded} = derive()
    end
  end

  describe "precedence — a node-local tombstone under a LIVE entry means the generation is halting" do
    test "healthy owner facts do not outrank the tombstone this generation just wrote" do
      # Activation clears the node-local leg BEFORE the entry exists, so a
      # tombstone coexisting with a live entry can only belong to THIS
      # generation — the halt decision has been made and the pipeline is
      # dying. The healthy-while-halting window must close: the tombstone
      # outranks the owner's own (stale-by-decision) facts.
      {:ok, owner} =
        FactsOwner.start(%{
          phase: :admitted,
          pipeline_alive: true,
          last_census: :healthy,
          census_enabled?: true,
          consecutive_faults: 0
        })

      AdmittedGeneration.put!(StatusSink, owner: owner)
      put_tombstone(:census_unverifiable, :halt)

      assert {:halted, :census_unverifiable} = AshReplicant.status(StatusSink)
      assert %{status: {:halted, :census_unverifiable}, lifecycle: :halted} = derive()
    end

    test "an operator-stopped tombstone under a live entry reports not started" do
      {:ok, owner} =
        FactsOwner.start(%{
          phase: :admitted,
          pipeline_alive: true,
          last_census: :healthy,
          census_enabled?: true,
          consecutive_faults: 0
        })

      AdmittedGeneration.put!(StatusSink, owner: owner)
      put_tombstone(:operator_stopped, :stopped)

      assert :not_started = AshReplicant.status(StatusSink)
      assert %{lifecycle: :stopped} = derive()
    end
  end

  describe "precedence — a live owner's facts decide the live states" do
    test "a pending owner is activating" do
      {:ok, owner} = FactsOwner.start(%{phase: :pending})
      AdmittedGeneration.put!(StatusSink, owner: owner)

      assert :catching_up = AshReplicant.status(StatusSink)
      assert %{lifecycle: :activating} = derive()
    end

    test "admitted with a healthy current census and live pipeline is ready/healthy" do
      {:ok, owner} =
        FactsOwner.start(%{
          phase: :admitted,
          pipeline_alive: true,
          last_census: :healthy,
          census_enabled?: true,
          consecutive_faults: 0
        })

      AdmittedGeneration.put!(StatusSink, owner: owner)

      assert :healthy = AshReplicant.status(StatusSink)
      assert %{lifecycle: :ready} = derive()
    end

    test "owner liveness alone is insufficient — census faults below budget degrade" do
      {:ok, owner} =
        FactsOwner.start(%{
          phase: :admitted,
          pipeline_alive: true,
          last_census: :faulted,
          census_enabled?: true,
          consecutive_faults: 1
        })

      AdmittedGeneration.put!(StatusSink, owner: owner)

      assert :catching_up = AshReplicant.status(StatusSink)
      assert %{lifecycle: :degraded} = derive()
    end

    test "a disabled census can never prove health" do
      {:ok, owner} =
        FactsOwner.start(%{
          phase: :admitted,
          pipeline_alive: true,
          last_census: :none,
          census_enabled?: false,
          consecutive_faults: 0
        })

      AdmittedGeneration.put!(StatusSink, owner: owner)

      assert :catching_up = AshReplicant.status(StatusSink)
      assert %{lifecycle: :degraded} = derive()
    end

    test "a census that never ran does not prove health" do
      {:ok, owner} =
        FactsOwner.start(%{
          phase: :admitted,
          pipeline_alive: true,
          last_census: :none,
          census_enabled?: true,
          consecutive_faults: 0
        })

      AdmittedGeneration.put!(StatusSink, owner: owner)

      assert :catching_up = AshReplicant.status(StatusSink)
    end

    test "an admitted owner whose pipeline already died is degraded, not ready" do
      {:ok, owner} =
        FactsOwner.start(%{
          phase: :admitted,
          pipeline_alive: false,
          last_census: :healthy,
          census_enabled?: true,
          consecutive_faults: 0
        })

      AdmittedGeneration.put!(StatusSink, owner: owner)

      assert :catching_up = AshReplicant.status(StatusSink)
      assert %{lifecycle: :degraded} = derive()
    end
  end

  describe "classification — the closed cause→class table" do
    test "contract, identity, and mapping drift classify misconfigured" do
      for reason <- [
            :source_identity_rebound,
            :source_identity_mismatch,
            :publication_contract_incompatible,
            :duplicate_source,
            :source_table_missing,
            :source_table_unmapped,
            :source_column_missing,
            :source_column_unmapped,
            :source_type_invalid,
            :source_replica_identity,
            {:invalid_destination_config, :repo}
          ] do
        assert :misconfigured = Status.classify(reason)
      end
    end

    test "everything else — including the census, fault, and integrity classes — is halt" do
      for reason <- [
            :census_unverifiable,
            :census_timeout,
            :census_source_unreachable,
            :census_checker_fault,
            :sink_failed,
            :schema_change_destructive,
            :tenant_required,
            :checkpoint_unbound,
            :snapshot_state_invalid,
            :append_origin_gap,
            :source_timeline_changed
          ] do
        assert :halt = Status.classify(reason)
      end
    end

    test "an unlisted reason defaults fail-closed to halt" do
      assert :halt = Status.classify(:something_new)
      assert :halt = Status.classify({:invalid_destination_config, :unlisted_tag})
    end
  end

  describe "tombstone encoding — closed strings, closed decode" do
    test "atom reasons round-trip" do
      assert {:halt, :census_unverifiable} =
               Status.decode_cause(Status.encode_cause(:census_unverifiable))

      assert {:misconfigured, :publication_contract_incompatible} =
               Status.decode_cause(Status.encode_cause(:publication_contract_incompatible))
    end

    test "the structural tuple reason round-trips over its closed tags" do
      encoded = Status.encode_cause({:invalid_destination_config, :repo})
      assert {:misconfigured, {:invalid_destination_config, :repo}} = Status.decode_cause(encoded)
    end

    test "a foreign or corrupted persisted cause decodes to the fallback, never raises" do
      assert {:halt, :tombstone_unknown} = Status.decode_cause("not a reason")
      assert {:halt, :tombstone_unknown} = Status.decode_cause("")
      assert {:halt, :tombstone_unknown} = Status.decode_cause(nil)
    end

    test "decoding a foreign cause never mints atoms from persisted bytes" do
      # The atom table is the hazard: a hostile or corrupted terminal_cause
      # string must be absorbed by the closed set, not converted into new
      # atoms (memory exhaustion through the decode path). async: false
      # keeps the atom count observation free of concurrent minting, and
      # the warm-up call forces any lazy first-call module loading OUTSIDE
      # the measured window (cross-vendor F5: a cold decode path loaded
      # modules and minted ~123 atoms inside it, reding the gate spuriously).
      _ = Status.decode_cause("warmup_probe")
      before = :erlang.system_info(:atom_count)

      assert {:halt, :tombstone_unknown} =
               Status.decode_cause("definitely_not_a_closed_reason_zq")

      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "value-free — the tombstone carries exactly cause, class, and a time" do
    test "the struct's fields are the closed set" do
      tombstone = %Status.Tombstone{
        cause: :census_unverifiable,
        class: :halt,
        at: DateTime.utc_now()
      }

      assert Map.keys(Map.from_struct(tombstone)) |> Enum.sort() == [:at, :cause, :class]
    end

    test "classify never returns outside its classes" do
      for reason <- [:census_unverifiable, :publication_contract_incompatible, :operator_stopped] do
        assert Status.classify(reason) in [:halt, :misconfigured, :stopped]
      end
    end
  end

  describe "the callback boundary writer (cross-vendor F3)" do
    test "an error leaving the boundary is terminal: recorded and passed through" do
      error =
        AshReplicant.Error.exception(reason: :source_timeline_changed, resource: nil, op: :bind)

      assert {:error, ^error} = Status.record_callback_error(@slot, {:error, error})

      assert %Status.Tombstone{cause: :source_timeline_changed, class: :halt} =
               :persistent_term.get(@tombstone_key)
    end

    test "a non-error result crosses the boundary untouched" do
      :persistent_term.erase(@tombstone_key)

      assert :ok = Status.record_callback_error(@slot, :ok)
      assert {:ok, nil} = Status.record_callback_error(@slot, {:ok, nil})
      assert :none == :persistent_term.get(@tombstone_key, :none)
    end
  end
end
