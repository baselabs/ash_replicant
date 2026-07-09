defmodule AshReplicant.EffectOnceScd2Test do
  @moduledoc """
  The SCD2 effect-once marquee: drives the validity-windowed (SCD2) mirror through the REAL
  `replicant` CDC pipeline (Postgres logical replication) — the load-bearing dup=0 / loss=0
  proof for the version-table strategy.

  Its own source table (`repl_scd2_src_orders`), publication, slot (`marquee_scd2_slot`) and
  `Scd2Sink` keep it isolated from the SCD1 marquee (`effect_once_test.exs`), so the two
  pipelines never cross-feed WAL nor collide under `Resolver.build_index`'s fail-closed
  duplicate-source guard. The harness (setup / `start!` readiness / stop→resume) mirrors the
  SCD1 marquee verbatim, swapping the mirror resource for the SCD2 `VersionOrder`.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AshReplicant.Test.Marquee
  alias AshReplicant.Test.PG
  alias Ecto.Adapters.SQL.Sandbox

  @conn [hostname: "localhost", port: 5599, username: "postgres", database: "postgres"]
  @slot "marquee_scd2_slot"

  setup do
    # The pipeline's Connection/AssemblerServer run in their OWN processes doing real
    # `config.repo` writes, and logical replication needs COMMITTED source rows — neither
    # works under the suite's :manual Sandbox. Run against real committing pooled
    # connections (:auto); restore :manual afterward. Registered FIRST so it runs LAST (LIFO)
    # — the cleanup below still runs while mode is :auto.
    Sandbox.mode(AshReplicant.TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(AshReplicant.TestRepo, :manual) end)

    Marquee.setup_scd2_schema!()

    # Async slot release after socket close can raise 55006 — `drop_slot!` retries.
    Marquee.drop_slot!(@slot)

    # The slot and its durable checkpoint are a PAIR (replicant fail-closes `:data_gap` when the
    # slot is absent but a checkpoint > 0 survives). The checkpoint row is committed OUTSIDE the
    # sandbox, keyed by slot_name — clear this slot's row to a genuine first run. Only at
    # setup/teardown, never mid-test (the crash-resume slot+checkpoint must stay consistent).
    Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])

    # The replay-dedup test adds a CHECK constraint (`tmp_block`) to the SHARED
    # ash_replicant_checkpoints table. Drop it defensively at setup AND teardown so a mid-test
    # crash in EITHER marquee module can never poison every subsequent checkpoint upsert.
    Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT IF EXISTS tmp_block")

    on_exit(fn ->
      AshReplicant.stop_supervised(@slot)
      Marquee.drop_slot!(@slot)
      Marquee.q!("DELETE FROM ash_replicant_checkpoints WHERE slot_name = $1", [@slot])
      Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT IF EXISTS tmp_block")
    end)

    :ok
  end

  # Block on `:slot_active` (fires on fresh `:create_slot` AND stream-resume) so a source write
  # after `start!()` is always captured — `go_forward_only: true` would otherwise skip a row
  # whose WAL precedes the slot's start point. The readiness pattern replicant's marquee uses.
  defp start! do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:replicant, :connection, :slot_active],
      fn _event, _measurements, _meta, _cfg -> send(test_pid, {:slot_active, ref}) end,
      nil
    )

    {:ok, _pid} =
      AshReplicant.start_link(
        sink: Marquee.Scd2Sink,
        connection: @conn,
        slot_name: @slot,
        publication: Marquee.scd2_publication(),
        go_forward_only: true
      )

    receive do
      {:slot_active, ^ref} -> :ok
    after
      15_000 -> flunk("pipeline never reached slot_active for #{@slot}")
    end

    :telemetry.detach({__MODULE__, ref})
  end

  test "version chain (loss=0): INSERT/UPDATE/DELETE yield contiguous, strictly-increasing boundaries" do
    start!()

    # o1 lifecycle across three source commits — each gets its own commit_lsn (L1 < L2 < L3).
    Marquee.q!("INSERT INTO #{Marquee.scd2_src()} (order_id, amount) VALUES ('o1', '1')")
    PG.wait_until(fn -> length(Marquee.scd2_versions("o1")) == 1 end)

    Marquee.q!("UPDATE #{Marquee.scd2_src()} SET amount = '2' WHERE order_id = 'o1'")
    PG.wait_until(fn -> length(Marquee.scd2_versions("o1")) == 2 end)

    Marquee.q!("DELETE FROM #{Marquee.scd2_src()} WHERE order_id = 'o1'")

    PG.wait_until(fn ->
      vs = Marquee.scd2_versions("o1")
      length(vs) == 2 and Enum.all?(vs, &(not is_nil(&1.to)))
    end)

    vs = Marquee.scd2_versions("o1")

    # COUNT first (anti-vacuity: an empty/partial result must not pass the boundary checks).
    assert length(vs) == 2
    [v1, v2] = vs

    # Each window is non-degenerate (valid_from strictly before valid_to)...
    assert v1.from < v1.to
    assert v2.from < v2.to
    # ...contiguous (v1's close == v2's open == L2)...
    assert v1.to == v2.from
    # ...strictly increasing (L1 < L2)...
    assert v1.from < v2.from
    # ...and the DELETE left NO open version (both closed, neither current).
    refute Enum.any?(vs, &is_nil(&1.to))
    refute Enum.any?(vs, & &1.current)
    # Per-version source values preserved.
    assert v1.amount == "1"
    assert v2.amount == "2"

    # dup=0: exactly one ledger row per commit_lsn (INSERT, UPDATE, DELETE = 3 distinct LSNs).
    counts = Marquee.scd2_applied_counts()
    assert map_size(counts) == 3
    assert Enum.all?(Map.values(counts), &(&1 == 1))
  end

  test "crash-and-resume (exactly once): an interrupted UPDATE re-delivers as one boundary, no dup" do
    start!()
    Marquee.q!("INSERT INTO #{Marquee.scd2_src()} (order_id, amount) VALUES ('o1', '1')")
    PG.wait_until(fn -> length(Marquee.scd2_versions("o1")) == 1 end)

    # REAL pipeline kill (a supervised teardown of the whole tree, NOT an injected raise).
    :ok = AshReplicant.stop_supervised(@slot)

    # Source write while the pipeline is DOWN — its WAL is un-delivered until resume.
    Marquee.q!("UPDATE #{Marquee.scd2_src()} SET amount = '2' WHERE order_id = 'o1'")

    start!()
    PG.wait_until(fn -> length(Marquee.scd2_versions("o1")) == 2 end)

    vs = Marquee.scd2_versions("o1")

    # loss=0: the interrupted UPDATE produced EXACTLY one new boundary...
    assert length(vs) == 2
    [v1, v2] = vs
    assert v1.to == v2.from
    assert v1.from < v2.from
    assert not v1.current and not is_nil(v1.to)
    # ...and exactly one open, current version (the re-delivered UPDATE), value preserved.
    assert is_nil(v2.to) and v2.current and v2.amount == "2"

    # dup=0: the append-only ledger has one row per commit_lsn — no LSN applied twice across
    # the kill boundary (a re-applied already-checkpointed txn would show count 2).
    counts = Marquee.scd2_applied_counts()
    assert map_size(counts) > 0
    assert Enum.all?(Map.values(counts), &(&1 == 1))
  end

  test "replay-dedup (dup=0): a checkpoint-fault rolls the SCD2 txn back byte-identical, then re-delivers exactly once" do
    start!()

    # Apply up to a durable checkpoint C: INSERT o1@L1, UPDATE o1@L2 (cp advances to L2).
    Marquee.q!("INSERT INTO #{Marquee.scd2_src()} (order_id, amount) VALUES ('o1', '1')")
    PG.wait_until(fn -> length(Marquee.scd2_versions("o1")) == 1 end)
    Marquee.q!("UPDATE #{Marquee.scd2_src()} SET amount = '2' WHERE order_id = 'o1'")
    PG.wait_until(fn -> length(Marquee.scd2_versions("o1")) == 2 end)

    before = Marquee.scd2_versions_snapshot()
    assert length(before) == 2

    # Block the checkpoint upsert so the NEXT SCD2 txn (close v(L2) + open v(L3)) fails at its
    # atomic checkpoint write and the WHOLE transaction rolls back — the close AND the open
    # both revert. This is the effect-once tripwire: a re-delivery-pending txn must leave the
    # version table BYTE-IDENTICAL (no duplicate version row, no re-opened/half-closed window).
    Marquee.q!(
      "ALTER TABLE ash_replicant_checkpoints ADD CONSTRAINT tmp_block CHECK (commit_lsn < 0) NOT VALID"
    )

    Marquee.q!("UPDATE #{Marquee.scd2_src()} SET amount = '3' WHERE order_id = 'o1'")
    Process.sleep(500)

    assert Marquee.scd2_versions_snapshot() == before,
           "a rolled-back SCD2 txn must leave the version table byte-identical (no dup, no re-open)"

    # Release the fault and resume: the un-acked L3 re-delivers (its checkpoint never advanced)
    # and applies EXACTLY ONCE — loss=0 (the change is not lost) and dup=0 (not double-applied).
    Marquee.q!("ALTER TABLE ash_replicant_checkpoints DROP CONSTRAINT tmp_block")
    :ok = AshReplicant.stop_supervised(@slot)
    start!()
    PG.wait_until(fn -> length(Marquee.scd2_versions("o1")) == 3 end)

    vs = Marquee.scd2_versions("o1")
    assert length(vs) == 3
    [v1, v2, v3] = vs

    # A single contiguous, strictly-increasing chain with exactly one open version.
    assert v1.to == v2.from and v2.to == v3.from
    assert v1.from < v2.from and v2.from < v3.from
    assert not is_nil(v1.to) and not is_nil(v2.to) and is_nil(v3.to)
    assert v3.current and v3.amount == "3"

    # dup=0: exactly one ledger row per commit_lsn. L3's first (rolled-back) attempt appended
    # NOTHING; its re-apply appended once. A double-applied re-delivery would show count 2.
    counts = Marquee.scd2_applied_counts()
    assert map_size(counts) == 3
    assert Enum.all?(Map.values(counts), &(&1 == 1))
  end

  describe "cloaked SCD2 close (adversarial Challenge 9)" do
    setup do
      Marquee.setup_scd2_cloak_schema!()
      start_supervised!(AshReplicant.Test.CloakVault)
      :ok
    end

    test "the atomic bulk_update close does not raise OriginalDataNotAvailable; ciphertext retained; new version round-trips" do
      config = %{
        resolver_index: %{
          {"public", "repl_scd2_cloak_src"} => AshReplicant.Test.Marquee.CloakVersionOrder
        },
        repo: AshReplicant.TestRepo,
        authorize?: false
      }

      # INSERT opens v(L1), encrypting pan="4111-1111" into encrypted_pan.
      AshReplicant.Apply.apply_change(
        config,
        %Replicant.Change{
          op: :insert,
          schema: "public",
          table: "repl_scd2_cloak_src",
          record: %{"order_id" => "o1", "amount" => "1", "pan" => "4111-1111"},
          commit_lsn: 100
        },
        ~U[2026-07-09 00:00:00.000000Z]
      )

      assert [v1] = Marquee.scd2_cloak_versions("o1")
      assert is_nil(v1.to) and v1.current
      c1 = v1.encrypted_pan
      refute is_nil(c1)

      # UPDATE closes v(L1) via the atomic bulk_update close path AND opens v(L2) with a fresh
      # ciphertext. Challenge 9: the `:close_version` action does not accept `pan`, so AshCloak
      # attaches no encrypt change to it — the atomic close must NOT raise
      # OriginalDataNotAvailable (this apply_change would re-raise a scrubbed error if it did).
      AshReplicant.Apply.apply_change(
        config,
        %Replicant.Change{
          op: :update,
          schema: "public",
          table: "repl_scd2_cloak_src",
          record: %{"order_id" => "o1", "amount" => "2", "pan" => "5222-2222"},
          commit_lsn: 200
        },
        ~U[2026-07-09 00:01:00.000000Z]
      )

      versions = Marquee.scd2_cloak_versions("o1")
      assert length(versions) == 2
      [closed, open] = versions

      # The close SUCCEEDED: v(L1) is closed at L2, no longer current.
      assert closed.from == 100 and closed.to == 200 and not closed.current
      # The closed version RETAINS its original ciphertext byte-for-byte (the close touched only
      # the window columns; it did not decrypt/re-encrypt/clear the sensitive column).
      assert closed.encrypted_pan == c1
      # The new open version is current with a DIFFERENT (freshly-encrypted) ciphertext.
      assert open.from == 200 and is_nil(open.to) and open.current
      refute is_nil(open.encrypted_pan)
      assert open.encrypted_pan != c1

      # The new open version's sensitive column ROUND-TRIPS through AshCloak (decrypts to the
      # expected plaintext) — end-to-end proof the open path encrypted a recoverable value.
      require Ash.Query

      loaded =
        AshReplicant.Test.Marquee.CloakVersionOrder
        |> Ash.Query.do_filter(%{order_id: "o1", valid_from_lsn: 200})
        |> Ash.read!(load: [:pan], authorize?: false)

      assert [%{pan: "5222-2222"}] = loaded
    end
  end
end
