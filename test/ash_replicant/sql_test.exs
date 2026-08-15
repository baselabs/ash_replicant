defmodule AshReplicant.SqlTest do
  @moduledoc """
  U3/D4 — the ONE identifier quoting home. `quote_identifier/1` wraps in double
  quotes doubling embedded `"` (the PG-canonical escape, `to_regclass`
  round-trip probed live), and REJECTS control characters rather than quoting
  them: Postgres accepts control chars inside quoted identifiers (probed), so
  quoting alone would be "correct" — rejection is the hygiene stance. A control
  character or empty identifier in DSL config is a misconfiguration that must
  fail value-free, never interpolate.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Sql

  describe "quote_identifier/1 valid identifiers" do
    test "wraps a plain identifier" do
      assert Sql.quote_identifier("orders") == ~S("orders")
    end

    test "wraps a schema-qualified pair via two calls" do
      assert Sql.quote_identifier("public") <> "." <> Sql.quote_identifier("orders") ==
               ~S("public"."orders")
    end

    test "doubles an embedded double quote (PG-canonical escape)" do
      assert Sql.quote_identifier("ord\"ers") == ~S("ord""ers")
    end

    test "doubles repeated embedded quotes" do
      assert Sql.quote_identifier("a\"b\"c") == ~S("a""b""c")
    end

    test "preserves case and unicode without altering them" do
      assert Sql.quote_identifier("OrderItems_ß") == ~S("OrderItems_ß")
    end
  end

  describe "quote_identifier/1 rejects misconfiguration, value-free" do
    @rejections [
      {"empty", ""},
      {"NUL", "\0"},
      {"newline", "\n"},
      {"carriage return", "\r"},
      {"tab", "\t"},
      {"ESC", "\e"},
      {"C0 boundary 0x1F", "\x1F"},
      {"DEL 0x7F", "\x7F"},
      {"C1 0x80", "\x80"},
      {"C1 boundary 0x9F", "\x9F"},
      {"embedded NUL between chars", "or\0ders"}
    ]

    for {label, ident} <- @rejections do
      test "rejects #{label}" do
        assert_raise AshReplicant.Error, ~r/reason=:config_invalid.*shape=identifier/, fn ->
          Sql.quote_identifier(unquote(ident))
        end
      end
    end

    test "rejects non-binary input" do
      assert_raise AshReplicant.Error, ~r/reason=:config_invalid.*shape=identifier/, fn ->
        Sql.quote_identifier(:orders)
      end
    end

    test "the rejection message carries no echo of the offending identifier" do
      e = assert_raise AshReplicant.Error, fn -> Sql.quote_identifier("or\0ders") end

      refute Exception.message(e) =~ "orders",
             "the rejection must be value-free: the identifier itself never renders"
    end
  end
end
