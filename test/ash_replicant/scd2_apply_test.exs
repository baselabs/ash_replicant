defmodule AshReplicant.Scd2ApplyTest do
  use AshReplicant.DataCase, async: false
  @moduletag :integration

  alias AshReplicant.Test.OrderVersion

  setup do
    config = %{
      resolver_index: %{{"public", "orders"} => OrderVersion},
      repo: AshReplicant.TestRepo,
      authorize?: false
    }

    {:ok, config: config}
  end

  defp change(op, record, lsn, old \\ nil) do
    %Replicant.Change{
      op: op,
      schema: "public",
      table: "orders",
      record: record,
      old_record: old,
      commit_lsn: lsn
    }
  end

  defp versions(order_id) do
    OrderVersion
    |> Ash.Query.do_filter(%{order_id: order_id})
    |> Ash.Query.sort(valid_from_lsn: :asc)
    |> Ash.read!(authorize?: false)
  end

  test "insert opens one current version", %{config: config} do
    AshReplicant.Apply.apply_change(
      config,
      change(:insert, %{"order_id" => "o1", "amount" => "10"}, 100),
      ~U[2026-07-09 00:00:00.000000Z]
    )

    assert [v] = versions("o1")
    assert v.valid_from_lsn == 100
    assert is_nil(v.valid_to_lsn)
    assert v.is_current
    assert v.amount == "10"
    assert v.valid_from_ts == ~U[2026-07-09 00:00:00.000000Z]
  end

  test "update closes the prior version and opens a new current one", %{config: config} do
    AshReplicant.Apply.apply_change(
      config,
      change(:insert, %{"order_id" => "o1", "amount" => "10"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(
      config,
      change(:update, %{"order_id" => "o1", "amount" => "20"}, 200),
      nil
    )

    assert [v1, v2] = versions("o1")
    assert v1.valid_from_lsn == 100 and v1.valid_to_lsn == 200 and not v1.is_current

    assert v2.valid_from_lsn == 200 and is_nil(v2.valid_to_lsn) and v2.is_current and
             v2.amount == "20"
  end

  test "delete closes the current version, leaving no open version", %{config: config} do
    AshReplicant.Apply.apply_change(
      config,
      change(:insert, %{"order_id" => "o1", "amount" => "10"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(
      config,
      change(:delete, nil, 300, %{"order_id" => "o1"}),
      nil
    )

    assert [v] = versions("o1")
    assert v.valid_to_lsn == 300 and not v.is_current
    assert Enum.all?(versions("o1"), &(not is_nil(&1.valid_to_lsn)))
  end

  test "delete with a nil business key fails closed (no silent lost delete)", %{config: config} do
    AshReplicant.Apply.apply_change(
      config,
      change(:insert, %{"order_id" => "o1", "amount" => "10"}, 100),
      nil
    )

    assert_raise AshReplicant.Error, fn ->
      AshReplicant.Apply.apply_change(
        config,
        change(:delete, nil, 300, %{"order_id" => nil}),
        nil
      )
    end

    # The open version is untouched — nothing was silently closed.
    assert [v] = versions("o1")
    assert is_nil(v.valid_to_lsn) and v.is_current
  end
end
