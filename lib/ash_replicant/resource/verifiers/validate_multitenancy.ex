defmodule AshReplicant.Resource.Verifiers.ValidateMultitenancy do
  @moduledoc """
  Compile-verifier for the `replicant` tenant sources (surfaced as a Spark
  diagnostic; build-blocking under `--warnings-as-errors`). Two arms.

  ## `tenant_attribute`

  When a `tenant_attribute` is set it is the per-row tenant discriminator Ash
  injects as a plaintext filter and force-set. It fails closed unless it is:

  - **not** classified `sensitive` — an encrypted discriminator would match
    nothing (fail-open isolation), and `ash_replicant` holds no key material;
  - **not** listed in `skip` — a skipped discriminator is never written, so the
    tenant filter matches nothing (fail-open isolation);
  - a **declared** attribute — an undeclared discriminator cannot be resolved or
    force-set;
  - **not** binary-storage-typed — the discriminator is a plaintext comparator;
    a tag/base64 discriminator would scope inconsistently; and
  - backed by an Ash **`multitenancy`** block — the sink passes the resolved
    per-row tenant to Ash as the `tenant:` option, which Ash HONORS only under
    declared multitenancy. With no `multitenancy` block, `tenant:` is silently
    ignored and every tenant's rows are mirrored UNSCOPED (fail-open isolation).

  ## `tenant_mfa`

  An mfa-resolved tenant is passed to Ash as the same `tenant:` option, so it has
  the **identical** "no `multitenancy` block ⇒ `tenant:` ignored ⇒ every tenant
  mirrored unscoped" fail-open. This arm requires an Ash `multitenancy` block when
  `tenant_mfa` is declared — any strategy satisfies (both `:attribute` and
  `:context` honor `tenant:`; `:context` is the typical mfa pairing, since the mfa
  value is a computed function result, not a stored attribute). The shape checks
  above do not apply to the mfa arm — the tenant is a function result, not a
  declared column.

  ## Multitenancy block `:attribute` shape

  Independent of the tenant source, when the resource declares `strategy :attribute`
  the multitenancy block's OWN `attribute` is force-set to the plaintext tenant on
  write and filtered on read. It must be a plaintext, non-sensitive comparator — a
  `sensitive`-classified or binary-storage-typed discriminator would store/compare a
  mismatched value and **silently mis-scope** (reads return empty). This runs for both
  tenant sources (and a global `:attribute` resource). An AshCloak-encrypted attribute
  is already rejected by Ash's own multitenancy verifier (the cloak transform removes
  the plain attribute), so it is not re-checked here.

  Messages are value-free: they name schema structure (the attribute name or the
  `tenant_mfa` key), never a row value or the mfa target's arguments.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: AshInfo
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    with :ok <- verify_tenant_attribute(dsl_state),
         :ok <- verify_tenant_mfa(dsl_state) do
      verify_multitenancy_attribute(dsl_state)
    end
  end

  defp verify_tenant_attribute(dsl_state) do
    case Verifier.get_option(dsl_state, [:replicant], :tenant_attribute) do
      nil -> :ok
      attr -> do_verify(dsl_state, attr)
    end
  end

  # The mfa arm has no attribute to shape-check (the tenant is a function result), so it runs
  # only the multitenancy-block requirement — the same fail-open the tenant_attribute arm's
  # `requires_multitenancy` closes.
  defp verify_tenant_mfa(dsl_state) do
    case Verifier.get_option(dsl_state, [:replicant], :tenant_mfa) do
      nil -> :ok
      _mfa -> requires_multitenancy_mfa(dsl_state)
    end
  end

  defp do_verify(dsl_state, attr) do
    module = Verifier.get_persisted(dsl_state, :module)
    sensitive = Verifier.get_option(dsl_state, [:replicant], :sensitive, [])
    skip = Verifier.get_option(dsl_state, [:replicant], :skip, [])
    declared = Enum.find(Verifier.get_entities(dsl_state, [:attributes]), &(&1.name == attr))

    with :ok <- not_sensitive(module, attr, sensitive),
         :ok <- not_skipped(module, attr, skip),
         :ok <- declared_non_binary(module, attr, declared) do
      requires_multitenancy(module, attr, dsl_state)
    end
  end

  defp not_sensitive(module, attr, sensitive) do
    if attr in sensitive do
      {:error,
       DslError.exception(
         module: module,
         path: [:replicant, :tenant_attribute],
         message:
           "the tenant_attribute #{inspect(attr)} must not be classified `sensitive`: the " <>
             "discriminator is a plaintext selector Ash injects as a filter and force-set, and " <>
             "an encrypted discriminator would match nothing (fail-open isolation), so it fails closed."
       )}
    else
      :ok
    end
  end

  defp not_skipped(module, attr, skip) do
    if attr in skip do
      {:error,
       DslError.exception(
         module: module,
         path: [:replicant, :tenant_attribute],
         message:
           "the tenant_attribute #{inspect(attr)} must not be listed in `skip`: a skipped " <>
             "discriminator is never written, so the tenant filter matches nothing " <>
             "(fail-open isolation)."
       )}
    else
      :ok
    end
  end

  defp declared_non_binary(module, attr, nil) do
    {:error,
     DslError.exception(
       module: module,
       path: [:replicant, :tenant_attribute],
       message:
         "the tenant_attribute #{inspect(attr)} must be a declared attribute on the mirror " <>
           "resource; an undeclared discriminator cannot be resolved or force-set, so it fails closed."
     )}
  end

  defp declared_non_binary(module, attr, declared) do
    if Ash.Type.storage_type(declared.type, declared.constraints) == :binary do
      {:error,
       DslError.exception(
         module: module,
         path: [:replicant, :tenant_attribute],
         message:
           "the tenant_attribute #{inspect(attr)} must not be binary-storage-typed: the " <>
             "discriminator is a plaintext comparator; a tag/base64 discriminator would scope " <>
             "inconsistently, so it fails closed."
       )}
    else
      :ok
    end
  end

  # `multitenancy_strategy/1` is `nil` unless a `multitenancy` section is present (it accepts
  # a compile-time `dsl_state`, same idiom as `ValidateTenantSource`). Both `:attribute` and
  # `:context` honor the `tenant:` option; only its ABSENCE is the fail-open, so require any
  # strategy. `global?` is fine — a global resource still honors `tenant:` when one is given.
  # Shared by both tenant-source arms (attribute and mfa): the fail-open is identical.
  defp multitenancy_declared?(dsl_state), do: not is_nil(AshInfo.multitenancy_strategy(dsl_state))

  defp requires_multitenancy(module, attr, dsl_state) do
    if multitenancy_declared?(dsl_state) do
      :ok
    else
      {:error,
       DslError.exception(
         module: module,
         path: [:replicant, :tenant_attribute],
         message:
           "the tenant_attribute #{inspect(attr)} requires an Ash `multitenancy` block on this " <>
             "resource (typically `strategy :attribute`, `attribute #{inspect(attr)}`): the sink " <>
             "passes the resolved per-row tenant to Ash as the `tenant:` option, which Ash HONORS " <>
             "only under declared multitenancy. With none, `tenant:` is silently ignored and every " <>
             "tenant's rows are mirrored unscoped (fail-open isolation), so it fails closed here."
       )}
    end
  end

  defp requires_multitenancy_mfa(dsl_state) do
    if multitenancy_declared?(dsl_state) do
      :ok
    else
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [:replicant, :tenant_mfa],
         message:
           "`tenant_mfa` requires an Ash `multitenancy` block on this resource (typically " <>
             "`strategy :context`): the sink passes the mfa-resolved per-row tenant to Ash as the " <>
             "`tenant:` option, which Ash HONORS only under declared multitenancy. With none, " <>
             "`tenant:` is silently ignored and every tenant's rows are mirrored unscoped " <>
             "(fail-open isolation), so it fails closed here."
       )}
    end
  end

  # The Ash `multitenancy` block's OWN `attribute` (under `strategy :attribute`) is force-set to
  # the plaintext tenant on write and filtered on read (`create.ex` `handle_attribute_multitenancy`).
  # It must be a plaintext, non-sensitive comparator: a `sensitive`-classified or binary-storage
  # column would store/compare a mismatched value and silently mis-scope (reads return empty). Runs
  # independent of the tenant SOURCE — it covers both arms and a global `:attribute` resource.
  # (An AshCloak-encrypted attribute is already rejected by Ash's own multitenancy verifier — the
  # cloak transform removes the plain attribute — so it is not re-checked here.)
  defp verify_multitenancy_attribute(dsl_state) do
    if AshInfo.multitenancy_strategy(dsl_state) == :attribute do
      check_multitenancy_attribute_shape(dsl_state, AshInfo.multitenancy_attribute(dsl_state))
    else
      :ok
    end
  end

  # nil under `:attribute` is Ash's own error ("attribute ... does not exist") — defer to it.
  defp check_multitenancy_attribute_shape(_dsl_state, nil), do: :ok

  defp check_multitenancy_attribute_shape(dsl_state, attr) do
    sensitive = Verifier.get_option(dsl_state, [:replicant], :sensitive, [])
    declared = Enum.find(Verifier.get_entities(dsl_state, [:attributes]), &(&1.name == attr))

    cond do
      attr in sensitive ->
        {:error, mt_attribute_error(dsl_state, attr, "is classified `sensitive`")}

      binary_storage?(declared) ->
        {:error, mt_attribute_error(dsl_state, attr, "is binary-storage-typed")}

      true ->
        :ok
    end
  end

  defp binary_storage?(nil), do: false
  defp binary_storage?(attr), do: Ash.Type.storage_type(attr.type, attr.constraints) == :binary

  defp mt_attribute_error(dsl_state, attr, reason) do
    DslError.exception(
      module: Verifier.get_persisted(dsl_state, :module),
      path: [:multitenancy, :attribute],
      message:
        "the multitenancy `attribute` #{inspect(attr)} #{reason}: under `strategy :attribute` Ash " <>
          "force-sets it to the plaintext tenant on write and filters reads on it, so a " <>
          "sensitive/encrypted/binary discriminator stores or compares a mismatched value and " <>
          "silently mis-scopes (reads return empty). Use a plaintext, non-sensitive attribute, so " <>
          "it fails closed here."
    )
  end
end
