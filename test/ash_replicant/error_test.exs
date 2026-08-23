defmodule AshReplicant.ErrorTest do
  use ExUnit.Case, async: true

  alias AshReplicant.Error

  test "scrub keeps structure only — no embedded value reaches message or inspect" do
    leaky = %RuntimeError{message: "boom SECRET_VALUE_4111 near column pan"}
    err = Error.scrub(leaky, AshReplicant.ErrorTest, :upsert)

    assert %Error{reason: :sink_failed, shape: shape} = err
    assert shape =~ "RuntimeError"
    refute Exception.message(err) =~ "SECRET_VALUE"
    refute Exception.message(err) =~ "4111"
    refute inspect(err) =~ "SECRET_VALUE"
    refute inspect(err) =~ "4111"
  end

  # LOAD-BEARING value-free gate for the spec §Errors "a Postgres error" class. A real
  # Postgrex constraint error echoes the offending row value in `postgres.detail` — the
  # realistic pre-encryption-plaintext leak vector (Ash wraps/redacts its OWN errors, so
  # the sink-level `refute`s on a missing-PK Ash error are vacuous; scrub is the true
  # guard for a raw DB error). CONTROL asserts the raw carries the value, so the refutes
  # below cannot pass vacuously.
  test "scrub strips a value-bearing Postgres error — postgres.detail never leaks" do
    raw = %Postgrex.Error{
      postgres: %{
        code: :unique_violation,
        severity: "ERROR",
        message: "duplicate key value violates unique constraint \"cards_pan_key\"",
        detail: "Key (pan)=(4111222233334444) already exists."
      }
    }

    # CONTROL: the raw Postgres error carries the value (else the refutes are vacuous).
    assert inspect(raw) =~ "4111222233334444"

    err = Error.scrub(raw, AshReplicant.ErrorTest, :upsert)

    assert %Error{reason: :sink_failed, shape: "Postgrex.Error"} = err
    refute Exception.message(err) =~ "4111222233334444"
    refute inspect(err) =~ "4111222233334444"
    refute inspect(err) =~ "pan"
  end

  test "scrub is total — a non-exception term fails closed to a constant reason" do
    assert %Error{reason: :sink_failed} = Error.scrub({:weird, "SECRET"}, nil, :sink)
    refute inspect(Error.scrub({:weird, "SECRET"}, nil, :sink)) =~ "SECRET"
  end

  test "exception/1 builds a structural error" do
    e = Error.exception(reason: :tenant_required, resource: Foo, op: :upsert)
    assert %Error{reason: :tenant_required, resource: Foo, op: :upsert} = e
  end

  test "scrub does not leak a non-atom __struct__ term (chokepoint guard)" do
    leaky_map = %{__struct__: {:pan, "SECRET4111"}}
    err = Error.scrub(leaky_map, nil, :sink)

    assert %Error{reason: :sink_failed} = err
    refute Exception.message(err) =~ "SECRET4111"
    refute Exception.message(err) =~ "pan"
    refute inspect(err) =~ "SECRET4111"
    # non-atom __struct__ falls through to the value-free _other clause: no shape set
    assert err.shape == nil
  end

  # Install and upgrade planning mint refusal reasons on their OWN value-free
  # exception modules, outside the runtime halt taxonomy ADR-0011 freezes. The
  # exclusions are guarded: if one of these files ever touches the runtime error
  # boundary, it must rejoin this census rather than hiding a new halt reason.
  @planner_error_sources [
    "lib/ash_replicant/install.ex",
    "lib/ash_replicant/upgrade.ex",
    "lib/ash_replicant/upgrade/checkpoint.ex",
    "lib/mix/tasks/ash_replicant.upgrade.ex"
  ]

  @runtime_error_reference ~r/(?:AshReplicant\.Error\b|alias\s+AshReplicant\.\{[^}]*\bError\b)/

  test "the planner exclusion guard recognizes runtime error reference forms" do
    for source <- [
          "raise AshReplicant.Error, reason: :new_reason",
          "alias AshReplicant.{Error, Upgrade}",
          "%AshReplicant.Error{reason: :new_reason}"
        ] do
      assert source =~ @runtime_error_reference
    end

    refute "alias AshReplicant.Upgrade.Checkpoint.Error" =~ @runtime_error_reference
  end

  test "the closed reason set equals every reason minted in lib (live pin)" do
    Enum.each(@planner_error_sources, fn path ->
      refute File.read!(path) =~ @runtime_error_reference,
             "#{path} now references the runtime error — it can no longer be excluded " <>
               "from the reason census"
    end)

    minted =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&(&1 in @planner_error_sources))
      |> Enum.flat_map(fn path ->
        File.read!(path)
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/reason: :([a-z_]+)/, line) do
            [_, r] -> [r]
            nil -> []
          end
        end)
      end)
      |> Enum.uniq()
      |> MapSet.new()

    closed =
      Enum.flat_map(
        [
          :sink_failed,
          :tenant_required,
          :tenant_resolution_failed,
          :schema_change_destructive,
          :truncate_halt,
          :duplicate_source,
          :config_invalid,
          :source_identity_mismatch,
          :source_identity_rebound,
          :source_timeline_changed,
          :source_behind_watermark,
          :publication_contract_incompatible,
          :source_column_missing,
          :source_column_unmapped,
          :source_replica_identity,
          :source_skip_stale,
          :source_table_missing,
          :source_table_unmapped,
          :source_type_invalid,
          :message_prefix_unmapped,
          :checkpoint_unbound,
          :checkpoint_adopt_conflict,
          :checkpoint_adopt_invalid,
          :checkpoint_legacy_rows_present,
          # S02 (ADR-0017), additive growth per ADR-0011.
          :snapshot_state_invalid,
          :snapshot_provenance_unavailable,
          :snapshot_scope_incomplete,
          # O03 (ADR-0022): the recovery-horizon refusal.
          :retention_below_recovery_horizon
        ],
        &[Atom.to_string(&1)]
      )
      |> MapSet.new()

    assert MapSet.subset?(minted, closed),
           "reasons minted in lib but not in the closed set: #{inspect(MapSet.to_list(MapSet.difference(minted, closed)))}"
  end

  test "the public @type reason admits every @closed_reasons atom (no silent type lag)" do
    # ADR-0011's frozen set is the contract; the public type lagged it once
    # (8 atoms unlisted, Dialyzer-silent). Pin type-equals-set from source so
    # the next added reason must update both or this goes red.
    source = File.read!("lib/ash_replicant/error.ex")

    closed_block =
      source
      |> String.split("@closed_reasons [", parts: 2)
      |> Enum.at(1)
      |> String.split("]", parts: 2)
      |> Enum.at(0)

    typed_block =
      source
      |> String.split("@type reason ::", parts: 2)
      |> Enum.at(1)
      |> String.split("\n\n", parts: 2)
      |> Enum.at(0)

    atoms = fn block ->
      Regex.scan(~r/:([a-z_]+)/, block, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()
    end

    closed = atoms.(closed_block)
    typed = atoms.(typed_block)

    # The tuple variant's tag atom legitimately appears in the type without a
    # bare closed-reasons entry; it is the only permitted extra.
    assert MapSet.subset?(closed, typed),
           "@type reason is missing closed-set atoms: #{inspect(MapSet.to_list(MapSet.difference(closed, typed)))}"

    assert MapSet.to_list(MapSet.difference(typed, closed)) == ["invalid_destination_config"],
           "@type reason carries atoms outside the closed set (beyond the tuple tag)"
  end
end
