defmodule AshReplicant.HorizonKeyStateTest do
  @moduledoc """
  O03 D3: the digest-key horizon witness — an authenticated envelope on the
  checkpoint row recording the last-observed digest-key set, so a key version
  removed while claims minted under it could still be re-delivered alerts
  BEFORE replay becomes impossible (adversarial F1: rebind on observed set
  change, classify against the last observation CONTAINING the version).
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshReplicant.Destination
  alias AshReplicant.Horizon
  alias AshReplicant.Horizon.KeyState
  alias AshReplicant.Test.{Checkpoint, Messages}

  @keys [{1, :crypto.strong_rand_bytes(16)}, {2, :crypto.strong_rand_bytes(16)}]
  @now ~U[2026-08-23 12:00:00Z]

  describe "the horizon provenance key set" do
    # ENV-MUTATION BAN (CI root cause): an async test swapping the shared
    # Application env poisons concurrently-starting pipelines — activations
    # fail closed on require_provenance_keys, and a bind under swapped keys
    # mints a witness the baseline census cannot decode (census drift).
    # Invalid shapes go through the PURE validator; the happy path asserts
    # the config baseline read-only.
    test "reads the validated config baseline without mutating env" do
      assert {:ok, [{1, _baseline}]} = Horizon.provenance_keys()
    end

    test "the pure validator sorts a valid set and rejects malformed shapes" do
      assert {:ok, [{1, _}, {2, _}]} =
               Horizon.provenance_key_set([
                 {2, :binary.copy("k", 16)},
                 {1, :binary.copy("j", 16)}
               ])

      for bad <- [
            [],
            [{1, "short"}],
            [{1, :binary.copy("a", 16)}, {1, :binary.copy("b", 16)}],
            [{0, :binary.copy("a", 16)}],
            "no"
          ] do
        assert :error = Horizon.provenance_key_set(bad)
      end
    end
  end

  describe "the envelope codec" do
    test "round-trips the observed set under its authenticating key version" do
      state = %KeyState{versions: [1, 2], active: 2, recorded_at: @now, key_version: 2}

      assert {:ok, encoded} = KeyState.encode(state, @keys)
      assert {:ok, decoded} = KeyState.decode(encoded, @keys)

      # Instant equality: the decoded DateTime carries microsecond precision
      # {0, 6} while the sigil literal carries {0, 0} — same moment.
      assert DateTime.compare(decoded.recorded_at, state.recorded_at) == :eq
      assert %{decoded | recorded_at: nil} == %{state | recorded_at: nil}
    end

    test "a tampered payload byte never decodes" do
      state = %KeyState{versions: [1, 2], active: 2, recorded_at: @now, key_version: 2}
      {:ok, encoded} = KeyState.encode(state, @keys)

      tampered =
        encoded
        |> :binary.decode_unsigned()
        |> Kernel.+(1)
        |> :binary.encode_unsigned()

      assert {:error, :undecodable} = KeyState.decode(tampered, @keys)

      assert {:error, :undecodable} =
               KeyState.decode(:binary.part(encoded, 0, byte_size(encoded) - 1), @keys)
    end

    test "an envelope minted under a key absent from the set names the version gap" do
      state = %KeyState{versions: [3], active: 3, recorded_at: @now, key_version: 3}
      {:ok, encoded} = KeyState.encode(state, [{3, :binary.copy("z", 16)}])

      assert {:error, :unknown_key_version} = KeyState.decode(encoded, @keys)
    end
  end

  describe "classification (adversarial F1 semantics)" do
    test "an unchanged set is :ok" do
      state = %KeyState{versions: [1, 2], active: 2, recorded_at: @now, key_version: 2}

      assert {:ok, :ok} = Horizon.classify_key_state(state, [1, 2], @now, 86_400)
    end

    test "an ADDED version rebinds — the observation must track last-mint" do
      state = %KeyState{versions: [1], active: 1, recorded_at: @now, key_version: 1}

      assert {:ok, :rebind} = Horizon.classify_key_state(state, [1, 2], @now, 86_400)
    end

    test "a version removed within the retention horizon is a violation" do
      state = %KeyState{versions: [1, 2], active: 2, recorded_at: @now, key_version: 2}

      # 86_399s after the last observation containing v1 — inside retention.
      assert {:error, :digest_key_horizon_violated} =
               Horizon.classify_key_state(state, [2], DateTime.add(@now, 86_399), 86_400)
    end

    test "a version removed past the retention horizon is a legitimate rebind" do
      state = %KeyState{versions: [1, 2], active: 2, recorded_at: @now, key_version: 2}

      assert {:ok, :rebind} =
               Horizon.classify_key_state(state, [2], DateTime.add(@now, 86_400), 86_400)
    end

    test "removing the envelope's ACTIVE version violates regardless of set stability (cross-vendor)" do
      # A stable {v1} set observed 10 days ago (retention 7d): v1 minted
      # claims until ~the removal — its retention clock never started. The
      # elapsed-since-observation rule alone would wrongly legitimize this.
      state = %KeyState{versions: [1], active: 1, recorded_at: @now, key_version: 1}

      assert {:error, :digest_key_horizon_violated} =
               Horizon.classify_key_state(state, [], DateTime.add(@now, 86_400 * 10), 86_400)
    end

    test "clock regression fails closed" do
      state = %KeyState{versions: [1], active: 1, recorded_at: @now, key_version: 1}

      assert {:error, :digest_key_state_invalid} =
               Horizon.classify_key_state(state, [1], DateTime.add(@now, -1), 86_400)
    end

    test "undecodable durable bytes fail closed through the raw classifier" do
      assert {:error, :digest_key_state_invalid} =
               Horizon.classify_stored_key_state(<<0, 1, 2>>, @keys, [1], @now, 86_400)
    end
  end

  describe "the retention bound" do
    test "max_route_retention walks the manifest's message protections" do
      {:ok, manifest} =
        Destination.manifest(%{
          repo: AshReplicant.TestRepo,
          domains: [Messages.Domain],
          checkpoint_resource: AshReplicant.Test.Checkpoint,
          message_routes: [
            {"outbox", Messages.Outbox, :record},
            {"transient", Messages.TransientOutbox, :record}
          ]
        })

      assert {:ok, 86_400} = Horizon.max_route_retention(manifest)
    end
  end

  describe "the checkpoint column" do
    test "the generated checkpoint resource carries the nullable binary attribute" do
      attribute = Info.attribute(Checkpoint, :digest_key_state)

      assert %{} = attribute
      assert attribute.type == Ash.Type.Binary
      assert attribute.allow_nil? == true
    end
  end
end
