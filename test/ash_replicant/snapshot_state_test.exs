defmodule AshReplicant.SnapshotStateTest do
  use ExUnit.Case, async: false

  alias AshReplicant.Snapshot.State
  alias AshReplicant.Test.Provenance

  @keys [{1, "test-snapshot-provenance-key-v1"}, {2, "test-snapshot-provenance-key-v2"}]

  defp v1(overrides \\ %{}) do
    Map.merge(
      %State{
        mode: :v1,
        status: :active,
        attempt: :binary.copy(<<7>>, 32),
        delivery_run: :binary.copy(<<9>>, 32),
        contract_digest: :binary.copy(<<3>>, 32),
        key_version: 1,
        progress_token_hash: nil,
        completed_lsn: nil
      },
      overrides
    )
  end

  defp incremental(overrides) do
    Map.merge(
      %State{
        mode: :incremental,
        status: :armed,
        attempt: :binary.copy(<<8>>, 32),
        delivery_run: "",
        contract_digest: :binary.copy(<<4>>, 32),
        key_version: 1,
        next_ordinal: 0,
        progress_token_hash: nil,
        completed_lsn: nil,
        completed_token_hash: nil
      },
      overrides
    )
  end

  defp legacy_v1(state) do
    completed_lsn = state.completed_lsn || 0
    completed_flag = if(is_nil(state.completed_lsn), do: 0, else: 1)

    body =
      IO.iodata_to_binary([
        <<1::8, 2::8>>,
        sized(state.attempt),
        sized(state.delivery_run),
        sized(state.contract_digest),
        <<state.key_version::32, completed_flag::8, completed_lsn::64>>
      ])

    framed = State.magic() <> <<1::8>> <> body
    key = @keys |> Map.new() |> Map.fetch!(state.key_version)
    framed <> :crypto.mac(:hmac, :sha256, key, framed)
  end

  defp sized(value), do: <<byte_size(value)::8>> <> value

  describe "encode/decode round trip" do
    test "an active V1 attempt round-trips under its own key version" do
      state = v1()

      assert {:ok, encoded} = State.encode(state, @keys)
      assert is_binary(encoded)
      assert {:ok, ^state} = State.decode(encoded, @keys)
    end

    test "a complete V1 attempt carries its completed LSN" do
      state = v1(%{status: :complete, completed_lsn: 9_876_543_210})

      assert {:ok, encoded} = State.encode(state, @keys)
      assert {:ok, ^state} = State.decode(encoded, @keys)
    end

    test "an incremental attempt carries a token-hash completion fence" do
      token_hash = :crypto.hash(:sha256, "opaque-progress-token")

      state =
        incremental(%{
          status: :complete,
          progress_token_hash: token_hash,
          completed_token_hash: token_hash
        })

      assert {:ok, encoded} = State.encode(state, @keys)
      assert {:ok, ^state} = State.decode(encoded, @keys)
    end

    test "an active incremental attempt authenticates its separately stored progress token" do
      token_hash = :crypto.hash(:sha256, "opaque-progress-token")
      state = incremental(%{status: :active, progress_token_hash: token_hash})

      assert {:ok, encoded} = State.encode(state, @keys)
      assert {:ok, ^state} = State.decode(encoded, @keys)
    end

    test "a row minted under a RETAINED key still decodes after rotation" do
      state = v1(%{key_version: 1})
      assert {:ok, encoded} = State.encode(state, @keys)

      # Rotation adds v2 and retains v1: the envelope names v1, so it verifies.
      assert {:ok, ^state} = State.decode(encoded, @keys)
    end

    test "a legacy version-1 V1 envelope decodes with the new fields absent" do
      encoded = legacy_v1(v1())

      assert {:ok, decoded} = State.decode(encoded, @keys)
      assert decoded.mode == :v1
      assert decoded.status == :active
      assert is_nil(decoded.next_ordinal)
      assert is_nil(decoded.progress_token_hash)
      assert is_nil(decoded.completed_token_hash)
    end

    test "encoding under an unknown key version fails closed" do
      assert {:error, :unknown_key_version} = State.encode(v1(%{key_version: 99}), @keys)
    end

    test "decoding after the naming key is DROPPED fails closed, never as a fresh attempt" do
      assert {:ok, encoded} = State.encode(v1(%{key_version: 1}), @keys)

      assert {:error, :unknown_key_version} =
               State.decode(encoded, [{2, "test-snapshot-provenance-key-v2"}])
    end
  end

  describe "strict decoding" do
    test "a flipped STATUS byte is caught by the MAC (a semantically valid tamper)" do
      assert {:ok, encoded} = State.encode(v1(%{status: :active}), @keys)

      # The status byte sits immediately after the magic, the version, and the
      # mode byte. Flip `active` (2) to `armed` (1) — a pairing every structural
      # rule ACCEPTS (armed with no completed LSN is exactly a legal envelope),
      # so nothing but the MAC can reject it.
      #
      # Flipping to `complete` (3) would NOT prove this: that trips the
      # impossible-pairing rule instead, and the test would stay green with the
      # MAC check entirely removed. Proven by driving both mutations.
      prefix_size = byte_size(State.magic()) + 2
      <<prefix::binary-size(^prefix_size), status::8, rest::binary>> = encoded
      assert status == 2
      tampered = <<prefix::binary, 1::8, rest::binary>>

      assert byte_size(tampered) == byte_size(encoded)
      assert {:error, :undecodable} = State.decode(tampered, @keys)
    end

    test "a tampered ATTEMPT id is caught by the MAC" do
      assert {:ok, encoded} = State.encode(v1(), @keys)

      # Flip one byte inside the attempt id, not at a boundary.
      offset = byte_size(State.magic()) + 4 + 10
      <<head::binary-size(^offset), byte::8, tail::binary>> = encoded
      tampered = <<head::binary, Bitwise.bxor(byte, 0xFF)::8, tail::binary>>

      assert {:error, :undecodable} = State.decode(tampered, @keys)
    end

    test "a foreign magic, an unknown envelope version, and truncation all fail closed" do
      assert {:ok, encoded} = State.encode(v1(), @keys)
      <<_magic::binary-size(4), rest::binary>> = encoded

      assert {:error, :undecodable} = State.decode(<<"xxxx", rest::binary>>, @keys)

      <<magic::binary-size(4), _version::8, tail::binary>> = encoded
      assert {:error, :undecodable} = State.decode(<<magic::binary, 99::8, tail::binary>>, @keys)

      assert {:error, :undecodable} =
               State.decode(binary_part(encoded, 0, byte_size(encoded) - 1), @keys)

      assert {:error, :undecodable} = State.decode(<<>>, @keys)
      assert {:error, :undecodable} = State.decode(:not_a_binary, @keys)
    end

    test "an unknown mode or status byte fails closed rather than defaulting" do
      assert {:error, :undecodable} = State.encode(v1(%{mode: :bogus}), @keys)
      assert {:error, :undecodable} = State.encode(v1(%{status: :bogus}), @keys)
    end
  end

  describe "impossible pairings fail closed" do
    test "a V1 envelope with no delivery run is rejected on encode AND decode" do
      assert {:error, :undecodable} = State.encode(v1(%{delivery_run: ""}), @keys)
    end

    test "a COMPLETE V1 envelope with no completed LSN is rejected" do
      assert {:error, :undecodable} =
               State.encode(v1(%{status: :complete, completed_lsn: nil}), @keys)
    end

    test "an ARMED/ACTIVE envelope carrying a completed LSN is rejected" do
      assert {:error, :undecodable} =
               State.encode(v1(%{status: :active, completed_lsn: 5}), @keys)

      assert {:error, :undecodable} = State.encode(v1(%{status: :armed, completed_lsn: 5}), @keys)
    end

    test "a negative completed LSN is rejected" do
      assert {:error, :undecodable} =
               State.encode(v1(%{status: :complete, completed_lsn: -1}), @keys)
    end

    test "incremental completion hashes are symmetric and only complete state carries the fence" do
      token_hash = :crypto.hash(:sha256, "opaque-progress-token")

      assert {:error, :undecodable} =
               State.encode(
                 incremental(%{status: :armed, progress_token_hash: token_hash}),
                 @keys
               )

      assert {:error, :undecodable} =
               State.encode(
                 incremental(%{status: :active, completed_token_hash: token_hash}),
                 @keys
               )

      assert {:error, :undecodable} =
               State.encode(incremental(%{status: :complete, completed_token_hash: nil}), @keys)

      assert {:error, :undecodable} =
               State.encode(
                 incremental(%{
                   status: :complete,
                   progress_token_hash: token_hash,
                   completed_token_hash: :crypto.hash(:sha256, "different-token")
                 }),
                 @keys
               )
    end
  end

  describe "mint_v1/3" do
    test "mints a 256-bit random attempt bound to the delivery run" do
      run = :binary.copy(<<1>>, 32)
      digest = :binary.copy(<<2>>, 32)

      a = State.mint_v1(run, digest, 1)
      b = State.mint_v1(run, digest, 1)

      assert byte_size(a.attempt) == 32
      assert a.mode == :v1
      assert a.status == :active
      assert a.delivery_run == run
      assert a.contract_digest == digest
      assert is_nil(a.progress_token_hash)
      assert is_nil(a.completed_lsn)

      # Two mints for the SAME run and consistent point still differ: the
      # attempt is random, never derived from the LSN.
      refute a.attempt == b.attempt
    end
  end

  describe "mint_incremental/2" do
    test "mints a durable armed attempt without a V1 delivery run" do
      digest = :binary.copy(<<2>>, 32)

      a = State.mint_incremental(digest, 1)
      b = State.mint_incremental(digest, 1)

      assert byte_size(a.attempt) == 32
      assert a.mode == :incremental
      assert a.status == :armed
      assert a.delivery_run == ""
      assert a.contract_digest == digest
      assert a.next_ordinal == 0
      assert is_nil(a.progress_token_hash)
      assert is_nil(a.completed_lsn)
      assert is_nil(a.completed_token_hash)
      refute a.attempt == b.attempt
    end
  end

  describe "ordinal invariants" do
    test "incremental state requires an unsigned 64-bit ordinal" do
      for invalid <- [nil, -1, 0x1_0000_0000_0000_0000] do
        assert {:error, :undecodable} =
                 State.encode(incremental(%{next_ordinal: invalid}), @keys)
      end
    end

    test "V1 state rejects any ordinal" do
      assert {:error, :undecodable} = State.encode(v1(%{next_ordinal: 0}), @keys)
    end
  end

  describe "contract_digest/1" do
    test "binds all four admitted identities and changes when any one changes" do
      config = %{
        sink_config_digest: <<1, 1, 1>>,
        destination_manifest: %AshReplicant.Destination.Manifest{
          repo: AshReplicant.TestRepo,
          entries: [],
          onetime_prefixes_by_action: %{},
          notifier_loads: %{},
          digest: <<2, 2, 2>>
        },
        code_fingerprint: <<3, 3, 3>>,
        source_contract: %{fingerprint: <<4, 4, 4>>}
      }

      assert {:ok, base} = State.contract_digest(config)
      assert byte_size(base) == 32

      for {key, mutate} <- [
            {:sink_config_digest, fn c -> %{c | sink_config_digest: <<9>>} end},
            {:manifest,
             fn c -> %{c | destination_manifest: %{c.destination_manifest | digest: <<9>>}} end},
            {:code_fingerprint, fn c -> %{c | code_fingerprint: <<9>>} end},
            {:source_contract, fn c -> %{c | source_contract: %{fingerprint: <<9>>}} end}
          ] do
        assert {:ok, changed} = State.contract_digest(mutate.(config))
        refute changed == base, "contract digest ignored #{key}"
      end
    end

    test "a config missing any admitted identity fails closed" do
      assert :error = State.contract_digest(%{})

      assert :error =
               State.contract_digest(%{
                 sink_config_digest: <<1>>,
                 code_fingerprint: <<3>>,
                 source_contract: %{fingerprint: <<4>>}
               })
    end
  end

  describe "the configured key set" do
    test "encode/decode use the ACTIVE (highest) version when minting" do
      Provenance.with_provenance_keys!(@keys, fn ->
        assert {:ok, keys} = AshReplicant.Snapshot.Provenance.keys()
        assert State.active_key_version(keys) == 2
      end)
    end

    test "rejects a version outside the state envelope's unsigned 32-bit field" do
      Provenance.with_provenance_keys!(
        [{0x1_0000_0000, "test-snapshot-provenance-key-v-too-large"}],
        fn ->
          assert :error = AshReplicant.Snapshot.Provenance.keys()
        end
      )
    end
  end
end
