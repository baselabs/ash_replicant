defmodule AshReplicant.Resource.Verifiers.ValidateActionMultitenancy do
  @moduledoc """
  Compile-verifier (surfaced as a Spark diagnostic; build-blocking under
  `--warnings-as-errors`): the **sink-selected write actions** of a multitenant
  replicant resource must not declare `multitenancy :bypass` / `:bypass_all`.

  The sink mirrors through the host's PRIMARY create (upsert, and the SCD2
  version-open) and PRIMARY destroy, plus — for an SCD2 resource — the configured
  `history_close_action`. Ash's `handle_multitenancy(changeset, action)` keys on the
  action's `:multitenancy` mode:

  - `:enforce` (default) — force-sets the discriminator (or threads `:context`) AND
    requires a tenant → scoped;
  - `:allow_global` — force-sets when a tenant is present (the sink ALWAYS passes a
    resolved tenant, fail-closed on nil/`false`) → scoped;
  - `:bypass` / `:bypass_all` — neither force-sets nor requires → the tenant the sink
    passes is **silently ignored** and every tenant's rows mirror UNSCOPED into one
    table (fail-open isolation).

  So this verifier rejects only `:bypass` / `:bypass_all` on a sink-written action of a
  multitenant resource. It fires only when the resource declares multitenancy (a
  non-multitenant resource has no tenant to bypass). A non-sink action's mode is the
  host's business and is not checked. Messages are value-free — they name the action
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
      case Enum.find(sink_write_actions(dsl_state), &bypasses?/1) do
        nil -> :ok
        action -> {:error, bypass_error(action, dsl_state)}
      end
    else
      :ok
    end
  end

  defp multitenant?(dsl_state), do: not is_nil(AshInfo.multitenancy_strategy(dsl_state))

  # The actions the sink writes through: primary create (upsert + SCD2 version-open),
  # primary destroy, and (SCD2 only) the configured close action. `primary_action/2` and
  # `action/2` accept a compile-time `dsl_state`; missing actions are dropped.
  defp sink_write_actions(dsl_state) do
    [AshInfo.primary_action(dsl_state, :create), AshInfo.primary_action(dsl_state, :destroy)]
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
        "the sink-selected write action #{inspect(action.name)} declares " <>
          "`multitenancy #{inspect(action.multitenancy)}`, which makes Ash IGNORE the per-row " <>
          "tenant the sink passes — every tenant's rows would mirror UNSCOPED into one table " <>
          "(fail-open isolation). Use `:enforce` (the default) or `:allow_global` on the " <>
          "sink-written actions of a multitenant resource, so it fails closed here."
    )
  end
end
