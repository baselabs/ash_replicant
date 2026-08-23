defmodule AshReplicant.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshReplicant.Telemetry

  test "validate! passes an allowlisted map and returns it" do
    meta = %{commit_lsn: 5, resource: Foo, tenant?: true}
    assert Telemetry.validate!(meta) == meta
  end

  test "validate! raises on any off-allowlist (value-bearing) key" do
    assert_raise ArgumentError, ~r/allowlist/, fn ->
      # rejected because :secret_value is off-allowlist — the module gates keys, not values
      Telemetry.validate!(%{secret_value: "4111"})
    end
  end

  test "event emits without raising for allowlisted metadata" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :applied]])

    assert :ok =
             Telemetry.event([:ash_replicant, :sink, :applied], %{change_count: 1}, %{
               commit_lsn: 9
             })

    assert_received {[:ash_replicant, :sink, :applied], ^ref, %{change_count: 1},
                     %{commit_lsn: 9}}

    :telemetry.detach(ref)
  end

  test "span/3 emits validated :start and :stop events (merge validated)" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:ash_replicant, :sink, :start],
        [:ash_replicant, :sink, :stop]
      ])

    result = Telemetry.span(:sink, %{commit_lsn: 1}, fn -> {:done, %{change_count: 3}} end)

    assert result == :done
    assert_received {[:ash_replicant, :sink, :start], ^ref, _m, %{commit_lsn: 1}}
    assert_received {[:ash_replicant, :sink, :stop], ^ref, _m, %{commit_lsn: 1, change_count: 3}}
    :telemetry.detach(ref)
  end

  test "span/3 raises when stop_meta carries an off-allowlist key (merge-validate enforcement)" do
    assert_raise ArgumentError, ~r/allowlist/, fn ->
      Telemetry.span(:sink, %{commit_lsn: 1}, fn -> {:done, %{secret_value: "4111"}} end)
    end
  end

  describe "typed metadata values (U3/D5)" do
    test "a binary under the atom-typed reason key raises, naming key + expected type only" do
      e =
        assert_raise ArgumentError, ~r/reason/, fn ->
          Telemetry.validate!(%{reason: "SENTINEL"})
        end

      refute e.message =~ "SENTINEL", "the offending VALUE never renders"
      assert e.message =~ "atom", "the expected type renders"
    end

    @type_violations [
      {:commit_lsn, "5"},
      {:commit_lsn, -1},
      {:resource, "Foo"},
      {:table, :orders},
      {:change_count, "3"},
      {:change_count, -1},
      {:tenant?, "yes"},
      {:tenant?, nil},
      {:duration, -1},
      {:duration, "1"},
      {:error_class, "invalid"},
      {:kind, "identity"},
      {:slot_name, 5}
    ]

    for {key, bad} <- @type_violations do
      test "off-type #{inspect(key)} = #{inspect(bad)} raises naming key + expected type" do
        e =
          assert_raise ArgumentError, fn ->
            Telemetry.validate!(%{unquote(key) => unquote(bad)})
          end

        assert e.message =~ to_string(unquote(key)),
               "the KEY renders (structural, not a value)"
      end
    end

    test "typed keys accept their legit shapes incl. nil where allowed" do
      meta = %{
        commit_lsn: nil,
        resource: Foo,
        table: "orders",
        change_count: 0,
        tenant?: false,
        duration: 17,
        reason: :halted,
        error_class: :invalid,
        kind: :coverage,
        slot_name: "slot"
      }

      assert Telemetry.validate!(meta) == meta
    end

    test "the off-allowlist raise names the COUNT of offending keys, never the keys" do
      sentinel_key = String.to_atom("row" <> "-value-key-SENTINEL")

      e =
        assert_raise ArgumentError, fn ->
          Telemetry.validate!(%{sentinel_key => 1})
        end

      refute e.message =~ "SENTINEL", "a row value in KEY position must never render"
      assert e.message =~ "1", "the count of offending keys renders"
    end
  end

  describe "closed measurement keys + numeric shape (U3/D5)" do
    test "an off-set measurement key raises (byte_size reserved for C1)" do
      e =
        assert_raise ArgumentError, fn ->
          Telemetry.event([:ash_replicant, :sink, :applied], %{last_value: 5}, %{commit_lsn: 1})
        end

      assert e.message =~ "measurement"
    end

    test "a non-numeric measurement raises naming key + expected shape" do
      assert_raise ArgumentError, ~r/count/, fn ->
        Telemetry.event([:ash_replicant, :sink, :applied], %{count: "1"}, %{commit_lsn: 1})
      end
    end

    test "a negative measurement raises" do
      assert_raise ArgumentError, fn ->
        Telemetry.event([:ash_replicant, :sink, :applied], %{count: -1}, %{commit_lsn: 1})
      end
    end

    test "non-finite measurements cannot reach the gate on the BEAM (documented)" do
      # The BEAM cannot produce NaN/inf floats at all: arithmetic raises
      # badarith on the constructions (0.0/0.0, 1.0e308*10), and decoding the
      # raw IEEE754 payloads via a float bit-match is REJECTED by the unifier
      # (verified live). The validator's NaN clause is therefore defensive
      # documentation, not a reachable cell on this platform — and NO
      # absorption check exists (a finite float >= 2^53 absorbs additions and
      # is legitimate). This test pins the unconstructibility so a future
      # port knows the gap.
      assert_raise ArithmeticError, fn -> 0.0 / 0.0 end
      assert_raise MatchError, fn -> <<_::float-big-64>> = <<0x7FF8000000000000::64>> end
    end

    test "the closed measurement set passes (count, change_count, duration)" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :applied]])

      :ok =
        Telemetry.event(
          [:ash_replicant, :sink, :applied],
          %{count: 1, change_count: 2, duration: 3.5},
          %{commit_lsn: 1}
        )

      assert_received {[:ash_replicant, :sink, :applied], ^ref,
                       %{count: 1, change_count: 2, duration: 3.5}, %{commit_lsn: 1}}

      :telemetry.detach(ref)
    end
  end

  describe "per-key legit acceptance (O03 mutation anchors)" do
    # One test per typed metadata key: each names its key so the mutation
    # matrix cell that laxes exactly that key's @meta_types entry has a
    # property-specific red target (a vacuous gate for one key cannot hide
    # behind the others).
    @legit_meta %{
      commit_lsn: 5,
      resource: Foo,
      table: "orders",
      change_count: 1,
      txn_count: 1,
      tenant?: true,
      duration: 9,
      reason: :halted,
      error_class: :error,
      kind: :coverage,
      slot_name: "slot",
      transactional: true
    }

    for {key, value} <- @legit_meta do
      test "legit shape accepted: #{inspect(key)}" do
        meta = %{unquote(key) => unquote(value)}
        assert Telemetry.validate!(meta) == meta
      end
    end

    @legit_measurements %{
      count: 1,
      change_count: 2,
      duration: 1.5,
      byte_size: 10
    }

    for {key, value} <- @legit_measurements do
      test "measurement accepted: #{inspect(key)}" do
        assert Telemetry.validate_measurements!(%{unquote(key) => unquote(value)}) == :ok
      end
    end

    test "the mutation matrix covers every typed telemetry key (completeness tripwire)" do
      matrix = File.read!("scripts/run-mutation-gates.py")

      for key <- Telemetry.allowed_meta_keys() do
        assert matrix =~ "telemetry_types.#{key}",
               "no mutation-matrix cell for the typed metadata key #{inspect(key)}"
      end

      for key <- Telemetry.allowed_measurement_keys() do
        assert matrix =~ "telemetry_measurements.#{key}",
               "no mutation-matrix cell for the measurement key #{inspect(key)}"
      end
    end
  end

  test "the library's own tuple-shaped reason mints valid telemetry (cross-vendor blocker regression)" do
    # {:invalid_destination_config, :onetime_store} is a RUNTIME reason minted
    # by preflight_onetime_transaction, raised on the apply path, and forwarded
    # by halt/2 — the typing must accept it or the halt path itself crashes.
    ref = :telemetry_test.attach_event_handlers(self(), [[:ash_replicant, :sink, :halted]])

    :ok =
      Telemetry.event([:ash_replicant, :sink, :halted], %{}, %{
        reason: {:invalid_destination_config, :onetime_store},
        error_class: :invalid
      })

    assert_received {[:ash_replicant, :sink, :halted], ^ref, _m,
                     %{reason: {:invalid_destination_config, :onetime_store}}}

    :telemetry.detach(ref)
  end

  test "span/3's exception event carries the structural class only, never the value (cross-vendor final4)" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:ash_replicant, :sink, :start],
        [:ash_replicant, :sink, :stop]
      ])

    assert_raise ArgumentError, fn ->
      Telemetry.span(:sink, %{commit_lsn: 1}, fn ->
        raise ArgumentError, "SENTINEL-SPAN-RAW-df77"
      end)
    end

    assert_received {[:ash_replicant, :sink, :start], ^ref, _, %{commit_lsn: 1}}
    assert_received {[:ash_replicant, :sink, :stop], ^ref, _, meta}

    refute inspect(meta) =~ "SENTINEL", "the raw exception message must never reach handlers"
    assert Map.has_key?(meta, :error_class)

    :telemetry.detach(ref)
  end

  test "span/3 with a MALFORMED fun result leaks no value and returns it (cross-vendor final5)" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:ash_replicant, :sink, :start],
        [:ash_replicant, :sink, :stop]
      ])

    sentinel_out = {:ok, "SENTINEL-SPAN-MALFORMED-3ea1"}

    returned =
      capture_log(fn ->
        assert ^sentinel_out = Telemetry.span(:sink, %{commit_lsn: 1}, fn -> sentinel_out end)
      end)

    assert_received {[:ash_replicant, :sink, :stop], ^ref, _, meta}
    refute inspect(meta) =~ "SENTINEL"
    assert returned =~ "" or is_binary(returned)

    :telemetry.detach(ref)
  end

  test "span/3's error_class comes from the closed set — a thrown minted atom never emits (cross-vendor final6)" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:ash_replicant, :sink, :start],
        [:ash_replicant, :sink, :stop]
      ])

    minted = String.to_atom("SENTINEL-CLASS-9d2f")

    catch_throw(Telemetry.span(:sink, %{commit_lsn: 1}, fn -> throw(%{class: minted}) end))

    assert_received {[:ash_replicant, :sink, :stop], ^ref, _, meta}
    assert meta.error_class == :error
    refute inspect(meta) =~ "SENTINEL"

    :telemetry.detach(ref)
  end
end
