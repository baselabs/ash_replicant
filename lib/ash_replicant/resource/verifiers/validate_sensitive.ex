defmodule AshReplicant.Resource.Verifiers.ValidateSensitive do
  @moduledoc """
  Compile-verifier for `replicant do sensitive [...] end` (surfaced as a Spark
  diagnostic; build-blocking under `--warnings-as-errors`).

  Every name in `sensitive` must resolve to a real encrypted / binary write
  target, or be excluded — otherwise the mirror writes the classified column as
  plaintext. A name passes if it is any of:

  - **(a)** an AshCloak cloak attribute (`name in AshCloak.Info.cloak_attributes!/1`),
    guarded to resources that actually use AshCloak;
  - **(b)** a declared attribute whose storage type is `:binary`
    (`Ash.Type.storage_type(type, constraints) == :binary`); or
  - **(d)** listed in `skip` (never written).

  Otherwise it fails closed. This checks the TYPE SHAPE, not ciphertext —
  encrypting is the host resource's (AshCloak's) job. Messages are value-free:
  they name schema structure (column/attribute names), never a row value.

  AshCloak is the single source of truth for encryption: a hand-rolled
  `encrypted_<name>` attribute WITHOUT AshCloak is NOT accepted — there is no
  encryptor the verifier can confirm, and `AshReplicant.Resolver` would mirror
  the column as plaintext (it routes to `encrypted_<name>` only for real AshCloak
  cloak attributes), so blessing that shape would leak plaintext.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    case Verifier.get_option(dsl_state, [:replicant], :sensitive, []) do
      [] -> :ok
      sensitive -> do_verify(dsl_state, sensitive)
    end
  end

  defp do_verify(dsl_state, sensitive) do
    module = Verifier.get_persisted(dsl_state, :module)
    skip = Verifier.get_option(dsl_state, [:replicant], :skip, [])
    by_name = Map.new(Verifier.get_entities(dsl_state, [:attributes]), &{&1.name, &1})
    cloak_attrs = cloak_attributes(dsl_state)

    case Enum.find(sensitive, fn name -> not protected?(name, by_name, skip, cloak_attrs) end) do
      nil ->
        :ok

      name ->
        {:error,
         DslError.exception(
           module: module,
           path: [:replicant, :sensitive],
           message:
             "sensitive source column #{inspect(name)} must map to an AshCloak-encrypted " <>
               "attribute or a binary-storage attribute, or be listed in `skip`. A sensitive " <>
               "column mirrored as plaintext defeats the classification, so it fails closed."
         )}
    end
  end

  defp protected?(name, by_name, skip, cloak_attrs) do
    name in skip or
      name in cloak_attrs or
      binary_attr?(Map.get(by_name, name))
  end

  defp binary_attr?(nil), do: false

  defp binary_attr?(attr),
    do: Ash.Type.storage_type(attr.type, attr.constraints) == :binary

  defp cloak_attributes(dsl_state) do
    if AshCloak in (Verifier.get_persisted(dsl_state, :extensions) || []) do
      AshCloak.Info.cloak_attributes!(dsl_state)
    else
      []
    end
  rescue
    _ -> []
  end
end
