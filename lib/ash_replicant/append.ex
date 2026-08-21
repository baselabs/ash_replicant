defmodule AshReplicant.Append do
  @moduledoc """
  Applies one `%Replicant.Change{}` to an immutable APPEND target (ADR-0018).

  Where `AshReplicant.Apply` converges a mirror row to the source's current
  state, this module records the change itself as an event and never modifies
  or removes a stored one. Insert, update, delete, truncate, logical message
  and snapshot each have an explicit shape; the append identity is exactly
  `(source system, database, slot, commit LSN, ordinal)`.

  ## Append-once, without overwriting

  The append runs `upsert?: true` against the host's declared append identity
  with an EMPTY `upsert_fields`. AshPostgres renders an empty upsert set as
  `ON CONFLICT (<identity>) DO UPDATE SET <identity col> = EXCLUDED.<identity
  col>` — the conflicting row's PAYLOAD is untouched. So a lawfully re-delivered
  WAL position (a redo after a crash, a snapshot re-run) is a durable no-op
  rather than a second row OR a mutation of the stored event. A plain insert
  would raise on the same replay, and a payload-carrying upsert would silently
  rewrite history; both are wrong for a log.

  Effect-once still rests where it always did: the append and the checkpoint
  commit in the SAME locked destination transaction. The unique identity is a
  defensive database constraint under that, not a substitute for it.

  ## Value-freedom

  `operation` and `origin` are library-minted structural labels from a closed
  set; the attempt is checkpoint-owned bytes. Nothing derived from a row value
  ever reaches an error, log, or telemetry event — every failure re-raises
  through `AshReplicant.Error.scrub/3` exactly as the mirror paths do.

  Called once per change, in delivery (`ordinal`) order, inside the sink's
  transaction. Raises on any failure so the surrounding `Repo.transaction` rolls
  the whole transaction back.
  """

  alias AshReplicant.Apply.Context
  alias AshReplicant.{Error, Resolver}
  alias AshReplicant.Resource.Info

  # The closed operation-label set. `Replicant.Change.op` is a framework-typed
  # atom, but rendering it with `Atom.to_string/1` would let a future framework
  # op reach the host's column unreviewed — an explicit table keeps the stored
  # vocabulary a decision rather than a side effect.
  @operations %{
    insert: "insert",
    update: "update",
    delete: "delete",
    truncate: "truncate",
    snapshot: "snapshot",
    message: "message"
  }

  @stream_origin "stream"
  @snapshot_origin "snapshot"

  @doc """
  Append one change to `resource`. Returns `:ok`; raises a value-free
  `AshReplicant.Error` on failure.
  """
  @spec apply(map(), module(), Replicant.Change.t()) :: :ok
  def apply(config, resource, %Replicant.Change{op: :truncate} = change) do
    case Info.replicant_on_truncate!(resource) do
      :append ->
        # A TRUNCATE is a structural event: it carries no row, so it appends
        # with every payload column absent. The verifier guarantees the target
        # is not tenant-scoped, because a truncate is tenant-blind and there is
        # no row to resolve a tenant from.
        append!(config, resource, change, %{}, nil)

      _halt ->
        raise Error.exception(
                reason: :truncate_halt,
                resource: resource,
                op: :append,
                shape: "#{change.schema}.#{change.table}"
              )
    end
  rescue
    e -> reraise Error.scrub(e, resource, :append), __STACKTRACE__
  catch
    :throw, value -> reraise Error.scrub_caught(value, resource, :append), __STACKTRACE__
    :exit, value -> reraise Error.scrub_caught(value, resource, :append), __STACKTRACE__
  end

  def apply(config, resource, %Replicant.Change{} = change) do
    record = payload_record!(resource, change)
    {inputs, _upsert_fields} = Resolver.attrs_for_upsert(resource, record)
    tenant = Resolver.resolve_tenant!(resource, record, :append)

    append!(config, resource, change, inputs, tenant)
  rescue
    e -> reraise Error.scrub(e, resource, :append), __STACKTRACE__
  catch
    :throw, value -> reraise Error.scrub_caught(value, resource, :append), __STACKTRACE__
    :exit, value -> reraise Error.scrub_caught(value, resource, :append), __STACKTRACE__
  end

  @doc false
  @spec apply_message(
          map(),
          Replicant.Decoder.Messages.Message.t(),
          %{resource: module(), action: atom()},
          Replicant.lsn() | nil
        ) :: :ok
  def apply_message(
        config,
        %Replicant.Decoder.Messages.Message{prefix: prefix, content: content} = message,
        %{resource: resource, action: action},
        txn_commit_lsn
      )
      when is_binary(prefix) and is_binary(content) do
    if action != Info.replicant_append_action!(resource) do
      raise Error.exception(reason: :config_invalid, resource: resource, op: :append)
    end

    lsn = txn_commit_lsn || message.lsn
    ordinal = if is_integer(message.ordinal), do: message.ordinal, else: 0

    unless is_integer(lsn) and lsn >= 0 and is_integer(ordinal) and ordinal >= 0 do
      raise Error.exception(reason: :config_invalid, resource: resource, op: :append)
    end

    names = Info.append_message_attributes(resource)
    delivery = %{op: :message, commit_lsn: lsn, ordinal: ordinal}

    append!(
      config,
      resource,
      delivery,
      %{names.prefix => prefix, names.content => content},
      nil
    )
  rescue
    e -> reraise Error.scrub(e, resource, :append), __STACKTRACE__
  catch
    :throw, value ->
      reraise Error.scrub_caught(value, resource, :append), __STACKTRACE__

    :exit, value ->
      reraise Error.scrub_caught(value, resource, :append), __STACKTRACE__
  end

  def apply_message(_config, _message, %{resource: resource}, _txn_commit_lsn) do
    raise Error.exception(reason: :config_invalid, resource: resource, op: :append)
  end

  @doc false
  @spec validate_message_routes(map()) :: :ok | {:error, term()}
  def validate_message_routes(%{sink_kind: :append_log} = config) do
    config
    |> Map.get(:message_routes, [])
    |> Enum.reduce_while(:ok, fn {_prefix, resource, action}, :ok ->
      if valid_message_route?(resource, action) do
        {:cont, :ok}
      else
        {:halt, {:error, {:destination_append_message_route_invalid, resource, action}}}
      end
    end)
  rescue
    _error -> {:error, {:invalid_destination_config, :reflection_failed}}
  catch
    _kind, _reason -> {:error, {:invalid_destination_config, :reflection_failed}}
  end

  def validate_message_routes(_config), do: :ok

  defp valid_message_route?(resource, action_name) do
    names = Info.append_message_attributes(resource)
    structural_names = Info.append_attributes(resource) |> Map.values()
    action = Ash.Resource.Info.action(resource, action_name)
    prefix = Ash.Resource.Info.attribute(resource, names.prefix)
    content = Ash.Resource.Info.attribute(resource, names.content)
    accepted = List.wrap(action && Map.get(action, :accept))

    AshReplicant.Resource in Spark.extensions(resource) and
      Info.append_log?(resource) and
      valid_message_action?(resource, action_name, action) and
      valid_message_attributes?(names, prefix, content, structural_names, accepted) and
      tenant_free_resource?(resource)
  end

  defp valid_message_action?(resource, action_name, action) do
    action_name == Info.replicant_append_action!(resource) and
      is_map(action) and action.type == :create
  end

  defp valid_message_attributes?(names, prefix, content, structural_names, accepted) do
    is_map(prefix) and Ash.Type.storage_type(prefix.type, prefix.constraints) == :string and
      is_map(content) and Ash.Type.storage_type(content.type, content.constraints) == :binary and
      names.prefix != names.content and
      names.prefix not in structural_names and names.content not in structural_names and
      names.prefix in accepted and names.content in accepted
  end

  defp tenant_free_resource?(resource) do
    is_nil(Ash.Resource.Info.multitenancy_strategy(resource)) or
      Ash.Resource.Info.multitenancy_global?(resource) == true
  end

  # A DELETE's payload is the admitted OLD record (ADR-0018 §4); every other
  # shape carries the new one. An absent record is a structural fault, not an
  # empty event: appending a delete with no old row would record that something
  # was deleted without recording WHAT, and under the default replica identity
  # that is exactly the silent outcome to refuse.
  defp payload_record!(_resource, %Replicant.Change{op: :delete, old_record: old})
       when is_map(old),
       do: old

  defp payload_record!(resource, %Replicant.Change{op: :delete}) do
    raise Error.exception(reason: :sink_failed, resource: resource, op: :append)
  end

  defp payload_record!(_resource, %Replicant.Change{record: record}) when is_map(record),
    do: record

  defp payload_record!(resource, _change) do
    raise Error.exception(reason: :sink_failed, resource: resource, op: :append)
  end

  defp append!(config, resource, change, inputs, tenant) do
    action = Info.replicant_append_action!(resource)
    structural = structural_inputs(config, resource, change)

    assert_no_structural_collision!(resource, inputs, structural)

    Context.with_admitted_manifest(config, fn ->
      Context.preflight_onetime!(config, tenant, resource, action, :append)
      Context.verify_notifier_loads!(config, resource, action, :append)

      Ash.create!(resource, Map.merge(inputs, structural),
        action: action,
        upsert?: true,
        upsert_identity: Info.replicant_append_identity!(resource),
        # EMPTY on purpose — see the moduledoc. AshPostgres turns an empty upsert
        # set into a self-assignment of the conflict target, so a replay is a
        # no-op and the stored payload is immutable.
        upsert_fields: [],
        tenant: tenant,
        authorize?: config.authorize?,
        context: Context.action_context(config, change, :append),
        # The sink owns the single outer Repo.transaction this action joins; no
        # redundant per-row savepoint.
        transaction?: false,
        return_notifications?: true
      )
    end)

    :ok
  end

  # The five identity axes plus the two structural labels and the backfill
  # attempt. The identity comes from the ADMITTED session identity and the
  # change — never from a row.
  defp structural_inputs(config, resource, %{op: op, commit_lsn: lsn, ordinal: ordinal}) do
    names = Info.append_attributes(resource)

    %{
      names.source_system => config.source_identity.system_identifier,
      names.source_database => config.source_identity.database,
      names.slot_name => config.slot_name,
      names.commit_lsn => lsn,
      names.ordinal => ordinal,
      names.operation => operation!(resource, op),
      names.origin => origin(op),
      names.attempt => attempt(config, op)
    }
  end

  defp operation!(resource, op) do
    case Map.fetch(@operations, op) do
      {:ok, label} ->
        label

      :error ->
        # A framework op this release has no declared label for. Fail closed
        # rather than stamp an unreviewed vocabulary into the host's log.
        raise Error.exception(reason: :config_invalid, resource: resource, op: :append)
    end
  end

  defp origin(:snapshot), do: @snapshot_origin
  defp origin(_op), do: @stream_origin

  # The checkpoint-owned snapshot attempt (ADR-0018 §4) rides the runtime
  # config, bound under the checkpoint row lock before any row effect. Streamed
  # changes carry none.
  defp attempt(config, :snapshot), do: Map.get(config, :append_snapshot_attempt)
  defp attempt(_config, _op), do: nil

  # A source column sharing a name with a structural attribute would have its
  # value silently replaced by the structural stamp (or vice versa), so the
  # event would carry neither fact honestly. The collision is a configuration
  # defect and halts value-free — the NAMES are schema structure, so reporting
  # that one collided leaks nothing.
  defp assert_no_structural_collision!(resource, inputs, structural) do
    if Enum.any?(structural, fn {name, _value} -> Map.has_key?(inputs, name) end) do
      raise Error.exception(reason: :config_invalid, resource: resource, op: :append)
    end

    :ok
  end
end
