defmodule AshReplicant.CensusTest do
  @moduledoc """
  C01 (ADR-0019) pure unit tests for the continuous invariant census: the
  bounded-configuration gate, the jittered schedule, the typed verdict
  precedence, and the two pure classifiers (checkpoint + contract).

  Database-free by construction — the classifiers are pure functions over
  already-read rows and already-built contracts, which is exactly what lets
  every invariant carry its own mutation red-proof without a live substrate.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Census
  alias AshReplicant.Census.Options
  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Test.Domain

  @publication ["orders_pub"]

  defp sink_config do
    %{
      domains: [Domain],
      repo: AshReplicant.TestRepo,
      slot_name: "orders",
      checkpoint_resource: AshReplicant.Test.Checkpoint
    }
  end

  defp admitted_contract do
    {:ok, contract} = Identity.build_contract(sink_config(), @publication)
    contract
  end

  defp filter do
    %{source_system_id: "741852963", source_database: "postgres", slot_name: "orders"}
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        source_system_id: "741852963",
        source_database: "postgres",
        slot_name: "orders",
        source_timeline: 1,
        publication_contract: admitted_contract().encoded,
        publication_fingerprint: admitted_contract().fingerprint
      },
      overrides
    )
  end

  describe "options/1 — the bounded-census configuration gate" do
    test "the defaults are positive and bounded" do
      assert {:ok, %Options{} = options} = Census.options([])

      assert options.enabled? == true
      assert options.interval_ms > 0
      assert options.timeout_ms > 0
      assert options.max_consecutive_faults > 0

      assert options.timeout_ms <= 60_000
    end

    test "an explicit census configuration round-trips" do
      assert {:ok, options} =
               Census.options(
                 census: [
                   enabled?: false,
                   interval_ms: 10_000,
                   jitter_ratio: 0.1,
                   timeout_ms: 500,
                   max_consecutive_faults: 2
                 ]
               )

      assert options == %Options{
               enabled?: false,
               interval_ms: 10_000,
               jitter_ratio: 0.1,
               timeout_ms: 500,
               max_consecutive_faults: 2
             }
    end

    test "the timeout is independently bounded because the owner schedules after settle" do
      assert {:ok, _} =
               Census.options(census: [interval_ms: 1_000, jitter_ratio: 0.2, timeout_ms: 1_200])

      assert {:error, :census_options_invalid} =
               Census.options(census: [interval_ms: 1_000, timeout_ms: 60_001])
    end

    test "an unknown census key fails closed" do
      assert {:error, :census_options_invalid} = Census.options(census: [inverval_ms: 1_000])
    end

    test "a non-keyword census option fails closed" do
      assert {:error, :census_options_invalid} = Census.options(census: false)
      assert {:error, :census_options_invalid} = Census.options(census: %{interval_ms: 1_000})
    end

    test "out-of-range and wrongly typed values fail closed" do
      assert {:error, :census_options_invalid} = Census.options(census: [jitter_ratio: 0.75])
      assert {:error, :census_options_invalid} = Census.options(census: [jitter_ratio: -0.1])
      assert {:error, :census_options_invalid} = Census.options(census: [jitter_ratio: 1])
      assert {:error, :census_options_invalid} = Census.options(census: [interval_ms: 0])
      assert {:error, :census_options_invalid} = Census.options(census: [interval_ms: 49])
      assert {:error, :census_options_invalid} = Census.options(census: [timeout_ms: 0])
      assert {:error, :census_options_invalid} = Census.options(census: [enabled?: :yes])

      assert {:error, :census_options_invalid} =
               Census.options(census: [max_consecutive_faults: 0])
    end
  end

  describe "next_delay/1 — bounded jitter" do
    test "every draw lands inside the closed jittered window" do
      {:ok, options} = Census.options(census: [interval_ms: 1_000, jitter_ratio: 0.2])

      for _ <- 1..500 do
        delay = Census.next_delay(options)
        assert delay >= 800 and delay <= 1_200
      end
    end

    test "the schedule is actually jittered (not a constant interval)" do
      {:ok, options} = Census.options(census: [interval_ms: 1_000, jitter_ratio: 0.2])

      draws = Enum.map(1..200, fn _ -> Census.next_delay(options) end)

      assert Enum.uniq(draws) |> length() > 1,
             "a constant delay would synchronize every owner on one source"
    end

    test "a zero jitter ratio yields exactly the interval" do
      {:ok, options} = Census.options(census: [interval_ms: 1_000, jitter_ratio: 0.0])

      assert Enum.all?(1..50, fn _ -> Census.next_delay(options) == 1_000 end)
    end
  end

  describe "state/1 — the typed verdict precedence" do
    test "all passing is healthy" do
      assert Census.state(destination: :pass, contract: :pass) == :healthy
    end

    test "drift outranks a fault and reports the FIRST drifting check" do
      assert Census.state(
               destination: {:fault, :checker_fault},
               contract: {:drift, :publication_contract_incompatible},
               coverage: {:drift, :source_type_invalid}
             ) == {:drifted, :contract, :publication_contract_incompatible}
    end

    test "a fault is never reported as healthy" do
      assert Census.state(destination: :pass, coverage: {:fault, :source_unreachable}) ==
               {:faulted, :coverage, :source_unreachable}
    end

    test "an EMPTY check list fails closed rather than reporting healthy" do
      assert {:faulted, _check, _reason} = Census.state([])
    end
  end

  describe "classify_checkpoint/3 — the durable checkpoint invariants" do
    test "untrusted checkpoint bytes cannot intern a new atom" do
      name = "ash_replicant_untrusted_atom_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

      encoded = <<131, 118, byte_size(name)::16, name::binary>>
      assert :error = Identity.decode(encoded)

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "the bound row under the admitted contract passes" do
      assert Census.classify_checkpoint([row()], filter(), admitted_contract().manifest) == :pass
    end

    test "a NULL stored contract is unverifiable until the bind initializes it" do
      assert Census.classify_checkpoint(
               [row(%{publication_contract: nil})],
               filter(),
               admitted_contract().manifest
             ) == {:fault, :checkpoint_unbound}
    end

    test "no row for the slot is a FAULT, never a pass (the bind may simply not have run yet)" do
      # The census cannot tell "not yet bound" from "deleted underneath us", so
      # it renders no verdict — it faults, which counts against the budget and
      # halts as :census_unverifiable if the row never appears. Classifying an
      # absent row as drift would halt every healthy pipeline whose first
      # census outran its first checkpoint bind.
      assert Census.classify_checkpoint([], filter(), admitted_contract().manifest) ==
               {:fault, :checkpoint_unbound}
    end

    test "two rows under one slot means the unique index is gone (mutation: index dropped)" do
      assert Census.classify_checkpoint(
               [row(), row(%{source_database: "other"})],
               filter(),
               admitted_contract().manifest
             ) == {:drift, :source_identity_rebound}
    end

    test "a rebound identity triple turns red (mutation: system id / database / slot)" do
      for override <- [
            %{source_system_id: "999999999"},
            %{source_database: "elsewhere"},
            %{slot_name: "other_slot"}
          ] do
        assert Census.classify_checkpoint(
                 [row(override)],
                 filter(),
                 admitted_contract().manifest
               ) == {:drift, :source_identity_rebound}
      end
    end

    test "an undecodable stored contract turns red (mutation: tampered bytes)" do
      assert Census.classify_checkpoint(
               [row(%{publication_contract: <<0, 1, 2, 3>>})],
               filter(),
               admitted_contract().manifest
             ) == {:drift, :publication_contract_incompatible}
    end

    test "a fingerprint that does not authenticate the stored bytes turns red" do
      assert Census.classify_checkpoint(
               [row(%{publication_fingerprint: <<0, 1, 2, 3>>})],
               filter(),
               admitted_contract().manifest
             ) == {:drift, :publication_contract_incompatible}
    end

    test "an INCOMPATIBLE stored manifest turns red (mutation: a relation disappeared)" do
      manifest = admitted_contract().manifest
      shrunk = %{manifest | relations: Enum.drop(manifest.relations, 1)}

      # Stored = the full contract; current = the shrunk one. A relation the
      # stored contract carried and the live one does not is set-monotone
      # incompatible.
      assert {:drift, :publication_contract_incompatible} =
               Census.classify_checkpoint([row()], filter(), shrunk)
    end

    test "a COMPATIBLE additive relation transition still passes" do
      manifest = admitted_contract().manifest
      relation = hd(manifest.relations)

      grown = %{
        manifest
        | relations:
            Enum.sort_by(
              [%{relation | schema: "archive", table: "orders_archive"} | manifest.relations],
              &{&1.schema, &1.table}
            )
      }

      assert Census.classify_checkpoint([row()], filter(), grown) == :pass
    end
  end

  describe "classify_contract/2 — the live-vs-admitted contract invariant" do
    test "an unchanged resource DSL passes" do
      assert Census.classify_contract(config(), admitted_contract()) == :pass
    end

    test "a drifted admitted contract turns red (mutation: the publication changed)" do
      admitted = admitted_contract()
      drifted = %{admitted | manifest: %{admitted.manifest | publication: ["someone_elses_pub"]}}

      assert Census.classify_contract(config(), drifted) ==
               {:drift, :publication_contract_incompatible}
    end

    test "a config that can no longer produce a contract turns red" do
      assert Census.classify_contract(%{config() | domains: [NotADomain]}, admitted_contract()) ==
               {:drift, :publication_contract_incompatible}
    end
  end

  describe "classify_coverage_result/1 — canonical preflight outcomes" do
    test "a canonical coverage violation is drift with its frozen reason" do
      error =
        AshReplicant.Error.exception(
          reason: :source_type_invalid,
          resource: nil,
          op: :preflight
        )

      assert Census.classify_coverage_result({:error, error}) ==
               {:drift, :source_type_invalid}
    end

    test "an unreachable census source is a fault, never a pass" do
      assert Census.classify_coverage_result({:ok, :deferred}) ==
               {:fault, :census_source_unreachable}
    end

    test "a successful full preflight passes" do
      assert Census.classify_coverage_result({:ok, %{facts: %{}, ignored: MapSet.new()}}) == :pass
    end
  end

  defp config do
    Map.merge(sink_config(), %{publication: @publication, ignored_sources: []})
  end
end
