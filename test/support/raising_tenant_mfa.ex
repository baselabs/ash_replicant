defmodule AshReplicant.Test.RaisingTenantMfa do
  @moduledoc false
  # Raises ONLY on the old side shape (no tenant_key key present) — the B4
  # :tenant_resolution_failed cell. Lives in test/support so the pure
  # no-database observers (resolver_test.exs) and the live integration suite
  # share one fixture.
  def resolve(record, "tenant_key") when is_map_key(record, "tenant_key"),
    do: Map.get(record, "tenant_key")

  def resolve(_record, "tenant_key"), do: raise(ArgumentError, "raising resolver fixture")
end
