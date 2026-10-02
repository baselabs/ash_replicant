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

  describe "the decoder facts are one derived structure" do
    test "the decoder list is exactly the table-set map's keys" do
      # @decoders is DERIVED (Map.keys of @table_set_keys): adding a decoder
      # to the map admits it everywhere at once; the reverse (a decoder in
      # the list without a key) is unconstructible.
      assert MapSet.new(SourceSet.decoders()) ==
               MapSet.new(SourceSet.table_set_keys() |> Map.keys())
    end

    test "the table-set keys match the transport's own per-decoder rule" do
      assert SourceSet.table_set_keys() == %{
               pgoutput: :publication,
               pglogical: :replication_sets,
               wal2json: :tables
             }
    end

    test "the release floors cover exactly the admitted decoders" do
      floors = SourceSet.release_floors()

      assert MapSet.new(floors |> Map.keys()) == MapSet.new(SourceSet.decoders())
      assert floors.pgoutput == 120_000
      assert floors.pglogical == 90_600
      assert floors.wal2json == 90_600
    end

    test "a version below the decoder's floor is the named refusal" do
      assert {:error, :source_release_unsupported} =
               SourceSet.check_release_floor(90_500, :wal2json)

      assert {:error, :source_release_unsupported} =
               SourceSet.check_release_floor(110_000, :pgoutput)

      assert {:error, :source_release_unsupported} =
               SourceSet.check_release_floor(90_503, :pglogical)
    end

    test "a version at or above the floor passes" do
      assert :ok = SourceSet.check_release_floor(90_600, :wal2json)
      assert :ok = SourceSet.check_release_floor(90_624, :pglogical)
      assert :ok = SourceSet.check_release_floor(120_000, :pgoutput)
      assert :ok = SourceSet.check_release_floor(180_000, :pgoutput)
    end
  end

  describe "the pipeline's required-key table derives from the home" do
    # A host pipeline module whose config names each decoder in turn: its
    # required-key validation must demand exactly the key SourceSet maps to
    # that decoder — a re-introduced hand-synced copy in pipeline.ex that
    # diverged (the 1.5.0 shape) reds here.
    defmodule ConfigPipeline do
      @moduledoc false
      use AshReplicant.Pipeline,
        otp_app: :ash_replicant,
        sink: AshReplicant.Test.Marquee.Sink
    end

    @base [
      connection: [hostname: "127.0.0.1", port: 1, database: "postgres"],
      source_identity: [system_identifier: "741852963", database: "postgres"]
    ]

    test "every admitted decoder's own key admits the config; any other decoder's key does not" do
      for {decoder, key} <- SourceSet.table_set_keys() do
        own = Keyword.put(Keyword.put(@base, :decoder, decoder), key, ["x"])

        assert {:ok, admitted} = start_with(own)
        assert admitted[:decoder] == decoder

        for {other_decoder, other_key} <- SourceSet.table_set_keys(),
            other_decoder != decoder do
          substituted =
            Keyword.put(Keyword.put(@base, :decoder, decoder), other_key, ["x"])

          assert_raise ArgumentError, ~r/is configured but incomplete/, fn ->
            start_with(substituted)
          end
        end
      end
    end

    defp start_with(config) do
      original = Application.get_env(:ash_replicant, ConfigPipeline)
      Application.put_env(:ash_replicant, ConfigPipeline, config)

      try do
        AshReplicant.Pipeline.start_options(
          :ash_replicant,
          ConfigPipeline,
          AshReplicant.Test.Marquee.Sink
        )
      after
        case original do
          nil -> Application.delete_env(:ash_replicant, ConfigPipeline)
          value -> Application.put_env(:ash_replicant, ConfigPipeline, value)
        end
      end
    end
  end
end
