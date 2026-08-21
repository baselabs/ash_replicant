defmodule AshReplicant.Resource.Verifiers.ValidateAppendLog do
  @moduledoc """
  Compile-verifier for `replicant do append_log true end` (surfaced as a Spark
  diagnostic; build-blocking under `--warnings-as-errors`).

  ADR-0018 makes the append target **host-owned**: this package generates no
  event table, no migration, and no raw write path. Everything delivery relies
  on therefore lives in the host's own resource, and every one of those
  obligations fails QUIETLY if it is only a convention:

  * a missing structural attribute means an append lands with a NULL axis and
    the identity stops identifying anything;
  * an identity that is not exactly the five append axes either widens the
    dedup key (a replay appends twice) or narrows it (two distinct
    same-transaction effects collide and one is lost);
  * an append action that declares its OWN upsert overrides the sink's
    conflict target, so a duplicate delivery can overwrite an already-appended
    event — the exact opposite of immutable;
  * state-mirror machinery (SCD2 windows, snapshot provenance markers,
    `on_truncate :mirror`) reaches an append target through code paths that
    UPDATE and DELETE rows a log must never modify.

  None of those raise at delivery on the happy path, so all of them are moved
  to build time here.

  When `append_log` is `true` the resource must satisfy all of:

  1. **The eight structural attributes exist** under their configured names
     (`append_source_system_attribute` … `append_attempt_attribute`), with the
     structural storage each role needs: `:string` for source system, source
     database, slot, operation and origin; `:integer` for commit LSN and
     ordinal; binary storage for the snapshot attempt. Every role except the
     stream-optional attempt is non-null.
  2. **No structural attribute is classified.** None may be `sensitive?: true`
     nor named in the `replicant` `sensitive` list — they carry library-minted
     structure, never a row value, and classifying one would misroute it
     through the encryption path.
  3. **The append action exists, is a non-manual `:create`, declares no upsert,
     and neither it nor the global `changes` block carries an arbitrary create
     change.** The
     sink supplies `upsert?: true` with the append identity as the conflict
     target and an EMPTY `upsert_fields`, which AshPostgres renders as a
     no-op conflict clause — append-once that never overwrites the stored
     payload. An action-level upsert would replace that conflict target; a
     manual action or change can replace the insert or rewrite the identity
     after input validation. AshCloak encryption is the sole admitted change.
  4. **The append action accepts every structural attribute**, or the sink's
     inputs are silently dropped.
  5. **The append identity exists and its keys are EXACTLY the five append
     axes** — source system, source database, slot, commit LSN, ordinal.
  6. **No state-mirror machinery.** `history_strategy :scd2`,
     `snapshot_provenance true`, and `on_truncate :mirror` / `:close` are
     rejected on an append target; `on_truncate :append` is rejected on a
     state mirror.
  7. **A tenant-scoped append target may not append a truncate.** A TRUNCATE is
     tenant-blind (it wipes every tenant) and carries no row to resolve a
     tenant from, so `on_truncate :append` beside a declared tenant source
     would have to write untenanted — fail closed at build time with
     `on_truncate :halt` instead.

  Messages are value-free: they name schema structure (attribute, action, and
  identity names), never a row value.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: AshInfo
  alias AshReplicant.Resource.Info
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  # Each structural role's required storage shape. `:binary` uses the same
  # `Ash.Type.storage_type/2` predicate `ValidateSensitive` uses for its binary
  # clause, so "binary-storage" means one thing across the whole extension.
  @role_storage %{
    source_system: :string,
    source_database: :string,
    slot_name: :string,
    commit_lsn: :integer,
    ordinal: :integer,
    operation: :string,
    origin: :string,
    attempt: :binary
  }

  @role_options %{
    source_system: :append_source_system_attribute,
    source_database: :append_source_database_attribute,
    slot_name: :append_slot_attribute,
    commit_lsn: :append_commit_lsn_attribute,
    ordinal: :append_ordinal_attribute,
    operation: :append_operation_attribute,
    origin: :append_origin_attribute,
    attempt: :append_attempt_attribute
  }

  # Deterministic report order: a resource missing several roles must name the
  # same one on every build, or the red gate reads as flaky.
  @role_order [
    :source_system,
    :source_database,
    :slot_name,
    :commit_lsn,
    :ordinal,
    :operation,
    :origin,
    :attempt
  ]

  @mirror_truncate_policies [:mirror, :close]

  @impl true
  def verify(dsl_state) do
    if Verifier.get_option(dsl_state, [:replicant], :append_log) == true do
      verify_append_target(dsl_state)
    else
      verify_state_mirror(dsl_state)
    end
  end

  # The only append clause that binds a STATE-MIRROR resource: `on_truncate
  # :append` has no meaning without an append target, and silently treating it
  # as `:halt` would hide a misconfigured truncate policy.
  defp verify_state_mirror(dsl_state) do
    if Verifier.get_option(dsl_state, [:replicant], :on_truncate) == :append do
      truncate_error(
        dsl_state,
        "`on_truncate :append` is an APPEND-LOG policy, but this resource is a state " <>
          "mirror (`append_log` is false). Use `:halt`, `:mirror`, or `:close`, or " <>
          "declare `append_log true`."
      )
    else
      :ok
    end
  end

  defp verify_append_target(dsl_state) do
    Enum.reduce_while(
      [
        # Structure first: every later clause reads the structural attribute
        # names, and reporting "your identity is wrong" for a resource that is
        # missing the column entirely would name the wrong defect.
        &verify_attributes/1,
        &verify_no_state_mirror_machinery/1,
        &verify_truncate_policy/1,
        &verify_append_action/1,
        &verify_append_identity/1
      ],
      :ok,
      fn check, :ok ->
        case check.(dsl_state) do
          :ok -> {:cont, :ok}
          {:error, _error} = failure -> {:halt, failure}
        end
      end
    )
  end

  # --- 1-2: the structural attributes ---

  defp verify_attributes(dsl_state) do
    names = role_names(dsl_state)
    by_name = Map.new(Verifier.get_entities(dsl_state, [:attributes]), &{&1.name, &1})
    classified = Verifier.get_option(dsl_state, [:replicant], :sensitive, [])

    @role_order
    |> Enum.find_value(fn role ->
      name = Map.fetch!(names, role)

      case attribute_problem(role, name, Map.get(by_name, name), classified) do
        nil -> nil
        message -> {role, message}
      end
    end)
    |> case do
      nil -> :ok
      {role, message} -> role_error(dsl_state, role, message)
    end
  end

  defp attribute_problem(role, name, nil, _classified) do
    "must declare the #{role_label(role)} attribute #{inspect(name)} — the append " <>
      "identity and the operation shapes are stamped onto it on every appended event " <>
      "(expected storage: #{inspect(Map.fetch!(@role_storage, role))})"
  end

  defp attribute_problem(role, name, attribute, classified) do
    expected = Map.fetch!(@role_storage, role)

    cond do
      Ash.Type.storage_type(attribute.type, attribute.constraints) != expected ->
        "the #{role_label(role)} attribute #{inspect(name)} must store as " <>
          "#{inspect(expected)} (its declared type does not), because the sink stamps a " <>
          "#{storage_description(expected)} onto it"

      role != :attempt and Map.get(attribute, :allow_nil?, true) != false ->
        "the #{role_label(role)} attribute #{inspect(name)} must declare " <>
          "`allow_nil? false`. A NULL structural axis defeats the append identity's " <>
          "unique constraint in PostgreSQL and can silently admit the same WAL event " <>
          "more than once"

      attribute.sensitive? ->
        "the #{role_label(role)} attribute #{inspect(name)} must not be " <>
          "`sensitive?: true` — it carries a library-minted structural value, never a " <>
          "row value, and classifying it misroutes structure through the encryption path"

      name in classified ->
        "the #{role_label(role)} attribute #{inspect(name)} must not be listed in the " <>
          "`replicant` `sensitive` option — it carries a library-minted structural " <>
          "value, never a row value"

      true ->
        nil
    end
  end

  defp storage_description(:string), do: "structural label"
  defp storage_description(:integer), do: "source LSN or ordinal"
  defp storage_description(:binary), do: "checkpoint-owned attempt id"

  # --- 6: no state-mirror machinery on an append target ---

  defp verify_no_state_mirror_machinery(dsl_state) do
    cond do
      Verifier.get_option(dsl_state, [:replicant], :history_strategy) == :scd2 ->
        dsl_error(
          dsl_state,
          [:replicant, :history_strategy],
          "`history_strategy :scd2` is a STATE-MIRROR strategy and cannot be combined " <>
            "with `append_log true`. SCD2 closes an open version with an UPDATE; an " <>
            "append log never modifies a stored event. Model history as the append " <>
            "sequence itself."
        )

      Verifier.get_option(dsl_state, [:replicant], :snapshot_provenance) == true ->
        dsl_error(
          dsl_state,
          [:replicant, :snapshot_provenance],
          "`snapshot_provenance true` is a STATE-MIRROR mechanism and cannot be combined " <>
            "with `append_log true`. Provenance exists to retire mirror rows the source " <>
            "dropped, which an append log must never do; backfill rows carry the " <>
            "checkpoint-owned attempt on `append_attempt_attribute` instead (ADR-0018 §4)."
        )

      true ->
        :ok
    end
  end

  # --- 6-7: the truncate policy ---

  defp verify_truncate_policy(dsl_state) do
    policy = Verifier.get_option(dsl_state, [:replicant], :on_truncate)

    cond do
      policy in @mirror_truncate_policies ->
        truncate_error(
          dsl_state,
          "`on_truncate #{inspect(policy)}` is a STATE-MIRROR policy: it DELETEs or " <>
            "closes stored rows, which an append log must never do. An append target " <>
            "admits only `:halt` (default, fail-closed) or `:append` (record the " <>
            "structural truncate event)."
        )

      policy == :append and tenant_scoped?(dsl_state) ->
        truncate_error(
          dsl_state,
          "`on_truncate :append` cannot be combined with a declared tenant source. A " <>
            "TRUNCATE is tenant-blind — it wipes every tenant and carries no row to " <>
            "resolve a tenant from — so the structural event would have to be appended " <>
            "untenanted, spanning tenants. Use `on_truncate :halt` and let an operator " <>
            "decide."
        )

      true ->
        :ok
    end
  end

  defp tenant_scoped?(dsl_state) do
    Verifier.get_option(dsl_state, [:replicant], :tenant_attribute) != nil or
      Verifier.get_option(dsl_state, [:replicant], :tenant_mfa) != nil
  end

  # --- 3-4: the immutable create action ---

  defp verify_append_action(dsl_state) do
    name = Verifier.get_option(dsl_state, [:replicant], :append_action)
    action = dsl_state |> Verifier.get_entities([:actions]) |> Enum.find(&(&1.name == name))

    case append_action_problem(dsl_state, name, action) do
      nil -> :ok
      {path, message} -> dsl_error(dsl_state, path, message)
    end
  end

  defp append_action_problem(_dsl_state, name, nil) do
    {[:replicant, :append_action],
     "must declare the append action #{inspect(name)} — a `:create` action accepting the " <>
       "structural attributes plus the mapped payload. It is the ONLY delivery path onto " <>
       "an append target; update, upsert, and destroy actions never are."}
  end

  defp append_action_problem(dsl_state, name, %{type: type}) when type != :create do
    _ = dsl_state

    {[:replicant, :append_action],
     "the append action #{inspect(name)} must be a `:create` action, but it is declared " <>
       "as #{inspect(type)}. An append log only ever inserts."}
  end

  defp append_action_problem(dsl_state, name, action) do
    accepted = List.wrap(Map.get(action, :accept))
    structural_names = Map.values(role_names(dsl_state))
    global_create_changes = AshInfo.changes(dsl_state, :create)

    missing =
      @role_order
      |> Enum.map(&Map.fetch!(role_names(dsl_state), &1))
      |> Enum.reject(&(&1 in accepted))

    cond do
      Map.get(action, :upsert?) == true ->
        {[:actions, name, :upsert?],
         "the append action #{inspect(name)} must not declare its own upsert. The sink " <>
           "supplies `upsert?: true` with the append identity as the conflict target and " <>
           "an EMPTY `upsert_fields`, which appends once and never overwrites a stored " <>
           "event; an action-level upsert replaces that conflict target and can make a " <>
           "duplicate delivery mutate an already-appended row."}

      Map.get(action, :manual) != nil ->
        {[:actions, name, :manual],
         "the append action #{inspect(name)} must not be manual. A manual action can " <>
           "replace the admitted AshPostgres insert and escape the append identity's " <>
           "atomic conflict boundary."}

      not append_changes_safe?(global_create_changes, structural_names) ->
        {[:changes],
         "the global `changes` block must not declare changes that run on create. A " <>
           "global create change also runs inside the append action after input admission " <>
           "and can rewrite an append identity axis so distinct WAL events collide and one " <>
           "is silently lost. AshCloak field encryption of non-structural payload is the " <>
           "only admitted global create change."}

      not append_changes_safe?(
        Map.get(action, :changes, []),
        structural_names
      ) ->
        {[:actions, name, :changes],
         "the append action #{inspect(name)} must not declare mutating action changes. " <>
           "A change runs after input admission and can rewrite an identity axis so two " <>
           "distinct WAL events collide and one is silently lost. AshCloak's field " <>
           "encryption change is the only admitted change because it preserves the " <>
           "structural identity and is required for classified payloads."}

      missing != [] ->
        {[:actions, name, :accept],
         "the append action #{inspect(name)} must accept every structural attribute; it " <>
           "does not accept #{inspect(missing)}. An unaccepted structural input is " <>
           "silently dropped, leaving the appended event without its identity axis."}

      true ->
        nil
    end
  end

  # The host action is part of the event identity boundary, so arbitrary Ash
  # changes cannot be trusted merely because the action accepts the right
  # inputs. AshCloak's generated encrypt change is the sole exception: the
  # sensitive verifier proves its field is payload, never one of the structural
  # axes, and encryption must run inside the Ash action.
  defp append_changes_safe?(changes, structural_names) do
    Enum.all?(List.wrap(changes), fn
      %{change: {AshCloak.Changes.Encrypt, opts}} when is_list(opts) ->
        field = Keyword.get(opts, :field)
        is_atom(field) and field not in structural_names

      _other ->
        false
    end)
  end

  # --- 5: the append identity is EXACTLY the five axes ---

  defp verify_append_identity(dsl_state) do
    name = Verifier.get_option(dsl_state, [:replicant], :append_identity)
    identity = dsl_state |> Verifier.get_entities([:identities]) |> Enum.find(&(&1.name == name))

    names = role_names(dsl_state)
    expected = Enum.map(Info.append_identity_roles(), &Map.fetch!(names, &1))

    case identity do
      nil ->
        identity_error(
          dsl_state,
          "must declare the append identity #{inspect(name)} over exactly " <>
            "#{inspect(expected)} — the defensive database constraint behind append-once. " <>
            "Without it a duplicate delivery has no conflict target and appends twice."
        )

      %{keys: keys} = identity ->
        cond do
          Enum.sort(List.wrap(keys)) != Enum.sort(expected) ->
            identity_error(
              dsl_state,
              "the append identity #{inspect(name)} must have EXACTLY the five append axes " <>
                "#{inspect(expected)}, but it declares #{inspect(List.wrap(keys))}. A " <>
                "narrower identity makes two distinct same-transaction effects collide so " <>
                "one is lost; a wider one lets a replayed delivery append the same event " <>
                "twice (ADR-0018 §3)."
            )

          attribute_multitenant?(dsl_state) and Map.get(identity, :all_tenants?) != true ->
            identity_error(
              dsl_state,
              "the append identity #{inspect(name)} must declare `all_tenants? true` on an " <>
                "attribute-multitenant append target. Ash otherwise PREPENDS the tenant " <>
                "discriminator to the upsert conflict target, which widens the append " <>
                "identity past its five axes and no longer matches the five-column unique " <>
                "index. One WAL ordinal is one event belonging to one tenant, so the append " <>
                "identity is global by construction."
            )

          true ->
            :ok
        end
    end
  end

  defp attribute_multitenant?(dsl_state) do
    Verifier.get_option(dsl_state, [:multitenancy], :strategy) == :attribute
  end

  # --- shared ---

  defp role_names(dsl_state), do: Info.append_attributes(dsl_state)

  defp role_label(:source_system), do: "source-system"
  defp role_label(:source_database), do: "source-database"
  defp role_label(:slot_name), do: "slot-name"
  defp role_label(:commit_lsn), do: "commit-LSN"
  defp role_label(:ordinal), do: "ordinal"
  defp role_label(:operation), do: "operation"
  defp role_label(:origin), do: "origin"
  defp role_label(:attempt), do: "snapshot-attempt"

  defp role_error(dsl_state, role, message),
    do: dsl_error(dsl_state, [:replicant, Map.fetch!(@role_options, role)], message)

  defp truncate_error(dsl_state, message),
    do: dsl_error(dsl_state, [:replicant, :on_truncate], message)

  defp identity_error(dsl_state, message),
    do: dsl_error(dsl_state, [:replicant, :append_identity], message)

  defp dsl_error(dsl_state, path, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: path,
       message: message
     )}
  end
end
