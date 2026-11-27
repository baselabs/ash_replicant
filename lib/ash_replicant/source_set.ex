defmodule AshReplicant.SourceSet do
  @moduledoc """
  The decoder-scoped source table set (Replicant 1.4 / ADR-0026): the ONE
  admission home deciding which table-set key names the source's published
  tables for the adapter's census, contract manifest, and doctor.

  The default `:pgoutput` decoder uses `publication:`; `:pglogical` uses
  `replication_sets:`. The census needs the table set before transport
  startup. This module checks its presence and shape; the catalog query
  builders validate identifiers. Replicant validates decoder capabilities
  and cross-decoder options among the supported decoders.

  The same source release floor applies to both decoders. Activation and
  doctor check it before querying any decoder-specific catalogs.
  """

  @table_set_keys %{pgoutput: :publication, pglogical: :replication_sets}
  @decoders Map.keys(@table_set_keys)
  @release_floor 150_000
  @removed_options [:tables, :allow_keyless_tables, :schema_check_interval]

  defstruct decoder: :pgoutput,
            publication: nil,
            replication_sets: nil

  @type t :: %__MODULE__{
          decoder: :pgoutput | :pglogical,
          publication: [String.t()] | nil,
          replication_sets: [String.t()] | nil
        }

  @doc false
  @spec invalid_option(keyword()) :: atom() | nil
  def invalid_option(opts) do
    if Keyword.get(opts, :decoder, :pgoutput) in @decoders do
      Enum.find(@removed_options, &Keyword.has_key?(opts, &1))
    else
      :decoder
    end
  end

  @doc """
  Normalize `start_link` options into the admitted source set, or the
  transport's own `:config_invalid` grammar atom. A single name normalizes to
  a one-element list (the publication precedent).
  """
  @spec normalize(keyword()) :: {:ok, t()} | {:error, :config_invalid}
  def normalize(opts) when is_list(opts) do
    case invalid_option(opts) do
      nil -> normalize_for(Keyword.get(opts, :decoder, :pgoutput), opts)
      _key -> {:error, :config_invalid}
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

  defp name_list(name) when is_binary(name) and name != "", do: {:ok, [name]}

  defp name_list(names) when is_list(names) and names != [], do: {:ok, names}

  defp name_list(_other), do: {:error, :config_invalid}

  @doc """
  Which member of the set names the census's table set — the one fact the
  per-decoder census collection branches on.
  """
  @spec census_member(t()) :: {:publication, [String.t()]} | {:replication_sets, [String.t()]}
  def census_member(%__MODULE__{decoder: :pgoutput, publication: publication}),
    do: {:publication, publication}

  def census_member(%__MODULE__{decoder: :pglogical, replication_sets: sets}),
    do: {:replication_sets, sets}

  @doc false
  @spec table_set_keys() :: %{optional(atom()) => atom()}
  def table_set_keys, do: @table_set_keys

  @doc "Judge a probed `server_version_num` against the supported source floor."
  @spec check_release_floor(integer()) :: :ok | {:error, :source_release_unsupported}
  def check_release_floor(version) when is_integer(version) and version >= @release_floor,
    do: :ok

  def check_release_floor(version) when is_integer(version),
    do: {:error, :source_release_unsupported}
end
