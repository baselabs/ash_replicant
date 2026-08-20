defmodule AshReplicant.Snapshot.State do
  @moduledoc """
  The checkpoint-owned snapshot state envelope (S02, ADR-0017).

  The source-bound checkpoint row is the serialization authority for snapshot
  chunks, stream transactions, completion and retirement. This module is the
  one encoder/decoder for the `snapshot_state` column it stores that authority
  in — a **versioned, MAC'd, strictly decoded** envelope, never
  `:erlang.binary_to_term/1` (which would let a tampered column inject atoms
  into the node).

  ## What it carries

    * `mode` — `:v1` (whole-table) or `:incremental`;
    * `status` — `:armed`, `:active`, or `:complete`;
    * `attempt` — a cryptographically random 256-bit attempt id. Membership is
      *this marker*: completion retires managed open rows whose stored marker
      differs;
    * `delivery_run` — the V1-only id minted for each `AshReplicant.PipelineOwner`
      activation. It is what makes a retry under a LATER owner rotate the
      attempt even when PostgreSQL hands back the same consistent point;
    * `contract_digest` — the admitted source and destination contract,
      including the action graph and code identity (`contract_digest/1`).
      A resume under drift fails closed rather than guessing that an
      incompatible attempt is safe;
    * `key_version` — the provenance HMAC key that authenticated the envelope; and
    * `completed_lsn` — the V1 replay fence.

  Attempt ids, delivery-run ids and tenants are **data-plane values**: they
  never enter an error, a log, or telemetry metadata. Every failure here is a
  structural atom.

  ## Why it is authenticated, not merely versioned

  Strict decoding already rejects a mangled column. It does NOT reject a
  *semantically valid* tamper — flipping the status byte from `active` to
  `complete` is one byte, and it would make completion return at the replay
  fence without ever retiring a row. The envelope is therefore HMAC-SHA-256'd
  under the same `:ash_replicant, :snapshot_provenance_keys` set the row
  fingerprints use (`AshReplicant.Snapshot.Provenance`), and the MAC covers the
  magic and version as well as the body.

  ## Impossible pairings

  ADR-0017 requires an *impossible* pairing to fail closed, not just an
  undecodable one. A V1 envelope with no delivery run, a `:complete` V1 envelope
  with no completed LSN, and an `:armed`/`:active` envelope that already carries
  one are each rejected on both encode and decode.
  """

  alias AshReplicant.Snapshot.Provenance

  @magic "arss"
  @version 1
  @modes %{v1: 1, incremental: 2}
  @statuses %{armed: 1, active: 2, complete: 3}
  @modes_by_byte Map.new(@modes, fn {name, byte} -> {byte, name} end)
  @statuses_by_byte Map.new(@statuses, fn {name, byte} -> {byte, name} end)
  @attempt_bytes 32
  @mac_bytes 32

  @typedoc "Whole-table (`:v1`) or incremental snapshot mode."
  @type mode :: :v1 | :incremental

  @typedoc "The attempt lifecycle: armed → active → complete."
  @type status :: :armed | :active | :complete

  @typedoc "Why an envelope could not be produced or read. Always value-free."
  @type failure :: :undecodable | :unknown_key_version

  @type t :: %__MODULE__{
          mode: mode(),
          status: status(),
          attempt: binary(),
          delivery_run: binary(),
          contract_digest: binary(),
          key_version: pos_integer(),
          completed_lsn: non_neg_integer() | nil
        }

  @enforce_keys [:mode, :status, :attempt, :delivery_run, :contract_digest, :key_version]
  defstruct [
    :mode,
    :status,
    :attempt,
    :delivery_run,
    :contract_digest,
    :key_version,
    :completed_lsn
  ]

  @doc "The envelope magic (exposed so tamper tests can address a byte offset)."
  @spec magic() :: binary()
  def magic, do: @magic

  @doc "The number of random bytes in an attempt or delivery-run id."
  @spec id_bytes() :: pos_integer()
  def id_bytes, do: @attempt_bytes

  @doc """
  The ACTIVE (highest) key version of a validated
  `AshReplicant.Snapshot.Provenance` key set — the version a freshly minted
  envelope is authenticated under.
  """
  @spec active_key_version(Provenance.key_set()) :: pos_integer() | nil
  def active_key_version(keys) when is_list(keys) and keys != [],
    do: keys |> Enum.map(&elem(&1, 0)) |> Enum.max()

  def active_key_version(_keys), do: nil

  @doc """
  Mint a fresh ACTIVE V1 attempt bound to `delivery_run` and `contract_digest`.

  The attempt is 256 bits from `:crypto.strong_rand_bytes/1` and is derived from
  NOTHING — not the consistent point, not the run. That is what makes an
  operator-authorized re-export under a later owner a genuinely different
  membership marker even when PostgreSQL returns the same `snapshot_lsn`.
  """
  @spec mint_v1(binary(), binary(), pos_integer()) :: t()
  def mint_v1(delivery_run, contract_digest, key_version)
      when is_binary(delivery_run) and is_binary(contract_digest) and is_integer(key_version) do
    %__MODULE__{
      mode: :v1,
      status: :active,
      attempt: :crypto.strong_rand_bytes(@attempt_bytes),
      delivery_run: delivery_run,
      contract_digest: contract_digest,
      key_version: key_version,
      completed_lsn: nil
    }
  end

  @doc """
  The admitted contract this attempt is bound to: one SHA-256 over the sink
  configuration digest, the destination manifest digest, the admitted code
  fingerprint, and the source contract fingerprint.

  All four come from the live generation, so an attempt cannot resume across a
  configuration, action-graph, bytecode, or source-contract change. A config
  missing any of them fails closed — the digest is never computed over a
  partial identity.
  """
  @spec contract_digest(map()) :: {:ok, binary()} | :error
  def contract_digest(config) when is_map(config) do
    with sink_digest when is_binary(sink_digest) <- Map.get(config, :sink_config_digest),
         %{digest: manifest_digest} when is_binary(manifest_digest) <-
           Map.get(config, :destination_manifest),
         code_fingerprint when is_binary(code_fingerprint) <- Map.get(config, :code_fingerprint),
         %{fingerprint: source_fingerprint} when is_binary(source_fingerprint) <-
           Map.get(config, :source_contract) do
      {:ok,
       :crypto.hash(
         :sha256,
         IO.iodata_to_binary([
           prefixed(sink_digest),
           prefixed(manifest_digest),
           prefixed(code_fingerprint),
           prefixed(source_fingerprint)
         ])
       )}
    else
      _other -> :error
    end
  end

  def contract_digest(_config), do: :error

  @doc """
  Encode `state` into the durable column bytes, authenticated under its own
  `key_version` of `keys`.
  """
  @spec encode(t(), Provenance.key_set()) :: {:ok, binary()} | {:error, failure()}
  def encode(%__MODULE__{} = state, keys) when is_list(keys) do
    with :ok <- validate(state),
         {:ok, key} <- fetch_key(keys, state.key_version),
         {:ok, body} <- body(state) do
      framed = @magic <> <<@version::8>> <> body
      {:ok, framed <> :crypto.mac(:hmac, :sha256, key, framed)}
    end
  end

  def encode(_state, _keys), do: {:error, :undecodable}

  @doc """
  Decode durable column bytes back into a `t:t/0`.

  Strict at every step: the magic, the envelope version, the mode and status
  bytes, the declared id lengths, the MAC, and the semantic pairing must all
  hold. Anything else is `{:error, :undecodable}` — never a guess, and never a
  silently fresh attempt (which would retire every row the previous attempt had
  legitimately marked).
  """
  @spec decode(binary(), Provenance.key_set()) :: {:ok, t()} | {:error, failure()}
  def decode(encoded, keys) when is_binary(encoded) and is_list(keys) do
    with {:ok, framed, mac} <- split_mac(encoded),
         {:ok, body} <- unframe(framed),
         {:ok, state} <- parse_body(body),
         {:ok, key} <- fetch_key(keys, state.key_version),
         :ok <- verify_mac(framed, mac, key),
         :ok <- validate(state) do
      {:ok, state}
    end
  end

  def decode(_encoded, _keys), do: {:error, :undecodable}

  # --- validation ---

  # The impossible-pairing gate, applied on BOTH sides: encode never mints a
  # shape decode would reject, and decode never admits one a tamper produced.
  defp validate(%__MODULE__{} = state) do
    if well_formed?(state) and valid_completion?(state), do: :ok, else: {:error, :undecodable}
  end

  # Shape: known vocabulary, present ids, a usable key version. `delivery_run`
  # is REQUIRED under V1 (it is the axis that rotates an attempt across owners)
  # and merely a binary otherwise.
  defp well_formed?(state) do
    is_map_key(@modes, state.mode) and is_map_key(@statuses, state.status) and
      id?(state.attempt) and id?(state.contract_digest) and
      valid_key_version?(state.key_version) and is_binary(state.delivery_run) and
      (state.mode != :v1 or id?(state.delivery_run))
  end

  defp id?(value), do: is_binary(value) and byte_size(value) in 1..255

  defp valid_key_version?(version),
    do: is_integer(version) and version >= 1 and version <= 0xFFFFFFFF

  # A `:complete` V1 attempt IS its replay fence — without the LSN there is
  # nothing to fence against, and completion would rescan. An `:armed` or
  # `:active` attempt carrying one is the inverse impossibility.
  defp valid_completion?(%{status: :complete, mode: :v1, completed_lsn: lsn}),
    do: is_integer(lsn) and lsn >= 0 and lsn <= 0xFFFFFFFFFFFFFFFF

  defp valid_completion?(%{status: :complete, completed_lsn: lsn}),
    do: is_nil(lsn) or (is_integer(lsn) and lsn >= 0 and lsn <= 0xFFFFFFFFFFFFFFFF)

  defp valid_completion?(%{completed_lsn: lsn}), do: is_nil(lsn)

  # --- the wire format ---

  defp body(%__MODULE__{} = state) do
    {flag, lsn} =
      case state.completed_lsn do
        nil -> {0, 0}
        value -> {1, value}
      end

    {:ok,
     IO.iodata_to_binary([
       <<Map.fetch!(@modes, state.mode)::8>>,
       <<Map.fetch!(@statuses, state.status)::8>>,
       sized(state.attempt),
       sized(state.delivery_run),
       sized(state.contract_digest),
       <<state.key_version::32>>,
       <<flag::8>>,
       <<lsn::64>>
     ])}
  end

  defp split_mac(encoded) when byte_size(encoded) > @mac_bytes do
    framed_size = byte_size(encoded) - @mac_bytes
    <<framed::binary-size(^framed_size), mac::binary-size(@mac_bytes)>> = encoded
    {:ok, framed, mac}
  end

  defp split_mac(_encoded), do: {:error, :undecodable}

  defp unframe(<<@magic, @version::8, body::binary>>), do: {:ok, body}
  defp unframe(_framed), do: {:error, :undecodable}

  defp parse_body(<<mode::8, status::8, rest::binary>>) do
    with {:ok, attempt, rest} <- take_sized(rest),
         {:ok, delivery_run, rest} <- take_sized(rest),
         {:ok, contract_digest, rest} <- take_sized(rest),
         <<key_version::32, flag::8, lsn::64>> <- rest,
         {:ok, mode_name} <- Map.fetch(@modes_by_byte, mode),
         {:ok, status_name} <- Map.fetch(@statuses_by_byte, status),
         {:ok, completed_lsn} <- completion(flag, lsn) do
      {:ok,
       %__MODULE__{
         mode: mode_name,
         status: status_name,
         attempt: attempt,
         delivery_run: delivery_run,
         contract_digest: contract_digest,
         key_version: key_version,
         completed_lsn: completed_lsn
       }}
    else
      _other -> {:error, :undecodable}
    end
  end

  defp parse_body(_body), do: {:error, :undecodable}

  # The flag and the value are decoded together so exactly ONE byte sequence
  # encodes "no completed LSN" — a `0` flag paired with a non-zero value would
  # otherwise be a second, equivalent encoding.
  defp completion(0, 0), do: {:ok, nil}
  defp completion(1, lsn), do: {:ok, lsn}
  defp completion(_flag, _lsn), do: :error

  defp sized(binary) when is_binary(binary), do: <<byte_size(binary)::8>> <> binary

  defp take_sized(<<size::8, value::binary-size(size), rest::binary>>), do: {:ok, value, rest}
  defp take_sized(_binary), do: :error

  defp prefixed(binary) when is_binary(binary), do: <<byte_size(binary)::64>> <> binary

  # --- keys ---

  defp fetch_key(keys, version) do
    case List.keyfind(keys, version, 0) do
      {^version, key} when is_binary(key) -> {:ok, key}
      _other -> {:error, :unknown_key_version}
    end
  end

  defp verify_mac(framed, mac, key) do
    computed = :crypto.mac(:hmac, :sha256, key, framed)

    if byte_size(mac) == byte_size(computed) and :crypto.hash_equals(mac, computed),
      do: :ok,
      else: {:error, :undecodable}
  end
end
