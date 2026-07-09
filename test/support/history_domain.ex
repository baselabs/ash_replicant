defmodule AshReplicant.Test.HistoryDomain do
  @moduledoc """
  A separate domain for SCD2 history-mirror fixtures. `OrderVersion` faithfully
  declares `source_table("orders")`, which collides with the SCD1 `Order` fixture's
  source key in `Test.Domain`. `Resolver.build_index/1` fails closed on a duplicate
  source within one build-indexed domain, so the SCD2 fixtures live here — never
  passed to `build_index([Test.Domain])` by the SCD1 suites. Downstream SCD2
  apply/integration tests hand-build their resolver_index (`"orders" -> OrderVersion`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReplicant.Test.OrderVersion
  end
end
