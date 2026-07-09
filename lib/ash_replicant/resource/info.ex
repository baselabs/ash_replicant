defmodule AshReplicant.Resource.Info do
  @moduledoc """
  Introspection for the `AshReplicant.Resource` extension.

  Generates the `replicant_<option>/1` (`{:ok, value} | :error`) and
  `replicant_<option>!/1` accessors for every option, plus the hand-written
  helpers `source_table/1` and `source_schema/1` (reflection fallbacks) and
  `history_scd2?/1` (the SCD2-strategy predicate).
  """
  use Spark.InfoGenerator, extension: AshReplicant.Resource, sections: [:replicant]

  alias AshPostgres.DataLayer.Info, as: PostgresInfo

  @doc """
  The source table for the resource: the explicit `source_table`, else the
  resource's own AshPostgres table via reflection.
  """
  @spec source_table(module() | map()) :: String.t() | nil
  def source_table(resource) do
    case replicant_source_table(resource) do
      {:ok, table} when is_binary(table) -> table
      _ -> PostgresInfo.table(resource)
    end
  end

  @doc """
  The source schema for the resource: the explicit `source_schema`, else the
  resource's own AshPostgres schema via reflection, else `"public"`.
  """
  @spec source_schema(module() | map()) :: String.t()
  def source_schema(resource) do
    case replicant_source_schema(resource) do
      {:ok, schema} when is_binary(schema) -> schema
      _ -> PostgresInfo.schema(resource) || "public"
    end
  end

  @doc "True when the resource opts into SCD2 history (`history_strategy :scd2`)."
  @spec history_scd2?(module() | map()) :: boolean()
  def history_scd2?(resource) do
    replicant_history_strategy!(resource) == :scd2
  end
end
