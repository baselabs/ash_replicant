defmodule AshReplicant.SnapshotProvenanceTest do
  @moduledoc """
  S01 unit tier: the versioned keyed snapshot fingerprint and its canonical
  encoding (ADR-0017). Pure — no DB, no server.

  The encoding's whole job is **injectivity**: two different `(resource, tenant,
  inputs)` triples must never share a fingerprint, or S02 skips a host business
  action for a row that actually changed. Each collision test below names the
  encoder element that prevents it (length prefix / type tag / container count)
  so removing that element goes red here.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Snapshot.Provenance
  alias AshReplicant.Test.Provenance, as: Fixtures

  @keys [{2, "second-version-provenance-key"}, {1, "first-version-provenance!!"}]

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Orders do
    use Ash.Resource,
      domain: AshReplicant.SnapshotProvenanceTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReplicant.Resource]

    replicant do
      source_schema("public")
      source_table("orders")
    end

    attributes do
      uuid_primary_key :id
      attribute :note, :string
    end
  end

  defmodule Invoices do
    use Ash.Resource,
      domain: AshReplicant.SnapshotProvenanceTest.Domain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReplicant.Resource]

    replicant do
      source_schema("public")
      source_table("invoices")
    end

    attributes do
      uuid_primary_key :id
      attribute :note, :string
    end
  end

  defmodule Marked do
    @moduledoc false
    use Ash.Resource,
      domain: AshReplicant.SnapshotProvenanceTest.MarkedDomain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReplicant.Resource]

    replicant do
      source_schema("public")
      source_table("marked")
      snapshot_provenance(true)
    end

    attributes do
      uuid_primary_key :id
      attribute :replica_fingerprint, :binary, public?: false, writable?: false
      attribute :replica_seen_attempt, :binary, public?: false, writable?: false
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      update :replicant_mark_seen do
        public? false
        accept []
        require_atomic? false
        change AshReplicant.Snapshot.MarkSeen
      end

      destroy :replicant_retire_unseen do
        public? false
      end
    end
  end

  defmodule MarkedDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.SnapshotProvenanceTest.Marked
    end
  end

  defmodule PlainDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshReplicant.SnapshotProvenanceTest.Orders
    end
  end

  defp canonical!(resource, tenant, inputs) do
    assert {:ok, encoded} = Provenance.canonical(resource, tenant, inputs)
    encoded
  end

  describe "keys/0" do
    test "accepts the configured non-empty list of unique positive versions, sorted ascending" do
      assert {:ok, keys} = Provenance.keys()
      assert keys == Enum.sort(keys)
      assert keys != []
    end

    test "rejects every malformed shape fail-closed" do
      for bad <- [
            nil,
            [],
            :not_a_list,
            [{0, "zero-version-key-16bytes"}],
            [{-1, "negative-version-key!!!!"}],
            [{1, "short"}],
            [{1, :not_a_binary}],
            [{1, "valid-key-sixteen-bytes!!"}, {1, "duplicate-version-key!!"}],
            ["not-a-tuple"],
            [{:one, :two}]
          ] do
        Fixtures.with_provenance_keys!(bad, fn ->
          assert :error = Provenance.keys(), "expected #{inspect(bad)} to be rejected"
        end)
      end
    end
  end

  describe "key_order/1" do
    test "puts the ACTIVE (highest) version first, then retained versions descending" do
      assert {:ok, [3, 2, 1]} =
               Provenance.key_order([
                 {1, "first-version-provenance!!"},
                 {3, "third-version-provenance!!"},
                 {2, "second-version-provenance-key"}
               ])
    end

    test "rejects an empty or duplicate-version key set" do
      assert :error = Provenance.key_order([])

      assert :error =
               Provenance.key_order([{1, "a-key-of-sixteen-bytes!!"}, {1, "another-key-16b!!"}])
    end
  end

  describe "canonical/3 determinism" do
    test "is stable across calls and independent of map insertion order" do
      a = canonical!(Orders, "tenant-1", %{note: "hello", id: "1"})
      b = canonical!(Orders, "tenant-1", %{id: "1", note: "hello"})
      assert a == b
      assert a == canonical!(Orders, "tenant-1", %{note: "hello", id: "1"})
    end

    test "carries the resource identity: same tenant and inputs, different resource, different bytes" do
      refute canonical!(Orders, "t", %{id: "1"}) == canonical!(Invoices, "t", %{id: "1"})
    end

    test "carries the resolved tenant" do
      refute canonical!(Orders, "tenant-1", %{id: "1"}) ==
               canonical!(Orders, "tenant-2", %{id: "1"})
    end

    test "a nil tenant (non-multitenant resource) encodes and is distinct from a blank tenant" do
      refute canonical!(Orders, nil, %{id: "1"}) == canonical!(Orders, "", %{id: "1"})
    end
  end

  describe "canonical/3 injectivity (collision tripwires)" do
    test "field boundaries are explicit — a shifted key/value boundary does not collide" do
      # The tight probe for the LENGTH PREFIX, with the type tags still in
      # place. Tagged-but-unprefixed, both sides encode as
      #   "a" <> key <> "b" <> value  ==  a x b b a y
      # so `%{x: "bay"}` and `%{xb: "ay"}` collide. The byte-length header on
      # every encoded field is the only thing separating them.
      refute canonical!(Orders, "t", %{x: "bay"}) == canonical!(Orders, "t", %{xb: "ay"})
    end

    test "field boundaries are explicit — a shifted boundary between tenant and key does not collide" do
      refute canonical!(Orders, "ab", %{x: "c"}) == canonical!(Orders, "a", %{bx: "c"})
    end

    test "value boundaries are explicit — a shifted boundary between two values does not collide" do
      refute canonical!(Orders, "t", %{a: "x", b: "yz"}) ==
               canonical!(Orders, "t", %{a: "xy", b: "z"})
    end

    test "types are tagged — integer 1 and binary \"1\" do not collide" do
      refute canonical!(Orders, "t", %{x: 1}) == canonical!(Orders, "t", %{x: "1"})
    end

    test "types are tagged — the atom :true and the boolean true do not collide with \"true\"" do
      refute canonical!(Orders, "t", %{x: true}) == canonical!(Orders, "t", %{x: "true"})
    end

    test "nil is tagged — nil and an empty binary do not collide" do
      refute canonical!(Orders, "t", %{x: nil}) == canonical!(Orders, "t", %{x: ""})
    end

    test "container boundaries are explicit — nested lists do not flatten into each other" do
      refute canonical!(Orders, "t", %{x: [["a"], ["b"]]}) ==
               canonical!(Orders, "t", %{x: [["a", "b"]]})
    end

    test "container ELEMENT COUNTS are explicit — differently-shaped nestings do not collide" do
      # The tight probe for the element COUNT, with the container tag still in
      # place. A list tag has no closing delimiter, so with the count removed
      # both sides encode as three opening "l" tags followed by one element:
      #   [[], ["a"]]  ->  l | l | l b1a
      #   [[["a"]]]    ->  l | l | l b1a
      # The count is the only thing that distinguishes them.
      refute canonical!(Orders, "t", %{x: [[], ["a"]]}) ==
               canonical!(Orders, "t", %{x: [[["a"]]]})
    end

    test "container boundaries are explicit — an embedded map is not its flattened pairs" do
      refute canonical!(Orders, "t", %{x: %{"a" => "b"}}) ==
               canonical!(Orders, "t", %{x: ["a", "b"]})
    end

    test "an absent key and an explicit nil do not collide" do
      refute canonical!(Orders, "t", %{a: "1"}) == canonical!(Orders, "t", %{a: "1", b: nil})
    end

    test "a JSONB-shaped container encodes deterministically regardless of key order" do
      assert canonical!(Orders, "t", %{x: %{"a" => 1, "b" => 2}}) ==
               canonical!(Orders, "t", %{x: %{"b" => 2, "a" => 1}})

      refute canonical!(Orders, "t", %{x: %{"a" => 1, "b" => 2}}) ==
               canonical!(Orders, "t", %{x: %{"a" => 2, "b" => 1}})
    end
  end

  describe "canonical/3 typed values" do
    test "encodes the Postgres-decoded scalar types distinctly from their string forms" do
      for value <- [
            Decimal.new("1.50"),
            ~D[2026-08-20],
            ~T[10:30:00],
            ~N[2026-08-20 10:30:00],
            ~U[2026-08-20 10:30:00Z],
            1.5,
            123
          ] do
        encoded = canonical!(Orders, "t", %{x: value})
        stringly = canonical!(Orders, "t", %{x: to_string(value)})

        refute encoded == stringly,
               "#{inspect(value)} must not encode identically to its string form"
      end
    end

    test "distinguishes a NaiveDateTime from the DateTime at the same wall clock" do
      refute canonical!(Orders, "t", %{x: ~N[2026-08-20 10:30:00]}) ==
               canonical!(Orders, "t", %{x: ~U[2026-08-20 10:30:00Z]})
    end
  end

  describe "canonical/3 fails closed on a non-deterministic term" do
    test "an unrecognised term is :unencodable, never a guessed encoding" do
      for value <- [self(), make_ref(), fn -> :ok end, %URI{}] do
        assert {:error, :unencodable} = Provenance.canonical(Orders, "t", %{x: value}),
               "expected #{inspect(value)} to fail closed"
      end
    end

    test "an unencodable value nested inside a container also fails closed" do
      assert {:error, :unencodable} = Provenance.canonical(Orders, "t", %{x: [[self()]]})
      assert {:error, :unencodable} = Provenance.canonical(Orders, "t", %{x: %{"a" => self()}})
    end

    test "an unencodable TENANT fails closed" do
      assert {:error, :unencodable} = Provenance.canonical(Orders, self(), %{x: "1"})
    end
  end

  describe "fingerprint/5" do
    test "is tagged with BOTH the encoding version and the key version" do
      assert {:ok, fp} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, @keys)
      assert String.starts_with?(fp, "e1v1:")

      assert {:ok, fp2} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 2, @keys)
      assert String.starts_with?(fp2, "e1v2:")
      refute fp == fp2
    end

    test "is HMAC-keyed, never a bare digest of the canonical bytes" do
      {:ok, fp} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, @keys)
      canonical = canonical!(Orders, "t", %{id: "1"})
      bare = Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)

      refute fp =~ bare
      assert byte_size(fp) >= byte_size("e1v1:") + 64
    end

    test "is deterministic for the same inputs and differs when any component differs" do
      {:ok, base} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, @keys)
      assert {:ok, ^base} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, @keys)

      for {resource, tenant, inputs} <- [
            {Invoices, "t", %{id: "1"}},
            {Orders, "other", %{id: "1"}},
            {Orders, "t", %{id: "2"}}
          ] do
        assert {:ok, other} = Provenance.fingerprint(resource, tenant, inputs, 1, @keys)
        refute base == other
      end
    end

    test "fails closed on an unknown key version and on an unencodable input" do
      assert {:error, :unknown_key_version} =
               Provenance.fingerprint(Orders, "t", %{id: "1"}, 9, @keys)

      assert {:error, :unencodable} =
               Provenance.fingerprint(Orders, "t", %{id: self()}, 1, @keys)
    end
  end

  describe "compare/5" do
    test "an unchanged row matches under the key version its fingerprint names" do
      {:ok, stored} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, @keys)
      assert :match = Provenance.compare(stored, Orders, "t", %{id: "1"}, @keys)
    end

    test "a changed row reports :changed, not an error" do
      {:ok, stored} = Provenance.fingerprint(Orders, "t", %{id: "1", note: "a"}, 1, @keys)
      assert :changed = Provenance.compare(stored, Orders, "t", %{id: "1", note: "b"}, @keys)
    end

    test "ROTATION: a row minted under a retained version still matches after a newer key is added" do
      {:ok, stored} =
        Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, [{1, "first-version-provenance!!"}])

      # v2 is now the active version; v1 is retained. The stored row names v1 and
      # must still verify — otherwise rotation would re-run every host business
      # action for every unchanged row.
      assert :match = Provenance.compare(stored, Orders, "t", %{id: "1"}, @keys)
    end

    test "KEY LOSS fails closed — a stored version no longer in the key set is an error, never :changed" do
      {:ok, stored} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, @keys)

      assert {:error, :unknown_key_version} =
               Provenance.compare(stored, Orders, "t", %{id: "1"}, [
                 {2, "second-version-provenance-key"}
               ])
    end

    test "an unknown ENCODING version fails closed, never :changed" do
      {:ok, stored} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, @keys)
      forged = String.replace_prefix(stored, "e1v1:", "e9v1:")

      assert {:error, :unknown_encoding_version} =
               Provenance.compare(forged, Orders, "t", %{id: "1"}, @keys)
    end

    test "a malformed or absent stored fingerprint fails closed" do
      for stored <- [nil, "", "not-a-fingerprint", "e1v1:", "v1:abcdef", :not_a_binary] do
        assert {:error, reason} = Provenance.compare(stored, Orders, "t", %{id: "1"}, @keys),
               "expected #{inspect(stored)} to fail closed"

        assert reason in [:malformed_fingerprint, :unknown_encoding_version]
      end
    end

    test "an unencodable current input fails closed rather than reporting :changed" do
      {:ok, stored} = Provenance.fingerprint(Orders, "t", %{id: "1"}, 1, @keys)

      assert {:error, :unencodable} =
               Provenance.compare(stored, Orders, "t", %{id: self()}, @keys)
    end
  end

  describe "preflight/1" do
    test "a sink mapping a provenance resource fails activation CLOSED when the keys are absent" do
      Fixtures.with_provenance_keys!(nil, fn ->
        assert {:error, error} = Provenance.preflight(%{domains: [MarkedDomain]})
        assert error.reason == :config_invalid
        assert error.op == :activation
      end)
    end

    test "a sink mapping a provenance resource fails activation CLOSED on a MALFORMED key set" do
      Fixtures.with_provenance_keys!([{1, "short"}], fn ->
        assert {:error, %{reason: :config_invalid}} =
                 Provenance.preflight(%{domains: [MarkedDomain]})
      end)
    end

    test "a sink mapping a provenance resource activates with a valid key set" do
      assert :ok = Provenance.preflight(%{domains: [MarkedDomain]})
    end

    test "a sink mapping NO provenance resource never requires the keys (the upgrade path)" do
      Fixtures.with_provenance_keys!(nil, fn ->
        assert :ok = Provenance.preflight(%{domains: [PlainDomain]})
        assert :ok = Provenance.preflight(%{domains: []})
        assert :ok = Provenance.preflight(%{})
      end)
    end
  end

  describe "value-free discipline" do
    test "no failure reason carries a row value, a tenant, or key bytes" do
      reasons =
        [
          Provenance.canonical(Orders, "super-secret-tenant", %{pan: "4111111111111111"}),
          Provenance.canonical(Orders, "t", %{pan: self()}),
          Provenance.fingerprint(Orders, "t", %{pan: "4111111111111111"}, 9, @keys),
          Provenance.compare("garbage", Orders, "t", %{pan: "4111111111111111"}, @keys)
        ]
        |> Enum.filter(&match?({:error, _}, &1))
        |> Enum.map(fn {:error, reason} -> reason end)

      assert reasons != []

      for reason <- reasons do
        assert is_atom(reason),
               "a failure reason must be a structural atom, got #{inspect(reason)}"
      end
    end
  end
end
