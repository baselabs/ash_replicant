defmodule AshReplicant.Horizon.KeyState do
  @moduledoc """
  The authenticated digest-key-set witness (O03, ADR-0022): the last-observed
  set of message-digest key VERSIONS, the active version, and the observation
  time — MAC'd under its own key version of
  `:ash_replicant, :horizon_provenance_keys`, an orthogonal family (never the
  rotating message digest keys themselves: authenticating under the keys whose
  removal this witness detects is circular — removing the authenticating
  version would make every envelope undecodable before the
  retirement-vs-violation classification could run).

  Why a witness at all: the AshOnetime claim stores only a hash of the
  versioned digest string, so the mint version is unreadable from claims; the
  only durable fact that can bound "a key version still backs
  potentially-live claims" is the last observation that saw it present.
  Claims mint continuously while the pipeline runs, so the envelope rebinds
  on every census-observed set change, never at binds alone — otherwise a
  long-lived connection understates a removed version's last-mint time and a
  sloppy rotation goes quietly blind.

  Value-free by construction: version integers, an active-version integer,
  and a DateTime. Key BYTES, prefixes, and row values never enter the
  envelope or its failures.
  """

  defstruct [:versions, :active, :recorded_at, :key_version]

  @type t :: %__MODULE__{
          versions: [pos_integer()],
          active: pos_integer(),
          recorded_at: DateTime.t(),
          key_version: pos_integer()
        }

  @magic "arh"
  @version 1
  @max_versions 16
  @mac_bytes 32

  @doc """
  The maximum digest-key version count the witness envelope can carry.
  Admission (Messages.preflight_digest/1) refuses a larger set so the cap
  surfaces as a configuration fault, never an encode failure at bind.
  """
  @spec max_versions() :: pos_integer()
  def max_versions, do: @max_versions

  @doc """
  Encode `state` into the durable column bytes, authenticated under its own
  `key_version` of the horizon provenance `keys`.
  """
  @spec encode(t(), [{pos_integer(), binary()}]) :: {:ok, binary()} | {:error, :undecodable}
  def encode(%__MODULE__{} = state, keys) when is_list(keys) do
    with :ok <- validate(state),
         {:ok, key} <- fetch_key(keys, state.key_version) do
      framed = frame(state)
      {:ok, framed <> :crypto.mac(:hmac, :sha256, key, framed)}
    else
      _other -> {:error, :undecodable}
    end
  end

  def encode(_state, _keys), do: {:error, :undecodable}

  @doc """
  Decode durable column bytes back into a `t:t/0`. Strict at every step:
  magic, envelope version, declared count, full consumption, and the MAC —
  anything else is `{:error, :undecodable}`, never a guess. An envelope
  minted under a key version absent from the configured set is distinguishable
  (`{:error, :unknown_key_version}`) so the caller can tell "the horizon key
  rotated away from the witness" from "corrupted".
  """
  @spec decode(binary(), [{pos_integer(), binary()}]) ::
          {:ok, t()} | {:error, :undecodable | :unknown_key_version}
  def decode(encoded, keys) when is_binary(encoded) and is_list(keys) do
    with {:ok, framed, mac} <- split_mac(encoded),
         {:ok, state} <- unframe(framed),
         {:ok, key} <- fetch_key(keys, state.key_version),
         :ok <- verify_mac(framed, mac, key) do
      {:ok, state}
    end
  end

  def decode(_encoded, _keys), do: {:error, :undecodable}

  @doc false
  @spec observed(pos_integer(), [pos_integer()], DateTime.t(), pos_integer()) :: t()
  def observed(active, versions, recorded_at, key_version) do
    %__MODULE__{
      versions: Enum.sort(versions),
      active: active,
      recorded_at: recorded_at,
      key_version: key_version
    }
  end

  # --- framing: all fixed-width, no term encoding ---
  # magic(3) version(1) key_version(32) active(32) count(16)
  #   count × version(32) recorded_at(signed 64) — then the 32-byte MAC.

  defp frame(%__MODULE__{} = state) do
    versions = Enum.sort(state.versions)
    unix_us = DateTime.to_unix(state.recorded_at, :microsecond)

    @magic <>
      <<@version::8, state.key_version::32, state.active::32, length(versions)::16,
        unix_us::signed-64>> <>
      Enum.map_join(versions, "", fn version -> <<version::32>> end)
  end

  defp unframe(
         @magic <>
           <<@version::8, key_version::32, active::32, count::16, unix_us::signed-64,
             rest::binary>>
       ) do
    with true <- count > 0 and count <= @max_versions,
         {:ok, versions, <<>>} <- take_versions(rest, count, []),
         true <- active in versions do
      {:ok,
       %__MODULE__{
         versions: versions,
         active: active,
         recorded_at: DateTime.from_unix!(unix_us, :microsecond),
         key_version: key_version
       }}
    else
      _other -> {:error, :undecodable}
    end
  end

  defp unframe(_other), do: {:error, :undecodable}

  defp take_versions(<<>>, 0, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp take_versions(<<version::32, rest::binary>>, remaining, acc) when remaining > 0,
    do: take_versions(rest, remaining - 1, [version | acc])

  defp take_versions(_rest, _remaining, _acc), do: {:error, :undecodable}

  defp validate(%__MODULE__{} = state) do
    with true <- valid_versions?(state.versions),
         true <- state.active == List.last(Enum.sort(state.versions)),
         true <- valid_key_version?(state.key_version),
         true <- valid_observation_time?(state.recorded_at) do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp valid_versions?(versions) do
    sorted = Enum.sort(versions)

    is_list(versions) and sorted != [] and length(sorted) <= @max_versions and
      length(Enum.uniq(sorted)) == length(sorted) and
      Enum.all?(sorted, &(is_integer(&1) and &1 > 0))
  end

  defp valid_key_version?(version), do: is_integer(version) and version > 0

  defp valid_observation_time?(%DateTime{} = at),
    do: DateTime.compare(at, ~U[1970-01-01 00:00:00Z]) == :gt

  defp valid_observation_time?(_other), do: false

  defp fetch_key(keys, version) do
    case List.keyfind(keys, version, 0) do
      {^version, key} when is_binary(key) -> {:ok, key}
      _other -> {:error, :unknown_key_version}
    end
  end

  defp split_mac(encoded) do
    size = byte_size(encoded)

    if size > @mac_bytes do
      split_at = size - @mac_bytes
      {:ok, binary_part(encoded, 0, split_at), binary_part(encoded, split_at, @mac_bytes)}
    else
      {:error, :undecodable}
    end
  end

  defp verify_mac(framed, mac, key) do
    computed = :crypto.mac(:hmac, :sha256, key, framed)

    if :crypto.hash_equals(mac, computed), do: :ok, else: {:error, :undecodable}
  end
end
