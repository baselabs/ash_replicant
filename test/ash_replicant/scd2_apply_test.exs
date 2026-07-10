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

  test "on_truncate :close closes every open version tenant-blind", %{config: _config} do
    ct_config = %{
      resolver_index: %{{"public", "orders"} => AshReplicant.Test.OrderVersionCloseTruncate},
      repo: AshReplicant.TestRepo,
      authorize?: false
    }

    AshReplicant.Apply.apply_change(
      ct_config,
      change(:insert, %{"order_id" => "a", "amount" => "1"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(
      ct_config,
      change(:insert, %{"order_id" => "b", "amount" => "2"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(
      ct_config,
      %Replicant.Change{op: :truncate, schema: "public", table: "orders", commit_lsn: 500},
      nil
    )

    rows = AshReplicant.Test.OrderVersionCloseTruncate |> Ash.read!(authorize?: false)

    # ANTI-VACUITY (MANDATORY): assert BOTH versions exist before checking closed — `Enum.all?([], _)`
    # is vacuously true, so an empty result (inserts failed) must NOT pass.
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.valid_to_lsn == 500 and not &1.is_current))

    # IDEMPOTENCY: re-truncate at a LATER lsn. `WHERE valid_to_lsn IS NULL` matches no
    # open rows now, so already-closed versions KEEP their original valid_to_lsn (500),
    # never re-stamped to 600.
    AshReplicant.Apply.apply_change(
      ct_config,
      %Replicant.Change{op: :truncate, schema: "public", table: "orders", commit_lsn: 600},
      nil
    )

    reread = AshReplicant.Test.OrderVersionCloseTruncate |> Ash.read!(authorize?: false)
    assert length(reread) == 2
    assert Enum.all?(reread, &(&1.valid_to_lsn == 500 and not &1.is_current))
  end

  test "on_truncate :mirror physically deletes every version row (mirror_wipe)", %{
    config: _config
  } do
    m_config = %{
      resolver_index: %{{"public", "orders"} => AshReplicant.Test.OrderVersionMirror},
      repo: AshReplicant.TestRepo,
      authorize?: false
    }

    AshReplicant.Apply.apply_change(
      m_config,
      change(:insert, %{"order_id" => "a", "amount" => "1"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(
      m_config,
      change(:insert, %{"order_id" => "b", "amount" => "2"}, 100),
      nil
    )

    # ANTI-VACUITY: rows MUST exist before the truncate, else an empty-table `== []` passes falsely.
    assert length(Ash.read!(AshReplicant.Test.OrderVersionMirror, authorize?: false)) == 2

    AshReplicant.Apply.apply_change(
      m_config,
      %Replicant.Change{op: :truncate, schema: "public", table: "orders", commit_lsn: 500},
      nil
    )

    # mirror_wipe issues a raw DELETE of the whole version table — no rows remain.
    assert Ash.read!(AshReplicant.Test.OrderVersionMirror, authorize?: false) == []
  end

  test "on_truncate :close is tenant-blind — closes EVERY tenant's open version", %{
    config: _config
  } do
    t_config = %{
      resolver_index: %{{"public", "orders"} => AshReplicant.Test.OrderVersionTenant},
      repo: AshReplicant.TestRepo,
      authorize?: false
    }

    # Insert via the SCD2 apply path for two distinct tenants (resolve_tenant pulls org_id
    # from the record). This also exercises the multitenant SCD2 INSERT path.
    AshReplicant.Apply.apply_change(
      t_config,
      change(:insert, %{"order_id" => "a", "org_id" => "t1", "amount" => "1"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(
      t_config,
      change(:insert, %{"order_id" => "b", "org_id" => "t2", "amount" => "2"}, 100),
      nil
    )

    # A SINGLE tenant-blind truncate closes BOTH tenants' open versions (no tenant filter).
    AshReplicant.Apply.apply_change(
      t_config,
      %Replicant.Change{op: :truncate, schema: "public", table: "orders", commit_lsn: 500},
      nil
    )

    t1 = Ash.read!(AshReplicant.Test.OrderVersionTenant, tenant: "t1", authorize?: false)
    t2 = Ash.read!(AshReplicant.Test.OrderVersionTenant, tenant: "t2", authorize?: false)

    # ANTI-VACUITY: each tenant has exactly one version row — a tenant-scoped close would
    # have raised TenantRequired or touched only one tenant; both are closed here.
    assert length(t1) == 1
    assert length(t2) == 1
    assert Enum.all?(t1 ++ t2, &(&1.valid_to_lsn == 500 and not &1.is_current))
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

  test "pk-changing update at the SAME commit_lsn retires the old key (no ghost open version)", %{
    config: config
  } do
    # Insert o1 and change its key o1→o2 within ONE source transaction: both changes carry the
    # SAME commit_lsn. The old-key close is TERMINAL (o1 is retired, never re-opened at L), so it
    # must use the inclusive `<= L` predicate. With the open-path `< L`, o1's version opened at
    # exactly L is not matched and dangles open forever — a ghost of a key that no longer exists,
    # invisible to the partial-unique-open index (o1 and o2 are distinct keys). This is the
    # within-txn case the cross-txn pk-change test above cannot exercise (it uses 100 then 200).
    AshReplicant.Apply.apply_change(
      config,
      change(:insert, %{"order_id" => "o1", "amount" => "10"}, 100),
      nil
    )

    AshReplicant.Apply.apply_change(
      config,
      change(:update, %{"order_id" => "o2", "amount" => "10"}, 100, %{"order_id" => "o1"}),
      nil
    )

    # ANTI-VACUITY: the old key MUST have exactly one version and it MUST be closed at L.
    assert [v_old] = versions("o1")

    assert v_old.valid_to_lsn == 100 and not v_old.is_current,
           "a same-commit_lsn pk-change must retire the old key's version, not leave it open"

    # The new key is the sole open/current version.
    assert [v_new] = versions("o2")
    assert is_nil(v_new.valid_to_lsn) and v_new.is_current
  end

  test "an SCD2 apply failure is value-free (scrubbed to a structural reason)", %{config: config} do
    # No `order_id` in the record → the nil-business-key guard in `close_current` raises a
    # structural `AshReplicant.Error` BEFORE any write. The scrubbed error must carry only
    # structure (reason/resource/op), never the `amount` row value.
    bad = %Replicant.Change{
      op: :insert,
      schema: "public",
      table: "orders",
      record: %{"amount" => "secret-value-123"},
      commit_lsn: 100
    }

    err =
      assert_raise AshReplicant.Error, fn -> AshReplicant.Apply.apply_change(config, bad, nil) end

    refute inspect(err) =~ "secret-value-123"
    assert err.reason in [:sink_failed, :tenant_required]
  end
end
