defmodule AshReplicant.CensusOwnerTest do
  @moduledoc """
  C01 (ADR-0019): the owner's census schedule, its bounded dispatch, the
  consecutive-fault budget, and the fail-closed halt — database-free.

  The port-1 source connection deliberately fails (the `PipelineOwnerTest`
  precedent), and the structural suite runs with no repo started, so every
  census in this file faults on the substrate-touching checks. That is the
  point: it makes the FAULT path — the one that must never be mistaken for a
  pass — directly observable without a live substrate.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias AshReplicant.Census
  alias AshReplicant.Destination.Generation

  defmodule CensusSink do
    @moduledoc false
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "census_owner_slot"
  end

  @slot "census_owner_slot"
  @key {AshReplicant, @slot}
  @source_identity [system_identifier: "741852963", database: "postgres"]

  defp start_opts(extra) do
    Keyword.merge(
      [
        sink: CensusSink,
        connection: [
          hostname: "127.0.0.1",
          port: 1,
          username: "postgres",
          database: "postgres",
          connect_timeout: 50,
          queue_target: 50,
          queue_interval: 50,
          timeout: 100
        ],
        publication: "census_owner_pub",
        source_identity: @source_identity,
        go_forward_only: true
      ],
      extra
    )
  end

  defp eventually(fun, polls \\ 400) do
    cond do
      fun.() -> :ok
      polls == 0 -> flunk("condition not reached within the poll budget")
      true -> Process.sleep(25)
    end
    |> case do
      :ok -> :ok
      _ -> eventually(fun, polls - 1)
    end
  end

  defp attach do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:ash_replicant, :census, :passed],
        [:ash_replicant, :census, :faulted],
        [:ash_replicant, :census, :halted]
      ],
      fn event, measurements, meta, _c ->
        send(test_pid, {:census, ref, event, Map.merge(measurements, meta)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  setup do
    AshReplicant.stop_supervised(@slot)
    :persistent_term.erase(@key)

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      :persistent_term.erase(@key)
    end)

    :ok
  end

  describe "the census configuration gate is wired into activation" do
    test "an unbounded timeout fails the start synchronously and installs no generation" do
      assert {:error, :census_options_invalid} =
               AshReplicant.start_link(start_opts(census: [timeout_ms: 999_999]))

      assert :none == :persistent_term.get(@key, :none)
    end

    test "an unknown census key fails the start synchronously" do
      assert {:error, :census_options_invalid} =
               AshReplicant.start_link(start_opts(census: [interval: 1_000]))
    end
  end

  describe "the consecutive-fault budget (fail closed, but not on one blip)" do
    test "faults below the budget do NOT halt; the Nth fault halts with :census_unverifiable" do
      ref = attach()

      capture_log(fn ->
        assert {:ok, owner} =
                 AshReplicant.start_link(
                   start_opts(
                     census: [
                       interval_ms: 100,
                       jitter_ratio: 0.0,
                       timeout_ms: 90,
                       max_consecutive_faults: 3
                     ]
                   )
                 )

        # Exactly two tolerated faults, then the budget is exhausted.
        assert_receive {:census, ^ref, [:ash_replicant, :census, :faulted], first}, 20_000
        assert first.slot_name == @slot
        assert is_atom(first.kind) and is_atom(first.reason)

        assert_receive {:census, ^ref, [:ash_replicant, :census, :faulted], _second}, 20_000

        assert_receive {:census, ^ref, [:ash_replicant, :census, :halted],
                        %{reason: :census_unverifiable}},
                       20_000

        # The halt is a real fail-closed teardown: generation erased, owner gone.
        eventually(fn -> :persistent_term.get(@key, :none) == :none end)
        eventually(fn -> not Process.alive?(owner) end)
      end)
    end

    test "a monitored worker timeout is typed, killed, and the owner survives it" do
      ref = attach()

      capture_log(fn ->
        assert {:ok, owner} =
                 AshReplicant.start_link(
                   start_opts(
                     census: [
                       interval_ms: 60_000,
                       jitter_ratio: 0.0,
                       timeout_ms: 5_000,
                       max_consecutive_faults: 50
                     ]
                   )
                 )

        worker = spawn(fn -> Process.sleep(:infinity) end)
        token = make_ref()
        timeout = Process.send_after(owner, :never, 60_000)

        :sys.replace_state(owner, fn state ->
          state
          |> Map.put(:census_timer, nil)
          |> Map.put(:census_run, %{
            token: token,
            monitor: Process.monitor(worker),
            pid: worker,
            timeout: timeout,
            timed_out?: false
          })
        end)

        send(owner, {:census_timeout, token})

        assert_receive {:census, ^ref, [:ash_replicant, :census, :faulted],
                        %{reason: :census_timeout}},
                       20_000

        refute Process.alive?(worker)
        assert Process.alive?(owner)
        assert %Generation{} = :persistent_term.get(@key, :none)
        assert :sys.get_state(owner).census_run == nil
      end)
    end
  end

  describe "one owner schedules ONE bounded census" do
    test "a tick arriving while a census is in flight is dropped, not stacked" do
      capture_log(fn ->
        assert {:ok, owner} =
                 AshReplicant.start_link(
                   start_opts(
                     census: [
                       interval_ms: 60_000,
                       jitter_ratio: 0.0,
                       timeout_ms: 5_000,
                       max_consecutive_faults: 50
                     ]
                   )
                 )

        # Install a synthetic in-flight run (a never-answering worker), then
        # tick: the owner must NOT start a second census over it.
        worker = spawn(fn -> Process.sleep(:infinity) end)
        timeout = Process.send_after(owner, :never, 60_000)
        token = make_ref()

        :sys.replace_state(owner, fn state ->
          state
          |> Map.put(:census_timer, nil)
          |> Map.put(:census_run, %{
            token: token,
            monitor: Process.monitor(worker),
            pid: worker,
            timeout: timeout,
            timed_out?: false
          })
        end)

        send(owner, :census_tick)
        in_flight = :sys.get_state(owner).census_run

        assert in_flight.pid == worker,
               "a second census must never displace one already in flight"

        Process.exit(worker, :kill)
      end)
    end

    test "a disabled census schedules nothing" do
      ref = attach()

      capture_log(fn ->
        assert {:ok, owner} =
                 AshReplicant.start_link(
                   start_opts(census: [enabled?: false, interval_ms: 100, jitter_ratio: 0.0])
                 )

        refute_receive {:census, ^ref, _event, _payload}, 700
        assert Process.alive?(owner)
        assert :sys.get_state(owner).census_run == nil
        assert :sys.get_state(owner).census_timer == nil
      end)
    end

    test "pipeline death kills an in-flight census worker before owner cleanup" do
      capture_log(fn ->
        assert {:ok, owner} =
                 AshReplicant.start_link(
                   start_opts(
                     census: [
                       interval_ms: 60_000,
                       jitter_ratio: 0.0,
                       timeout_ms: 5_000,
                       max_consecutive_faults: 50
                     ]
                   )
                 )

        worker = spawn(fn -> Process.sleep(:infinity) end)
        timeout = Process.send_after(owner, :never, 60_000)

        :sys.replace_state(owner, fn state ->
          state
          |> Map.put(:census_timer, nil)
          |> Map.put(:census_run, %{
            token: make_ref(),
            monitor: Process.monitor(worker),
            pid: worker,
            timeout: timeout,
            timed_out?: false
          })
        end)

        assert :ok = Replicant.stop(@slot)

        eventually(fn -> not Process.alive?(owner) end)
        refute Process.alive?(worker)
        assert :none == :persistent_term.get(@key, :none)
      end)
    end
  end

  describe "run/2 — each admitted invariant carries its own mutation red-proof" do
    test "the DESTINATION invariant turns red when the admitted code fingerprint drifts" do
      capture_log(fn ->
        assert {:ok, _owner} =
                 AshReplicant.start_link(start_opts(census: [enabled?: false]))

        %Generation{} = generation = :persistent_term.get(@key)

        # Mutation: the admitted delivery-path code fingerprint no longer
        # matches the live modules — exactly the class `validate_generation/1`
        # defends, now re-checked continuously instead of only per callback.
        :persistent_term.put(@key, %Generation{generation | code_fingerprint: <<0, 0, 0, 0>>})

        assert %Census.Report{state: {:drifted, :destination, :config_invalid}} =
                 Census.run(@slot, CensusSink)
      end)
    end

    test "the CONTRACT invariant turns red when the admitted contract drifts from the live DSL" do
      capture_log(fn ->
        assert {:ok, _owner} =
                 AshReplicant.start_link(start_opts(census: [enabled?: false]))

        %Generation{source_contract: contract} = generation = :persistent_term.get(@key)

        drifted = %{
          contract
          | manifest: %{contract.manifest | publication: ["someone_elses_publication"]}
        }

        :persistent_term.put(@key, %Generation{generation | source_contract: drifted})

        assert %Census.Report{
                 state: {:drifted, :contract, :publication_contract_incompatible}
               } = Census.run(@slot, CensusSink)
      end)
    end

    test "an absent generation is drift, never a pass" do
      capture_log(fn ->
        assert {:ok, _owner} = AshReplicant.start_link(start_opts(census: [enabled?: false]))
        :persistent_term.erase(@key)

        assert %Census.Report{state: {:drifted, :destination, _reason}} =
                 Census.run(@slot, CensusSink)
      end)
    end

    test "a census never raises out of a faulting checker" do
      capture_log(fn ->
        assert {:ok, _owner} = AshReplicant.start_link(start_opts(census: [enabled?: false]))

        # No repo is started in the structural suite and the source is
        # unreachable: both substrate checks fault, and the report must still
        # be a typed non-pass rather than an exception.
        assert %Census.Report{state: {:faulted, check, reason}} = Census.run(@slot, CensusSink)
        assert check in [:checkpoint, :coverage]

        assert reason in [
                 :census_checker_fault,
                 :census_source_unreachable,
                 :checkpoint_unbound
               ]
      end)
    end
  end
end
