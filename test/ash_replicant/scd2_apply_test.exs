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

  test "insert THEN delete at the same commit_lsn leaves NO current version (ghost tripwire)", %{
    config: config
  } do
    AshReplicant.Apply.apply_change(
      config,
      change(:insert, %{"order_id" => "o1", "amount" => "10"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(config, change(:delete, nil, 100, %{"order_id" => "o1"}), nil)

    vs = versions("o1")
    # ANTI-VACUITY: there MUST be exactly one version row (the create opened it); a delete
    # close at `<= 100` must have retired it. `Enum.all?([], _)` is vacuously true, so assert
    # the row EXISTS and is closed — otherwise a double-no-op would pass falsely.
    assert [v] = vs

    assert not is_nil(v.valid_to_lsn) and not v.is_current,
           "a create+delete within one commit must leave the opened version closed, not open"
  end

  test "update THEN delete at the same commit_lsn retires the row", %{config: config} do
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

    AshReplicant.Apply.apply_change(config, change(:delete, nil, 200, %{"order_id" => "o1"}), nil)

    vs = versions("o1")
    # ANTI-VACUITY: expect BOTH versions to exist (v@100 closed@200, v@200 closed@200) and
    # NONE open. Assert the count so an empty/partial result can't pass vacuously.
    assert length(vs) == 2
    assert Enum.all?(vs, &(not is_nil(&1.valid_to_lsn)))
  end

  test "pk-changing update closes the old business key and opens the new", %{config: config} do
    AshReplicant.Apply.apply_change(
      config,
      change(:insert, %{"order_id" => "o1", "amount" => "10"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(
      config,
      change(:update, %{"order_id" => "o2", "amount" => "10"}, 200, %{"order_id" => "o1"}),
      nil
    )

    assert [v_old] = versions("o1")
    assert v_old.valid_to_lsn == 200 and not v_old.is_current

    assert [v_new] = versions("o2")
    assert is_nil(v_new.valid_to_lsn) and v_new.is_current and v_new.amount == "10"
  end
end
