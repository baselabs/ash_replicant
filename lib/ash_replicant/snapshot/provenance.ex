defmodule AshReplicant.Snapshot.Provenance do
  @moduledoc """
  The versioned, host-keyed snapshot row fingerprint (S01, ADR-0017).

  A snapshot retry must not repeat a host business effect for a row that did
  not change. Final-state convergence is not enough — a create, destroy, or
  SCD2 close can carry an append-only local effect even when a later upsert
  converges to the same row. So each snapshot-managed row stores a
  fingerprint over the exact values the host action was given, and a retry
  that recomputes the same fingerprint marks the row seen instead of
  re-running the business action.

  ## The two version numbers

  The stored fingerprint is tagged `e<encoding>v<key>:<hex>`. Both numbers are
  load-bearing and they fail differently:

    * the **key** version selects the HMAC key. Rotation adds a higher version
      while retaining the old ones, so a row minted under a retained key still
      verifies — otherwise every rotation would re-run every host business
      action for every unchanged row.
    * the **encoding** version identifies the canonical byte format below. A
      format change makes old fingerprints incomparable, which is an operator
      migration, not a row change.

  Neither mismatch is ever reported as `:changed`. A missing key version, an
  unknown encoding version, a malformed fingerprint, and a value that cannot be
  deterministically encoded all fail closed — per ADR-0017, *"missing keys fail
  closed rather than treating every row as changed and repeating business
  effects."*

  ## The canonical encoding

  `canonical/3` encodes the encoding version, the resource module, its source
  `{schema, table}`, the resolved tenant, and the mapped action inputs. The
  inputs are `AshReplicant.Resolver.upsert_input/2`'s `inputs` map, so
  `skip`ped source columns are excluded by construction rather than by a second
  rule.

  Every value is **type-tagged** and **length-prefixed**, containers carry an
  explicit **element count**, and map keys are sorted by their encoded bytes.
  Those three properties are what make the encoding injective; without them
  distinct rows collide and a changed row is silently skipped:

    * no length prefix — `{tenant: "ab", %{x: "c"}}` and
      `{tenant: "a", %{bx: "c"}}` concatenate identically;
    * no type tag — integer `1` and binary `"1"` encode identically;
    * no container count — `[["a"], ["b"]]` and `[["a", "b"]]` flatten together.

  An unrecognised term (pid, reference, function, or a struct not named below)
  is `{:error, :unencodable}` rather than a guessed encoding.

  Fingerprints, like attempt ids and tenants, are **data-plane values**: they
  never enter an error, a log, or telemetry metadata. Every failure here is a
  structural atom.

  Keys come from `:ash_replicant, :snapshot_provenance_keys` and follow the
  same validated shape as C1's `:message_digest_keys` (`AshReplicant.Messages`)
  — one keying convention for the two keyed surfaces in this package.
  """

  alias AshReplicant.Error
  alias AshReplicant.Resource.Info

  @encoding_version 1
  @min_key_bytes 16
  @magic "arp"
  @hex_digest_bytes 64

  @typedoc "A validated `{version, key}` provenance key set."
  @type key_set :: [{pos_integer(), binary()}]

  @typedoc "Why a fingerprint could not be produced or compared. Always value-free."
  @type failure ::
          :unencodable
          | :unknown_key_version
          | :unknown_encoding_version
          | :malformed_fingerprint

  @doc "The canonical encoding version embedded in every fingerprint tag."
  @spec encoding_version() :: pos_integer()
  def encoding_version, do: @encoding_version

  # --- the key set ---

  @doc """
  The validated provenance-key set from `:ash_replicant,
  :snapshot_provenance_keys`: a non-empty list of
  `{positive_integer_version, binary_key}` with unique versions and keys of at
  least #{@min_key_bytes} bytes, sorted ascending by version. The ACTIVE
  version is the highest; the others are RETAINED for the rotation window.
  """
  @spec keys() :: {:ok, key_set()} | :error
  def keys do
    case Application.get_env(:ash_replicant, :snapshot_provenance_keys) do
      keys when is_list(keys) and keys != [] ->
        with true <- Enum.all?(keys, &valid_key?/1),
             versions = Enum.map(keys, &elem(&1, 0)),
             true <- length(Enum.uniq(versions)) == length(versions) do
          {:ok, Enum.sort(keys)}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp valid_key?({version, key})
       when is_integer(version) and version >= 1 and is_binary(key) and
              byte_size(key) >= @min_key_bytes,
       do: true

  defp valid_key?(_other), do: false

  @doc """
  The version attempt order: the ACTIVE (highest) version first, then the
  retained versions descending. A row is minted under the active version and
  verified under the version its own tag names, so this order is what a
  rotation-window sweep walks.
  """
  @spec key_order(key_set()) :: {:ok, [pos_integer()]} | :error
  def key_order(keys) when is_list(keys) and keys != [] do
    versions = keys |> Enum.map(&elem(&1, 0)) |> Enum.sort(&(&1 >= &2))

    if length(Enum.uniq(versions)) == length(versions),
      do: {:ok, versions},
      else: :error
  end

  def key_order(_other), do: :error

  @doc """
  Fail closed at activation when a mapped resource declares
  `snapshot_provenance true` but the key configuration is absent or malformed —
  the same posture as C1's message-digest activation preflight.
  """
  @spec preflight(map()) :: :ok | {:error, Error.t()}
  def preflight(config) do
    if provenance_declared?(config) do
      case keys() do
        {:ok, _keys} ->
          :ok

        :error ->
          {:error, Error.exception(reason: :config_invalid, resource: nil, op: :activation)}
      end
    else
      :ok
    end
  end

  defp provenance_declared?(config) do
    config
    |> Map.get(:domains, [])
    |> AshReplicant.Resolver.domain_resources()
    |> Enum.any?(&provenance_resource?/1)
  end

  defp provenance_resource?(resource) do
    AshReplicant.Resource in Spark.extensions(resource) and
      Info.replicant_snapshot_provenance!(resource) == true
  end

  # --- the fingerprint ---

  @doc """
  The fingerprint over `(resource, tenant, inputs)` under `version` of `keys`:
  `"e<encoding>v<key>:" <> hex(hmac_sha256(key, canonical))`.

  Keyed, never a bare digest — a fingerprint is a destination row value, and an
  unkeyed digest would admit offline guessing of the mirrored row.
  """
  @spec fingerprint(module(), term(), map(), pos_integer(), key_set()) ::
          {:ok, binary()} | {:error, failure()}
  def fingerprint(resource, tenant, inputs, version, keys)
      when is_atom(resource) and is_map(inputs) and is_integer(version) and is_list(keys) do
    case List.keyfind(keys, version, 0) do
      {^version, key} when is_binary(key) ->
        with {:ok, bytes} <- canonical(resource, tenant, inputs) do
          mac = :crypto.mac(:hmac, :sha256, key, bytes)
          {:ok, tag(version) <> Base.encode16(mac, case: :lower)}
        end

      _other ->
        {:error, :unknown_key_version}
    end
  end

  @doc """
  Compare a `stored` fingerprint against the current `(resource, tenant,
  inputs)`.

  Recomputes under the key version the STORED tag names, so a row minted before
  a rotation still verifies. Returns `:match` for an unchanged row, `:changed`
  for a genuinely different one, and `{:error, reason}` for every case where the
  answer is unknown — key loss, an unknown encoding version, a malformed tag, or
  an input that cannot be deterministically encoded. An unknown answer must NOT
  degrade to `:changed`: that would re-run the host business action and repeat
  an append-only effect.
  """
  @spec compare(term(), module(), term(), map(), key_set()) ::
          :match | :changed | {:error, failure()}
  def compare(stored, resource, tenant, inputs, keys) when is_binary(stored) do
    with {:ok, key_version} <- parse_tag(stored),
         {:ok, computed} <- fingerprint(resource, tenant, inputs, key_version, keys) do
      if constant_time_equal?(stored, computed), do: :match, else: :changed
    end
  end

  def compare(_stored, _resource, _tenant, _inputs, _keys), do: {:error, :malformed_fingerprint}

  defp tag(version), do: "e#{@encoding_version}v#{version}:"

  @tag_pattern ~r/^e(\d+)v(\d+):([0-9a-f]+)$/

  defp parse_tag(stored) do
    case Regex.run(@tag_pattern, stored) do
      [_full, encoding, key_version, hex] when byte_size(hex) == @hex_digest_bytes ->
        if String.to_integer(encoding) == @encoding_version,
          do: {:ok, String.to_integer(key_version)},
          else: {:error, :unknown_encoding_version}

      _other ->
        {:error, :malformed_fingerprint}
    end
  end

  # `:crypto.hash_equals/2` raises on differing sizes, so guard the size first.
  # Both sides carry the same tag by construction (the computed side uses the
  # version parsed from the stored side), making this guard defensive only.
  defp constant_time_equal?(a, b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  # --- the canonical encoding ---

  @doc """
  The canonical bytes for `(resource, tenant, inputs)`. See the moduledoc for
  the injectivity properties this encoding guarantees.
  """
  @spec canonical(module(), term(), map()) :: {:ok, binary()} | {:error, :unencodable}
  def canonical(resource, tenant, inputs) when is_atom(resource) and is_map(inputs) do
    with {:ok, tenant_bytes} <- encode(tenant),
         {:ok, input_bytes} <- encode_map(inputs) do
      {:ok,
       IO.iodata_to_binary([
         @magic,
         <<@encoding_version::64>>,
         prefixed(Atom.to_string(resource)),
         # `source_schema/1` always resolves (explicit, reflected, else "public");
         # `source_table/1` can be nil for a resource with no table at all, which
         # `Resolver.build_index/1` rejects at activation.
         prefixed(Info.source_schema(resource)),
         prefixed(Info.source_table(resource) || ""),
         tenant_bytes,
         input_bytes
       ])}
    end
  end

  def canonical(_resource, _tenant, _inputs), do: {:error, :unencodable}

  defp prefixed(binary) when is_binary(binary), do: <<byte_size(binary)::64>> <> binary

  # Every clause emits a TYPE TAG followed by a self-delimiting payload, so
  # concatenated values are unambiguous. The literal atoms come before the
  # generic `is_atom/1` clause, and the named structs before `is_map/1`.
  defp encode(nil), do: {:ok, "z"}
  defp encode(true), do: {:ok, "t"}
  defp encode(false), do: {:ok, "f"}
  defp encode(value) when is_binary(value), do: {:ok, "b" <> prefixed(value)}
  defp encode(value) when is_atom(value), do: {:ok, "a" <> prefixed(Atom.to_string(value))}

  defp encode(value) when is_integer(value),
    do: {:ok, "i" <> prefixed(Integer.to_string(value))}

  defp encode(value) when is_float(value),
    do: {:ok, "d" <> prefixed(:erlang.float_to_binary(value, [:short]))}

  # Decimal's string form is scale-preserving, and Postgres returns a fixed
  # scale per numeric column, so this is deterministic per mapped column.
  defp encode(%Decimal{} = value), do: {:ok, "c" <> prefixed(Decimal.to_string(value, :normal))}
  defp encode(%Date{} = value), do: {:ok, "D" <> prefixed(Date.to_iso8601(value))}
  defp encode(%Time{} = value), do: {:ok, "T" <> prefixed(Time.to_iso8601(value))}

  defp encode(%NaiveDateTime{} = value),
    do: {:ok, "N" <> prefixed(NaiveDateTime.to_iso8601(value))}

  defp encode(%DateTime{} = value), do: {:ok, "U" <> prefixed(DateTime.to_iso8601(value))}
  defp encode(value) when is_list(value), do: encode_list(value)
  defp encode(value) when is_tuple(value), do: encode_tuple(value)
  defp encode(value) when is_map(value) and not is_struct(value), do: encode_map(value)

  # A pid, reference, function, or unrecognised struct has no deterministic
  # encoding. Fail closed rather than guess one.
  defp encode(_other), do: {:error, :unencodable}

  # Walks the list explicitly so an improper list fails closed instead of
  # raising out of `Enum`.
  defp encode_list(list) do
    with {:ok, count, payload} <- encode_elements(list, 0, []) do
      {:ok, "l" <> <<count::64>> <> payload}
    end
  end

  defp encode_tuple(tuple) do
    with {:ok, count, payload} <- encode_elements(Tuple.to_list(tuple), 0, []) do
      {:ok, "u" <> <<count::64>> <> payload}
    end
  end

  defp encode_elements([], count, acc),
    do: {:ok, count, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp encode_elements([head | tail], count, acc) do
    case encode(head) do
      {:ok, bytes} -> encode_elements(tail, count + 1, [bytes | acc])
      {:error, _reason} = error -> error
    end
  end

  defp encode_elements(_improper_tail, _count, _acc), do: {:error, :unencodable}

  # Pairs are sorted by their ENCODED bytes. Map keys are unique and each
  # encoded key is a self-delimiting prefix of its pair, so this orders by key
  # deterministically across mixed key types.
  defp encode_map(map) do
    with {:ok, pairs} <- encode_pairs(Enum.to_list(map), []) do
      payload = pairs |> Enum.sort() |> IO.iodata_to_binary()
      {:ok, "m" <> <<map_size(map)::64>> <> payload}
    end
  end

  defp encode_pairs([], acc), do: {:ok, acc}

  defp encode_pairs([{key, value} | tail], acc) do
    with {:ok, key_bytes} <- encode(key),
         {:ok, value_bytes} <- encode(value) do
      encode_pairs(tail, [key_bytes <> value_bytes | acc])
    end
  end
end
