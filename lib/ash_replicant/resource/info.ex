defmodule AshReplicant.Resource.Info do
  @moduledoc """
  Introspection for the `AshReplicant.Resource` extension.

  Generates the `replicant_<option>/1` (`{:ok, value} | :error`) and
  `replicant_<option>!/1` accessors for every option, plus the hand-written
  helpers `source_table/1` and `source_schema/1` (reflection fallbacks),
  `history_scd2?/1` (the SCD2-strategy predicate), and the append-log
  predicate/role map (`append_log?/1`, `append_attributes/1`,
  `append_identity_roles/0`).
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

  @doc """
  True when the resource is an immutable APPEND target (`append_log true`,
  ADR-0018) rather than a state mirror.
  """
  @spec append_log?(module() | map()) :: boolean()
  def append_log?(resource) do
    replicant_append_log!(resource) == true
  end

  @doc """
  The append target's structural attribute names, keyed by their fixed
  structural role. The ONE home shared by the compile-time verifier
  (`ValidateAppendLog`) and the delivery path (`AshReplicant.Append`) — a role
  present in one and absent from the other is exactly how a structural column
  silently stops being written.
  """
  @spec append_attributes(module() | map()) :: %{atom() => atom()}
  def append_attributes(resource) do
    %{
      source_system: replicant_append_source_system_attribute!(resource),
      source_database: replicant_append_source_database_attribute!(resource),
      slot_name: replicant_append_slot_attribute!(resource),
      commit_lsn: replicant_append_commit_lsn_attribute!(resource),
      ordinal: replicant_append_ordinal_attribute!(resource),
      operation: replicant_append_operation_attribute!(resource),
      origin: replicant_append_origin_attribute!(resource),
      attempt: replicant_append_attempt_attribute!(resource)
    }
  end

  @doc "The two host-owned payload attributes used by append-log message routes."
  @spec append_message_attributes(module() | map()) :: %{prefix: atom(), content: atom()}
  def append_message_attributes(resource) do
    %{
      prefix: replicant_append_message_prefix_attribute!(resource),
      content: replicant_append_message_content_attribute!(resource)
    }
  end

  @doc """
  The five structural roles that make up the append identity, in the ADR-0018 §3
  order: source system, source database, slot, commit LSN, ordinal.
  """
  @spec append_identity_roles() :: [atom()]
  def append_identity_roles,
    do: [:source_system, :source_database, :slot_name, :commit_lsn, :ordinal]
end
