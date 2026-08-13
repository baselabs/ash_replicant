defmodule AshReplicant.TestRepoGuardTest do
  @moduledoc "Database-free tests for the same-VM TestRepo start-attempt guard."
  use ExUnit.Case, async: false

  alias AshReplicant.TestRepo

  setup do
    key = TestRepo.start_attempt_key()
    previous = Application.get_env(:ash_replicant, :forbid_test_repo_start?)
    Application.put_env(:ash_replicant, :forbid_test_repo_start?, true)
    :persistent_term.erase(key)

    on_exit(fn ->
      :persistent_term.erase(key)

      case previous do
        nil -> Application.delete_env(:ash_replicant, :forbid_test_repo_start?)
        value -> Application.put_env(:ash_replicant, :forbid_test_repo_start?, value)
      end
    end)

    %{key: key}
  end

  test "runtime configuration reads are not start attempts", %{key: key} do
    assert is_list(TestRepo.config())
    refute :persistent_term.get(key, false)
  end

  test "supervisor initialization is a start attempt", %{key: key} do
    assert {:ok, []} = TestRepo.init(:supervisor, [])
    assert :persistent_term.get(key, false)
    :persistent_term.erase(key)
  end
end
