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

  test "an unknown decoder atom fails with the config atom upstream itself uses" do
    assert SourceSet.normalize(decoder: :pg_logical, publication: "p") ==
             {:error, :config_invalid}

    assert SourceSet.normalize(decoder: "pglogical", replication_sets: ["default"]) ==
             {:error, :config_invalid}
  end

  test "the census table-set decision names which member feeds the census" do
    {:ok, pgoutput} = SourceSet.normalize(publication: "p")
    {:ok, pglogical} = SourceSet.normalize(decoder: :pglogical, replication_sets: ["default"])

    assert SourceSet.census_member(pgoutput) == {:publication, ["p"]}
    assert SourceSet.census_member(pglogical) == {:replication_sets, ["default"]}
  end

  test "the table-set keys match the supported decoder rules" do
    assert SourceSet.table_set_keys() == %{pgoutput: :publication, pglogical: :replication_sets}
  end

  test "the source floor is enforced at PostgreSQL 15" do
    assert {:error, :source_release_unsupported} = SourceSet.check_release_floor(149_999)
    assert :ok = SourceSet.check_release_floor(150_000)
    assert :ok = SourceSet.check_release_floor(190_000)
    assert :ok = SourceSet.check_release_floor(200_000)
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

    test "a removed decoder fails configuration validation without showing its value" do
      error =
        assert_raise ArgumentError, fn ->
          start_with(@base ++ [decoder: :wal2json, tables: [{"public", "orders"}]])
        end

      assert Exception.message(error) =~ ":decoder"
      refute Exception.message(error) =~ "wal2json"
    end

    test "removed table options fail configuration validation without showing their values" do
      for key <- [:tables, :allow_keyless_tables, :schema_check_interval] do
        config = Keyword.put(@base ++ [publication: "pub"], key, "private-value")
        error = assert_raise ArgumentError, fn -> start_with(config) end

        assert Exception.message(error) =~ inspect(key)
        refute Exception.message(error) =~ "private-value"
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
