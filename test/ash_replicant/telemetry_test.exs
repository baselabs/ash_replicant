defmodule AshReplicant.TelemetryTest do
  use ExUnit.Case, async: true

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
end
