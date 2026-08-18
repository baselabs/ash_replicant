defmodule AshReplicant.Sql do
  @moduledoc """
  The ONE home for quoting config-shaped SQL identifiers (U3/D4). Every raw
  statement this library builds — the truncate/:mirror DELETE, the SCD2
  `on_truncate :close` UPDATE (incl. its SET column fragments), the snapshot
  clear_mirror DELETE, and the manifest's qualified relations — routes
  through `quote_identifier/1`.

  Identifiers come from the resource DSL (an operator trust boundary), never
  from a row value — but "operator-trusted" is not "safe to interpolate
  bare": an embedded `"` breaks out of the interpolation, and a control
  character (accepted by Postgres inside quoted identifiers — probed live)
  wrecks pg_stat_activity/logs either way. Both are misconfigurations, and a
  misconfiguration fails HERE, value-free, before any SQL reaches Postgres.
  """

  alias AshReplicant.Error

  @doc """
  Quotes one SQL identifier, doubling embedded double quotes (the
  PG-canonical escape).

  Non-binary, empty, or control-character input (NUL, C0, DEL, C1) is a
  misconfiguration and raises a value-free `#{Error}` — the identifier itself
  never renders into the raised message.
  """
  @spec quote_identifier(binary()) :: binary()
  def quote_identifier(identifier) when is_binary(identifier) do
    if identifier != "" and !contains_control_character?(identifier) do
      ~s("#{String.replace(identifier, "\"", "\"\"")}")
    else
      raise Error.exception(reason: :config_invalid, shape: "identifier")
    end
  end

  def quote_identifier(_other) do
    raise Error.exception(reason: :config_invalid, shape: "identifier")
  end

  @doc """
  The admission-time twin of `quote_identifier/1`: true for a binary, non-empty,
  control-character-free identifier. The manifest walk validates every
  identifier it reads with this predicate at ADMISSION (activation /
  after-compile) — a misconfiguration fails there, before any SQL is built;
  `quote_identifier/1`'s raise remains defense-in-depth at the SQL boundary.
  """
  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(identifier) when is_binary(identifier),
    do: identifier != "" and not contains_control_character?(identifier)

  def valid_identifier?(_other), do: false

  # NUL/C0 (U+0000-U+001F), DEL (U+007F), C1 (U+0080-U+009F) — scanned at
  # CODEPOINT level, not byte level: UTF-8 continuation bytes (0x80-0xBF)
  # otherwise false-positive as C1 and reject every multibyte identifier.
  # Invalid UTF-8 (a lone continuation byte, a truncated sequence) is rejected
  # as misconfiguration too — Postgres identifiers are text.
  defp contains_control_character?(identifier) do
    if String.valid?(identifier) do
      identifier
      |> String.to_charlist()
      |> Enum.any?(&(&1 <= 0x1F or &1 in 0x7F..0x9F))
    else
      true
    end
  end
end
