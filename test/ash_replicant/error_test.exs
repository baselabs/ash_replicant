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
