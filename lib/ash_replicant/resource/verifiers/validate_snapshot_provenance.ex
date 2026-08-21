defmodule AshReplicant.Resource.Verifiers.ValidateSnapshotProvenance do
  @moduledoc """
  Compile-verifier for `replicant do snapshot_provenance true end` (surfaced as
  a Spark diagnostic; build-blocking under `--warnings-as-errors`).

  ADR-0017 makes provenance a *contract*, not a convention: a snapshot retry
  decides whether to re-run a host business action by comparing a stored
  fingerprint, and it decides what to retire by reading a stored attempt
  marker. If either value can be written by anyone but this package, both
  decisions can be forged — silently, with no failing test on the host side,
  because a forged marker just makes a row look "already seen". That is the
  quiet failure this verifier exists to move to build time.

  When `snapshot_provenance` is `true` the resource must satisfy all of:

  1. **The two protected attributes exist** — `replica_fingerprint` and
     `replica_seen_attempt`.
  2. **Each is binary-storage** (`Ash.Type.storage_type/2` is `:binary`), the
     same predicate `ValidateSensitive` uses for its binary clause.
  3. **Each is `public?: false`**, `writable?: false`, and NOT
     `sensitive?: true`; and neither is named in the `replicant` `sensitive`
     list. They are internal metadata carrying no row value, so classifying
     them would misroute them through the encryption path.
  4. **No action accepts either one.** `accept :*` already excludes them
     (Ash expands `:*` to attributes that are public AND writable —
     `Ash.Resource.Transformers.DefaultAccept`), but an EXPLICIT accept list is
     passed through verbatim, so that is the real forgery path and this clause
     closes it. Verifiers run after transformers, so the check reads the
     post-expansion list and would also catch a future change to `:*`.
  5. **No action declares an argument named for either one** — an argument is
     an action input path just as much as an accept entry.
  6. **The mark change has one owner.** `AshReplicant.Snapshot.MarkSeen` may
     appear only on the configured mark action — never as a global change or on
     another public or private action. The mark action (`snapshot_mark_action`,
     default `:replicant_mark_seen`) exists, is an `:update`, is `public? false`,
     and carries the change **on the action itself**. A global change would also
     stamp the host's ordinary business updates; another action would create a
     second, host-callable provenance path. A mark action that does not stamp is
     vacuous, and a vacuous mark makes completion retire rows it just saw.
  7. **The retire action** (`snapshot_retire_action`, default
     `:replicant_retire_unseen`) exists, is `public? false`, and is a
     `:destroy` under `history_strategy :scd1` or an `:update` under `:scd2`
     — SCD2 retirement closes the open version, because closed history is
     immutable.
  8. **A non-global `strategy :context` resource declares a retained-scope
     enumerator** (`snapshot_tenant_scope_action`): a private generic action
     returning `{:array, _}`. Completion retires per tenant scope and never
     tenant-blind; attribute multitenancy enumerates itself from its
     discriminator column, but context multitenancy has none, so the host is
     the only authority on which scopes exist — including one wholly absent
     from the source attempt.

  Tenant scoping for both actions is enforced by
  `AshReplicant.Resource.Verifiers.ValidateActionMultitenancy`, which treats
  them as sink-selected actions rather than repeating the bypass check here.

  Messages are value-free: they name schema structure (attribute and action
  names), never a row value.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: AshInfo
  alias AshReplicant.Snapshot.MarkSeen
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @fingerprint :replica_fingerprint
  @attempt :replica_seen_attempt
  @protected [@fingerprint, @attempt]

  @impl true
  def verify(dsl_state) do
    if Verifier.get_option(dsl_state, [:replicant], :snapshot_provenance) == true and
         Verifier.get_option(dsl_state, [:replicant], :append_log) != true do
      do_verify(dsl_state)
    else
      # An APPEND target combined with `snapshot_provenance true` is rejected
      # outright by `ValidateAppendLog` (ADR-0018 §4: an append log never
      # retires a row, and backfill rows carry the checkpoint-owned attempt on
      # their own structural column). Reporting the provenance contract's
      # missing attributes on top of that would bury the real diagnostic under
      # a demand for machinery the host must not declare.
      :ok
    end
  end

  defp do_verify(dsl_state) do
    Enum.reduce_while(
      # The action-input check runs FIRST: it is the forgery path, and it is the
      # one clause with a case Ash does not independently cover. Ash's own
      # `DefaultAccept` rejects accepting a NON-writable attribute, but a
      # `writable?: true, public?: false` attribute IS acceptable to it (probed
      # against Ash 3.31.3) — so this clause, not Ash, is what closes that
      # shape, and reporting it before the writability tells the host what
      # actually went wrong.
      [
        &verify_no_action_input/1,
        &verify_mark_change_ownership/1,
        &verify_attributes/1,
        &verify_mark_action/1,
        &verify_retire_action/1,
        &verify_tenant_scope_action/1
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

  # --- 1-3: the protected attributes ---

  defp verify_attributes(dsl_state) do
    by_name = Map.new(Verifier.get_entities(dsl_state, [:attributes]), &{&1.name, &1})
    classified = Verifier.get_option(dsl_state, [:replicant], :sensitive, [])

    @protected
    |> Enum.find_value(fn name -> attribute_problem(name, Map.get(by_name, name), classified) end)
    |> case do
      nil -> :ok
      message -> {:error, provenance_error(dsl_state, message)}
    end
  end

  defp attribute_problem(name, nil, _classified) do
    "must declare the protected attribute #{inspect(name)} as " <>
      "`attribute #{inspect(name)}, :binary, public?: false, writable?: false` — " <>
      "the snapshot provenance contract stores it on every managed row"
  end

  defp attribute_problem(name, attribute, classified) do
    cond do
      Ash.Type.storage_type(attribute.type, attribute.constraints) != :binary ->
        "the protected attribute #{inspect(name)} must be binary-storage " <>
          "(its declared type does not store as `:binary`), because the fingerprint " <>
          "and attempt marker are opaque bytes"

      attribute.public? ->
        "the protected attribute #{inspect(name)} must be `public?: false` — a public " <>
          "provenance attribute is reachable as action input and lets a host forge " <>
          "snapshot membership"

      attribute.writable? ->
        "the protected attribute #{inspect(name)} must be `writable?: false` — only " <>
          "#{inspect(MarkSeen)} may write it, through " <>
          "`Ash.Changeset.force_change_attribute/3`"

      attribute.sensitive? ->
        "the protected attribute #{inspect(name)} must not be `sensitive?: true` — it " <>
          "carries no row value, and classifying it misroutes internal metadata through " <>
          "the encryption path"

      name in classified ->
        "the protected attribute #{inspect(name)} must not be listed in the `replicant` " <>
          "`sensitive` option — it carries no row value, only a keyed digest and an " <>
          "attempt marker"

      true ->
        nil
    end
  end

  # --- 4-5: no action input path ---

  defp verify_no_action_input(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:actions])
    |> Enum.find_value(&action_input_problem/1)
    |> case do
      nil ->
        :ok

      {action_name, path, message} ->
        {:error, action_error(dsl_state, action_name, path, message)}
    end
  end

  defp action_input_problem(action) do
    accepted = Enum.find(@protected, &(&1 in List.wrap(Map.get(action, :accept))))
    argued = Enum.find(@protected, fn name -> name in argument_names(action) end)

    cond do
      accepted ->
        {action.name, :accept,
         "the action #{inspect(action.name)} accepts #{inspect(accepted)}, which lets any " <>
           "caller forge snapshot provenance. No action may accept a protected provenance " <>
           "attribute — #{inspect(MarkSeen)} stamps them from the sink-supplied changeset " <>
           "context instead."}

      argued ->
        {action.name, :arguments,
         "the action #{inspect(action.name)} declares an argument named #{inspect(argued)}. " <>
           "An argument is an action input path, so it can carry a forged provenance value " <>
           "into a change; name the argument something else."}

      true ->
        nil
    end
  end

  defp argument_names(action), do: action |> Map.get(:arguments, []) |> Enum.map(& &1.name)

  # --- 6: the mark change has exactly one action owner ---

  defp verify_mark_change_ownership(dsl_state) do
    mark_action = Verifier.get_option(dsl_state, [:replicant], :snapshot_mark_action)

    other_action =
      dsl_state
      |> Verifier.get_entities([:actions])
      |> Enum.find(fn action ->
        action.name != mark_action and carries_mark_change?(action)
      end)

    cond do
      Enum.any?(AshInfo.changes(dsl_state), &mark_change?/1) ->
        {:error,
         dsl_error(
           dsl_state,
           [:changes],
           "the global `changes` block carries `change #{inspect(MarkSeen)}`. Only the " <>
             "configured private mark action #{inspect(mark_action)} may carry that change; " <>
             "a global change also stamps ordinary host business updates"
         )}

      other_action ->
        {:error,
         action_error(
           dsl_state,
           other_action.name,
           :changes,
           "the action #{inspect(other_action.name)} carries `change #{inspect(MarkSeen)}`. " <>
             "Only the configured private mark action #{inspect(mark_action)} may carry that " <>
             "change; another action creates a forgeable provenance-write path"
         )}

      true ->
        :ok
    end
  end

  # --- 6: the configured mark action ---

  defp verify_mark_action(dsl_state) do
    name = Verifier.get_option(dsl_state, [:replicant], :snapshot_mark_action)
    action = name && AshInfo.action(dsl_state, name)

    cond do
      is_nil(action) ->
        mark_error(
          dsl_state,
          "must declare the private mark action #{inspect(name)} (an `:update` carrying " <>
            "`change #{inspect(MarkSeen)}`) — the snapshot retry marks an unchanged row seen " <>
            "instead of re-running the host business action"
        )

      action.type != :update ->
        mark_error(
          dsl_state,
          "the mark action #{inspect(name)} must be an `:update` action (it stamps membership " <>
            "onto an existing row), got #{inspect(action.type)}"
        )

      action.public? ->
        mark_error(
          dsl_state,
          "the mark action #{inspect(name)} must be private (`public? false`) — only the sink " <>
            "may mark a row seen"
        )

      not carries_mark_change?(action) ->
        mark_error(
          dsl_state,
          "the mark action #{inspect(name)} must carry `change #{inspect(MarkSeen)}` on the " <>
            "ACTION itself. Without it the action stamps nothing and completion retires rows " <>
            "the attempt just saw; a global `changes` entry does not count, because it would " <>
            "also stamp the host's ordinary business updates"
        )

      true ->
        :ok
    end
  end

  defp carries_mark_change?(action) do
    action
    |> Map.get(:changes, [])
    |> Enum.any?(&mark_change?/1)
  end

  defp mark_change?(%{change: {MarkSeen, _opts}}), do: true
  defp mark_change?(%{change: MarkSeen}), do: true
  defp mark_change?(_other), do: false

  # --- 7: the retire action ---

  defp verify_retire_action(dsl_state) do
    name = Verifier.get_option(dsl_state, [:replicant], :snapshot_retire_action)
    action = name && AshInfo.action(dsl_state, name)
    scd2? = Verifier.get_option(dsl_state, [:replicant], :history_strategy) == :scd2
    expected = if scd2?, do: :update, else: :destroy

    cond do
      is_nil(action) ->
        retire_error(
          dsl_state,
          "must declare the private retirement action #{inspect(name)} (a " <>
            "#{inspect(expected)} action) — completion retires only the managed rows a " <>
            "completed attempt did not see"
        )

      action.public? ->
        retire_error(
          dsl_state,
          "the retirement action #{inspect(name)} must be private (`public? false`) — only " <>
            "the sink may retire an unseen row"
        )

      action.type != expected ->
        retire_error(dsl_state, retire_type_message(name, expected, action.type, scd2?))

      true ->
        :ok
    end
  end

  defp retire_type_message(name, expected, actual, true = _scd2?) do
    "the retirement action #{inspect(name)} must be an #{inspect(expected)} action under " <>
      "`history_strategy :scd2` — SCD2 retirement CLOSES the open version through the host " <>
      "close action and never deletes history, got #{inspect(actual)}"
  end

  defp retire_type_message(name, expected, actual, false = _scd2?) do
    "the retirement action #{inspect(name)} must be a #{inspect(expected)} action under " <>
      "`history_strategy :scd1` (the current-state mirror retires by destroying the row), " <>
      "got #{inspect(actual)}"
  end

  # --- 8: the context-tenant retained-scope enumerator (S02) ---

  # Completion retires PER SCOPE and never tenant-blind. Attribute multitenancy
  # enumerates itself — the discriminator is a column, so `SELECT DISTINCT` over
  # the admitted Repo is authoritative. Context multitenancy has no such column:
  # the retained scopes live wherever the host keeps them (a registry table, the
  # schema catalog, a config), so the host must name the action that reports
  # them. Without it completion could only retire the scopes the SOURCE attempt
  # happened to mention, silently leaving a destination-only tenant's stale rows
  # open forever.
  defp verify_tenant_scope_action(dsl_state) do
    if context_scoped?(dsl_state) do
      name = Verifier.get_option(dsl_state, [:replicant], :snapshot_tenant_scope_action)
      scope_action_problem(dsl_state, name, name && AshInfo.action(dsl_state, name))
    else
      :ok
    end
  end

  # `global?` resources take one scoped pass, so they need no enumeration.
  defp context_scoped?(dsl_state) do
    AshInfo.multitenancy_strategy(dsl_state) == :context and
      AshInfo.multitenancy_global?(dsl_state) != true
  end

  defp scope_action_problem(dsl_state, nil, _action) do
    scope_error(
      dsl_state,
      "declares `strategy :context` multitenancy, so it must also declare " <>
        "`snapshot_tenant_scope_action` — a private generic action returning the array of " <>
        "retained tenant contexts. Completion has to enumerate every destination scope, and " <>
        "context multitenancy carries no discriminator column to enumerate from"
    )
  end

  defp scope_action_problem(dsl_state, name, nil) do
    scope_error(
      dsl_state,
      "names #{inspect(name)} as the retained-scope enumerator, but the resource declares no " <>
        "such action"
    )
  end

  defp scope_action_problem(dsl_state, name, action) do
    cond do
      action.type != :action ->
        scope_error(
          dsl_state,
          "the retained-scope enumerator #{inspect(name)} must be a generic action returning " <>
            "`{:array, _}` (a read action returns mirror RECORDS, and a context-multitenant " <>
            "read cannot span tenants to enumerate them), got #{inspect(action.type)}"
        )

      not array_return?(Map.get(action, :returns)) ->
        scope_error(
          dsl_state,
          "the retained-scope enumerator #{inspect(name)} must be a generic action declaring " <>
            "`{:array, _}` as its return type — completion reads the list of retained tenant " <>
            "contexts from it"
        )

      action.public? ->
        scope_error(
          dsl_state,
          "the retained-scope enumerator #{inspect(name)} must be private (`public? false`) — " <>
            "it is a sink-driven admission read, not a host API surface"
        )

      true ->
        :ok
    end
  end

  defp array_return?({:array, _inner}), do: true
  defp array_return?(_other), do: false

  # --- errors ---

  defp scope_error(dsl_state, message) do
    {:error, dsl_error(dsl_state, [:replicant, :snapshot_tenant_scope_action], message)}
  end

  defp provenance_error(dsl_state, message) do
    dsl_error(dsl_state, [:replicant, :snapshot_provenance], message)
  end

  defp mark_error(dsl_state, message) do
    {:error, dsl_error(dsl_state, [:replicant, :snapshot_mark_action], message)}
  end

  defp retire_error(dsl_state, message) do
    {:error, dsl_error(dsl_state, [:replicant, :snapshot_retire_action], message)}
  end

  defp action_error(dsl_state, action_name, key, message) do
    dsl_error(dsl_state, [:actions, action_name, key], message)
  end

  defp dsl_error(dsl_state, path, message) do
    DslError.exception(
      module: Verifier.get_persisted(dsl_state, :module),
      path: path,
      message: message
    )
  end
end
