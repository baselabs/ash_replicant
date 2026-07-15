defmodule AshReplicant.Resource.Verifiers.ValidateActionMultitenancy do
  @moduledoc """
  Compile-verifier (surfaced as a Spark diagnostic; build-blocking under
  `--warnings-as-errors`): the **sink-selected actions** of a multitenant replicant
  resource must not declare `multitenancy :bypass` / `:bypass_all`.

  The sink mirrors through the host's PRIMARY create (upsert, and the SCD2 version-open),
  PRIMARY destroy, and — for an SCD2 resource — the configured `history_close_action`.
  It also READS through the PRIMARY read: the SCD2 close (`Ash.bulk_update`) and mirror
  delete (`Ash.bulk_destroy`) build an `Ash.Query.do_filter` over the primary read to
  match the rows they update/delete, and under the stream strategy that read must be
  tenant-scoped. Ash keys the tenant scoping on each action's `:multitenancy` mode:

  - `:enforce` (default) — force-sets/filters the discriminator AND requires a tenant → scoped;
  - `:allow_global` — force-sets/filters when a tenant is present (the sink ALWAYS passes a
    resolved tenant, fail-closed on nil/`false`) → scoped;
  - `:bypass` / `:bypass_all` — neither scopes nor requires → the tenant the sink passes is
    **silently ignored** and the write/read spans tenants (fail-open isolation). On a read this
    lets a `bulk_update`/`bulk_destroy` match and mutate ANOTHER tenant's rows.

  So this verifier rejects `:bypass` / `:bypass_all` on any sink-selected action (primary
  read/create/destroy + SCD2 close) of a multitenant resource. It fires only when the resource
  declares multitenancy (a non-multitenant resource has no tenant to bypass). A non-sink action's
  mode is the host's business and is not checked. Messages are value-free — they name the action
  and its declared mode, never a row value.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: AshInfo
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @bypass_modes [:bypass, :bypass_all]

  @impl true
  def verify(dsl_state) do
    if multitenant?(dsl_state) do
      case Enum.find(sink_actions(dsl_state), &bypasses?/1) do
        nil -> :ok
        action -> {:error, bypass_error(action, dsl_state)}
      end
    else
      :ok
    end
  end

  defp multitenant?(dsl_state), do: not is_nil(AshInfo.multitenancy_strategy(dsl_state))

  # The actions the sink drives: the primary READ (the `bulk_update`/`bulk_destroy` row match),
  # primary create (upsert + SCD2 version-open), primary destroy, and (SCD2 only) the configured
  # close action. `primary_action/2` and `action/2` accept a compile-time `dsl_state`; missing
  # actions are dropped.
  defp sink_actions(dsl_state) do
    [
      AshInfo.primary_action(dsl_state, :read),
      AshInfo.primary_action(dsl_state, :create),
      AshInfo.primary_action(dsl_state, :destroy)
    ]
    |> maybe_add_close_action(dsl_state)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_add_close_action(actions, dsl_state) do
    if Verifier.get_option(dsl_state, [:replicant], :history_strategy) == :scd2 do
      close = Verifier.get_option(dsl_state, [:replicant], :history_close_action)
      [close && AshInfo.action(dsl_state, close) | actions]
    else
      actions
    end
  end

  defp bypasses?(action), do: action.multitenancy in @bypass_modes

  defp bypass_error(action, dsl_state) do
    DslError.exception(
      module: Verifier.get_persisted(dsl_state, :module),
      path: [:actions, action.name],
      message:
        "the sink-selected action #{inspect(action.name)} declares " <>
          "`multitenancy #{inspect(action.multitenancy)}`, which makes Ash IGNORE the per-row " <>
          "tenant the sink passes — the mirror write (or a `bulk_update`/`bulk_destroy` row match) " <>
          "would span tenants UNSCOPED (fail-open isolation). Use `:enforce` (the default) or " <>
          "`:allow_global` on the sink-selected actions of a multitenant resource, so it fails " <>
          "closed here."
    )
  end
end
