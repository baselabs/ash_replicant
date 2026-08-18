defmodule AshReplicant.Messages do
  @moduledoc """
  Logical-message routing and application (C1, ADR-0015).

  A `pg_logical_emit_message` payload routes by its PREFIX to a host create
  action declared on the sink (`message_routes`); an explicitly ignored
  prefix acknowledges with no effect; an unknown prefix halts fail-closed.
  The routed action carries an AshOnetime idempotency claim whose key is the
  6+label operation identity (`:message` invocation, participant = the routed
  resource) and whose FINGERPRINT is the versioned host-keyed content digest
  — the claim persists no content in any derivable form, and a digest
  mismatch under every retained key version halts rather than replaying a
  stale response or re-executing.

  Transactional messages ride `%Transaction.messages` (ordinal shared with
  the changes' numbering space) and are applied by the sink inside the
  transaction. Non-transactional messages arrive standalone via
  `handle_message/2` with NO framework dedup — the claim is the dedup.
  """

  alias AshReplicant.{DestinationParticipant, Error, Telemetry}

  @digest_min_key_bytes 16

  # --- the versioned host-keyed digest ---

  @doc """
  The validated digest-key set: a non-empty list of
  `{positive_integer_version, binary_key}` with unique versions and keys of
  at least #{@digest_min_key_bytes} bytes, sorted ascending by version.
  The ACTIVE version is the highest; the others are RETAINED for
  rotation-window replay (`digest_order/1`).
  """
  @spec digest_keys() :: {:ok, [{pos_integer(), binary()}]} | :error
  def digest_keys do
    case Application.get_env(:ash_replicant, :message_digest_keys) do
      keys when is_list(keys) and keys != [] ->
        with true <- Enum.all?(keys, &valid_digest_key?/1),
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

  defp valid_digest_key?({version, key})
       when is_integer(version) and version >= 1 and is_binary(key) and
              byte_size(key) >= @digest_min_key_bytes,
       do: true

  defp valid_digest_key?(_other), do: false

  @doc """
  The digest attempt order: the ACTIVE (highest) version first, then the
  retained versions descending. A re-delivered message whose claim was minted
  under a retained version replays by retrying down this list (a fingerprint
  mismatch is an admission REJECTION — the action body never ran — so the
  retry is effect-free).
  """
  @spec digest_order([{pos_integer(), binary()}]) :: {:ok, [pos_integer()]} | :error
  def digest_order(keys) when is_list(keys) and keys != [] do
    versions = keys |> Enum.map(&elem(&1, 0)) |> Enum.sort(&(&1 >= &2))

    if length(Enum.uniq(versions)) == length(versions),
      do: {:ok, versions},
      else: :error
  end

  def digest_order(_other), do: :error

  @doc """
  The versioned host-keyed HMAC over the message content:
  `v<version>:<hex(hmac_sha256(key, content))>`. Keyed (never a bare digest —
  claims are destination rows and an unkeyed digest admits offline content
  guessing) and versioned (rotation retains old versions through the
  claim/recovery lifetime).
  """
  @spec digest(binary(), pos_integer(), [{pos_integer(), binary()}]) ::
          {:ok, binary()} | :error
  def digest(content, version, keys)
      when is_binary(content) and is_integer(version) and is_list(keys) do
    case List.keyfind(keys, version, 0) do
      {^version, key} when is_binary(key) ->
        mac = :crypto.mac(:hmac, :sha256, key, content)
        {:ok, "v#{version}:" <> Base.encode16(mac, case: :lower)}

      _other ->
        :error
    end
  end

  def digest(_content, _version, _keys), do: :error

  @doc false
  @spec preflight_digest(map()) :: :ok | {:error, term()}
  def preflight_digest(config) do
    if routes_configured?(config) do
      case digest_keys() do
        {:ok, _keys} ->
          :ok

        :error ->
          {:error, Error.exception(reason: :config_invalid, resource: nil, op: :activation)}
      end
    else
      :ok
    end
  end

  # --- routing ---

  @doc """
  Resolve `prefix` against the sink's routing surface:
  `{:ok, %{resource:, action:}}` for a route, `:ignored` for an explicit
  ignore, `{:error, :unmapped}` otherwise (the caller halts fail-closed).
  """
  @spec resolve_route(map(), binary()) ::
          {:ok, %{resource: module(), action: atom()}} | :ignored | {:error, :unmapped}
  def resolve_route(config, prefix) when is_binary(prefix) do
    routes = Map.get(config, :message_routes, [])

    case List.keyfind(routes, prefix, 0) do
      {^prefix, resource, action} ->
        {:ok, %{resource: resource, action: action}}

      _routed ->
        if prefix in Map.get(config, :ignored_message_prefixes, []) do
          :ignored
        else
          {:error, :unmapped}
        end
    end
  end

  def resolve_route(_config, _prefix), do: {:error, :unmapped}

  # --- operation identity ---

  @doc """
  The message's operation-identity context: the same 6+label shape as every
  other sink effect, with `invocation: :message` and `participant` = the
  routed resource. A TRANSACTIONAL message keys on the transaction's
  `commit_lsn` and its own ordinal (the shared numbering space); a STANDALONE
  message keys on its OWN LSN (each standalone emission owns one WAL
  position) with ordinal 0.
  """
  @spec operation_context(map(), Replicant.Decoder.Messages.Message.t(), Replicant.lsn() | nil) ::
          {:ok, map()} | :error
  def operation_context(
        %{
          source_identity: %{system_identifier: system, database: database},
          slot_name: slot_name
        },
        %Replicant.Decoder.Messages.Message{lsn: message_lsn, ordinal: ordinal},
        txn_commit_lsn
      )
      when is_binary(system) and is_binary(database) and is_binary(slot_name) do
    lsn = txn_commit_lsn || message_lsn
    ordinal = if is_integer(ordinal), do: ordinal, else: 0

    if is_integer(lsn) and lsn >= 0 and ordinal >= 0 do
      {:ok,
       %{
         source_system_identifier: system,
         source_database: database,
         slot_name: slot_name,
         commit_lsn: lsn,
         ordinal: ordinal,
         invocation: :message
       }}
    else
      :error
    end
  end

  def operation_context(_config, _message, _txn_commit_lsn), do: :error

  # --- application ---

  @doc """
  Apply one routed message through its protected action: mint the operation
  key, digest the content under the ACTIVE version (retrying retained
  versions on a fingerprint mismatch), and drive the create with the sink's
  admission posture (`authorize?: false`, ambient transaction, notifications
  bundled-and-discarded). Raises `AshReplicant.Error` (value-free) on every
  failure path. Emits `[:ash_replicant, :message, :applied]` with the
  content's `byte_size` — never the content.
  """
  @spec apply(map(), Replicant.Decoder.Messages.Message.t(), map(), Replicant.lsn() | nil) :: :ok
  def apply(config, %Replicant.Decoder.Messages.Message{} = message, route, txn_commit_lsn) do
    with {:ok, operation} <- operation_context(config, message, txn_commit_lsn),
         {:ok, keys} <- digest_keys(),
         {:ok, versions} <- digest_order(keys),
         {:ok, operation_key} <- operation_key(operation, route),
         :ok <-
           drive_with_rotation(config, message, route, operation, keys, versions, operation_key) do
      Telemetry.event(
        [:ash_replicant, :message, :applied],
        %{byte_size: byte_size(message.content || "")},
        %{
          commit_lsn: operation.commit_lsn,
          resource: route.resource,
          transactional: message.transactional? == true
        }
      )

      :ok
    else
      {:error, %Error{} = error} ->
        raise error

      _other ->
        raise Error.exception(reason: :config_invalid, resource: route.resource, op: :message)
    end
  end

  defp operation_key(operation, route) do
    case DestinationParticipant.operation_key(operation, route.resource) do
      {:ok, key} -> {:ok, key}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  # Mint the digest under each version in descending order. A fingerprint
  # mismatch (`:key_reused_with_different_request`) is an ADMISSION rejection:
  # the action body never ran, so retrying under the next retained version is
  # effect-free. Every version mismatching is the genuine corruption class —
  # the raise halts fail-closed. Any OTHER error halts immediately (no retry).
  defp drive_with_rotation(config, message, route, operation, keys, versions, operation_key) do
    versions
    |> Enum.reduce_while(:exhausted, fn version, :exhausted ->
      attempt_version(config, message, route, operation, keys, version, operation_key)
    end)
    |> case do
      :ok ->
        :ok

      :exhausted ->
        {:error,
         Error.exception(
           reason: :sink_failed,
           resource: route.resource,
           op: :message,
           shape: "content_digest_mismatch"
         )}

      {:error, _error} = passed ->
        passed
    end
  end

  defp attempt_version(config, message, route, operation, keys, version, operation_key) do
    case digest(message.content || "", version, keys) do
      {:ok, digest} ->
        case drive(config, message, route, operation, operation_key, digest) do
          :ok -> {:halt, :ok}
          {:error, :fingerprint_mismatch} -> {:cont, :exhausted}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      :error ->
        {:halt, {:error, :invalid}}
    end
  end

  defp drive(config, message, route, operation, operation_key, digest) do
    # The sink-fed arguments are PRIVATE (the public action surface accepts
    # only the content payload); they ride the `private_arguments:` option —
    # the same convention the auxiliary fixtures use.
    Ash.create!(route.resource, %{content: message.content || ""},
      action: route.action,
      authorize?: config_authorize(config),
      transaction?: false,
      return_notifications?: true,
      private_arguments: %{operation_key: operation_key, content_digest: digest},
      context: action_context(config, operation)
    )

    :ok
  rescue
    e ->
      if fingerprint_mismatch?(e) do
        {:error, :fingerprint_mismatch}
      else
        {:error, Error.scrub(e, route.resource, :message)}
      end
  catch
    _kind, value ->
      # A fingerprint mismatch can surface as a DBConnection EXIT tuple
      # carrying the typed AshOnetime leaf ({DBConnection, ref, error}) —
      # structural detection only (code-atom match, never a value read);
      # everything else scrubs value-free as always.
      if fingerprint_mismatch?(value) do
        {:error, :fingerprint_mismatch}
      else
        {:error, Error.scrub_caught(value, route.resource, :message)}
      end
  end

  defp config_authorize(config), do: Map.get(config, :authorize?, false)

  defp action_context(config, operation) do
    %{
      data_layer: Map.get(config, :data_layer_context, %{repo: config.repo}),
      ash_replicant_operation: operation
    }
  end

  # Structural CODE match only (value-free): the AshOnetime fingerprint
  # mismatch surfaces as Ash.Error.Invalid wrapping the typed leaf, OR as a
  # DBConnection exit tuple carrying it ({DBConnection, ref, error}) when the
  # claim collision rides a connection-level fault — walk both shapes.
  defp fingerprint_mismatch?(%{code: :key_reused_with_different_request}), do: true

  defp fingerprint_mismatch?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &fingerprint_mismatch?/1)

  defp fingerprint_mismatch?({_, _, inner}), do: fingerprint_mismatch?(inner)

  defp fingerprint_mismatch?(_other), do: false

  defp routes_configured?(config) do
    Map.get(config, :message_routes, []) != [] or
      Map.get(config, :ignored_message_prefixes, []) != []
  end
end
