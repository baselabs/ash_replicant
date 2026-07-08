defmodule AshReplicant.Resource.Verifiers.ValidateMultitenancy do
  @moduledoc """
  Compile-verifier for `replicant do tenant_attribute :x end` (surfaced as a
  Spark diagnostic; build-blocking under `--warnings-as-errors`).

  When a `tenant_attribute` is set it is the per-row tenant discriminator Ash
  injects as a plaintext filter and force-set. It fails closed unless it is:

  - **not** classified `sensitive` — an encrypted discriminator would match
    nothing (fail-open isolation), and `ash_replicant` holds no key material;
  - **not** listed in `skip` — a skipped discriminator is never written, so the
    tenant filter matches nothing (fail-open isolation);
  - a **declared** attribute — an undeclared discriminator cannot be resolved or
    force-set; and
  - **not** binary-storage-typed — the discriminator is a plaintext comparator;
    a tag/base64 discriminator would scope inconsistently.

  Messages are value-free: they name schema structure (the attribute name),
  never a row value.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    case Verifier.get_option(dsl_state, [:replicant], :tenant_attribute) do
      nil -> :ok
      attr -> do_verify(dsl_state, attr)
    end
  end

  defp do_verify(dsl_state, attr) do
    module = Verifier.get_persisted(dsl_state, :module)
    sensitive = Verifier.get_option(dsl_state, [:replicant], :sensitive, [])
    skip = Verifier.get_option(dsl_state, [:replicant], :skip, [])
    declared = Enum.find(Verifier.get_entities(dsl_state, [:attributes]), &(&1.name == attr))

    with :ok <- not_sensitive(module, attr, sensitive),
         :ok <- not_skipped(module, attr, skip) do
      declared_non_binary(module, attr, declared)
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
end
