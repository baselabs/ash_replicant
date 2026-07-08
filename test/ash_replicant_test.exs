defmodule AshReplicantTest do
  use ExUnit.Case, async: true

  test "the library module exposes its version" do
    assert is_binary(AshReplicant.version())
  end
end
