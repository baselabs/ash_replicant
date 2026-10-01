defmodule AshReplicant.SourceSetTest do
  @moduledoc """
  The decoder-scoped source table-set admission (ADR-0009 upstream / ADR-0026
  here): ONE home deciding which table-set key the activation census reads,
  mirroring Replicant 1.4's own per-decoder rule. Presence and shape only —
  identifier validity is the census SQL builders' own validation (the same
  split `publication:` always had).
  """
  use ExUnit.Case, async: true

  alias AshReplicant.SourceSet

  test "an absent decoder defaults to pgoutput with the publication rule" do
    assert {:ok, set} = SourceSet.normalize(publication: "orders_pub")
    assert set.decoder == :pgoutput
    assert set.publication == ["orders_pub"]
    assert set.replication_sets == nil
    assert set.tables == nil
  end

  test "a publication list normalizes unchanged" do
    assert {:ok, set} = SourceSet.normalize(publication: ["a", "b"])
    assert set.publication == ["a", "b"]
  end

  test "pgoutput without a publication fails with the config atom" do
    assert SourceSet.normalize([]) == {:error, :config_invalid}
    assert SourceSet.normalize(publication: "") == {:error, :config_invalid}
    assert SourceSet.normalize(publication: []) == {:error, :config_invalid}
  end

  test "pglogical requires replication sets" do
    assert {:ok, set} =
             SourceSet.normalize(decoder: :pglogical, replication_sets: "default")

    assert set.decoder == :pglogical
    assert set.replication_sets == ["default"]
    assert set.publication == nil

    assert SourceSet.normalize(decoder: :pglogical) == {:error, :config_invalid}

    assert SourceSet.normalize(decoder: :pglogical, replication_sets: []) ==
             {:error, :config_invalid}
  end

  test "wal2json requires a non-empty {schema, table} list" do
    assert {:ok, set} =
             SourceSet.normalize(decoder: :wal2json, tables: [{"public", "orders"}])

    assert set.decoder == :wal2json
    assert set.tables == [{"public", "orders"}]
    assert set.publication == nil

    assert SourceSet.normalize(decoder: :wal2json) == {:error, :config_invalid}
    assert SourceSet.normalize(decoder: :wal2json, tables: []) == {:error, :config_invalid}

    assert SourceSet.normalize(decoder: :wal2json, tables: ["public.orders"]) ==
             {:error, :config_invalid}

    assert SourceSet.normalize(decoder: :wal2json, tables: [{"public"}]) ==
             {:error, :config_invalid}
  end

  test "an unknown decoder atom fails with the config atom upstream itself uses" do
    assert SourceSet.normalize(decoder: :pg_logical, publication: "p") ==
             {:error, :config_invalid}

    assert SourceSet.normalize(decoder: "wal2json", tables: [{"public", "orders"}]) ==
             {:error, :config_invalid}
  end

  test "the census table-set decision names which member feeds the census" do
    {:ok, pgoutput} = SourceSet.normalize(publication: "p")
    {:ok, pglogical} = SourceSet.normalize(decoder: :pglogical, replication_sets: ["default"])
    {:ok, wal2json} = SourceSet.normalize(decoder: :wal2json, tables: [{"public", "orders"}])

    assert SourceSet.census_member(pgoutput) == {:publication, ["p"]}
    assert SourceSet.census_member(pglogical) == {:replication_sets, ["default"]}
    assert SourceSet.census_member(wal2json) == {:tables, [{"public", "orders"}]}
  end
end
