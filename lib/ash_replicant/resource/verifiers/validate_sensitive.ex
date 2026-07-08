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
    (`Ash.Type.storage_type(type, constraints) == :binary`);
  - **(c)** backed by a declared `encrypted_<name>` binary-storage attribute
    (the shape AshCloak produces, or a hand-rolled equivalent); or
  - **(d)** listed in `skip` (never written).

  Otherwise it fails closed. This checks the TYPE SHAPE, not ciphertext —
  encrypting is the host resource's (AshCloak's) job. Messages are value-free:
  they name schema structure (column/attribute names), never a row value.
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
               "attribute, a binary-storage attribute, or an `encrypted_<name>` binary " <>
               "attribute, or be listed in `skip`. A sensitive column mirrored as plaintext " <>
               "defeats the classification, so it fails closed."
         )}
    end
  end

  defp protected?(name, by_name, skip, cloak_attrs) do
    name in skip or
      name in cloak_attrs or
      binary_attr?(Map.get(by_name, name)) or
      encrypted_binary?(by_name, name)
  end

  defp binary_attr?(nil), do: false

  defp binary_attr?(attr),
    do: Ash.Type.storage_type(attr.type, attr.constraints) == :binary

  defp encrypted_binary?(by_name, name) do
    case safe_existing_atom("encrypted_#{name}") do
      nil -> false
      encrypted -> binary_attr?(Map.get(by_name, encrypted))
    end
  end

  defp cloak_attributes(dsl_state) do
    if AshCloak in (Verifier.get_persisted(dsl_state, :extensions) || []) do
      AshCloak.Info.cloak_attributes!(dsl_state)
    else
      []
    end
  rescue
    _ -> []
  end

  defp safe_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end
