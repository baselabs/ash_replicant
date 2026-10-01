defmodule AshReplicant.SourceSet do
  @moduledoc """
  The decoder-scoped source table set (Replicant 1.4 / ADR-0026): the ONE
  admission home deciding which table-set key names the source's published
  tables for the adapter's census, contract manifest, and doctor.

  Mirrors `Replicant.Config`'s own per-decoder rule — `publication:` for
  `:pgoutput` (the default, unchanged), `replication_sets:` for `:pglogical`,
  `tables:` (`{schema, table}` pairs) for `:wal2json` — but decides it at
  ACTIVATION, before the census runs (the transport validates its full option
  grammar at `start_link`; the census needs the table set even earlier).
  Presence and shape only: identifier validity is the census SQL builders'
  own validation, exactly the split `publication:` always had. A decoder atom
  outside the three the transport accepts fails with the transport's own
  `:config_invalid` grammar atom rather than a lookalike local error.

  Cross-decoder options (a table-set key belonging to another decoder, the
  wal2json-only knobs, `streaming:`/`failover:`/`messages:` capabilities) are
  NOT re-validated here — they pass through to `Replicant.start_link/1`, whose
  refusals (`{:error, :config_invalid}`, `{:error,
  :decoder_capability_unsupported}`) surface unchanged.
  """

  @decoders [:pgoutput, :pglogical, :wal2json]

  defstruct decoder: :pgoutput,
            publication: nil,
            replication_sets: nil,
            tables: nil

  @type t :: %__MODULE__{
          decoder: :pgoutput | :pglogical | :wal2json,
          publication: [String.t()] | nil,
          replication_sets: [String.t()] | nil,
          tables: [{String.t(), String.t()}] | nil
        }

  @doc """
  Normalize `start_link` options into the admitted source set, or the
  transport's own `:config_invalid` grammar atom. A single name normalizes to
  a one-element list (the publication precedent).
  """
  @spec normalize(keyword()) :: {:ok, t()} | {:error, :config_invalid}
  def normalize(opts) when is_list(opts) do
    case Keyword.get(opts, :decoder, :pgoutput) do
      decoder when decoder in @decoders ->
        normalize_for(decoder, opts)

      _other ->
        {:error, :config_invalid}
    end
  end

  def normalize(_opts), do: {:error, :config_invalid}

  defp normalize_for(:pgoutput, opts) do
    with {:ok, publication} <- name_list(Keyword.get(opts, :publication)) do
      {:ok, %__MODULE__{decoder: :pgoutput, publication: publication}}
    end
  end

  defp normalize_for(:pglogical, opts) do
    with {:ok, sets} <- name_list(Keyword.get(opts, :replication_sets)) do
      {:ok, %__MODULE__{decoder: :pglogical, replication_sets: sets}}
    end
  end

  defp normalize_for(:wal2json, opts) do
    case Keyword.get(opts, :tables) do
      tables when is_list(tables) and tables != [] ->
        if Enum.all?(tables, &table_pair?/1),
          do: {:ok, %__MODULE__{decoder: :wal2json, tables: tables}},
          else: {:error, :config_invalid}

      _other ->
        {:error, :config_invalid}
    end
  end

  defp name_list(name) when is_binary(name) and name != "", do: {:ok, [name]}

  defp name_list(names) when is_list(names) and names != [], do: {:ok, names}

  defp name_list(_other), do: {:error, :config_invalid}

  defp table_pair?({schema, table}) when is_binary(schema) and is_binary(table), do: true
  defp table_pair?(_other), do: false

  @doc """
  Which member of the set names the census's table set — the one fact the
  per-decoder census collection branches on.
  """
  @spec census_member(t()) ::
          {:publication, [String.t()]}
          | {:replication_sets, [String.t()]}
          | {:tables, [{String.t(), String.t()}]}
  def census_member(%__MODULE__{decoder: :pgoutput, publication: publication}),
    do: {:publication, publication}

  def census_member(%__MODULE__{decoder: :pglogical, replication_sets: sets}),
    do: {:replication_sets, sets}

  def census_member(%__MODULE__{decoder: :wal2json, tables: tables}),
    do: {:tables, tables}
end
