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
end
