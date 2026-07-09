defmodule AshReplicant.Resource.Verifiers.ValidateTenantSource do
  @moduledoc """
  Compile-verifier (surfaced as a Spark diagnostic; build-blocking under
  `--warnings-as-errors`): a resource that declares **non-global Ash multitenancy**
  must declare a `replicant` tenant source — `tenant_attribute` or `tenant_mfa`.

  This is the CONVERSE of `ValidateMultitenancy` (which checks the *shape* of a
  declared discriminator). The sink resolves the per-row tenant from the source
  record via one of those keys; with neither,
  `AshReplicant.Resolver.resolve_tenant/2` yields `{:ok, nil}` and the mirror write
  is attempted with `tenant: nil`. For a non-`global?` multitenant resource Ash then
  raises `TenantRequired` at RUNTIME — so it is fail-closed, never a cross-tenant
  leak, but the pipeline halts on every row of that resource. This gate moves the
  failure to COMPILE time, matching the project's fail-closed-at-compile-time posture
  (`ValidateMultitenancy`, `ValidateSensitive`).

  Exempt: a `global?` resource (tenant is optional) and a non-multitenant resource.
  The message is value-free — it names schema structure only, never a row value.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: AshInfo
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    if non_global_multitenant?(dsl_state) and not tenant_source?(dsl_state) do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [:replicant],
         message:
           "this resource declares non-global Ash multitenancy but no `replicant` tenant " <>
             "source: declare a `tenant_attribute` or `tenant_mfa` so the sink can resolve the " <>
             "per-row tenant. Without one, every mirror write is attempted with `tenant: nil` " <>
             "and halts fail-closed (`:tenant_required`), so it fails closed here at compile time."
       )}
    else
      :ok
    end
  end

  # `multitenancy_strategy/1` is `nil` unless a `multitenancy` section is present;
  # `multitenancy_global?/1` is the section's `global?` (default `false`). Both accept
  # a compile-time `dsl_state`.
  defp non_global_multitenant?(dsl_state) do
    not is_nil(AshInfo.multitenancy_strategy(dsl_state)) and
      AshInfo.multitenancy_global?(dsl_state) != true
  end

  defp tenant_source?(dsl_state) do
    not is_nil(Verifier.get_option(dsl_state, [:replicant], :tenant_attribute)) or
      not is_nil(Verifier.get_option(dsl_state, [:replicant], :tenant_mfa))
  end
end
