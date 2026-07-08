defmodule AshReplicant.SchemaChangeTest do
  use ExUnit.Case, async: false

  defmodule Sink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "sc_slot"
  end

  defmodule IgnoreDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule IgnoreMirror do
    use Ash.Resource,
      domain: IgnoreDomain,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshReplicant.Resource]

    replicant do
      source_table("ignore_tbl")
      on_schema_change(:ignore)
    end

    attributes do
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults([:read])
    end
  end

  setup do
    {:ok, index} = AshReplicant.Resolver.build_index([AshReplicant.Test.Domain])
    :persistent_term.put({AshReplicant, "sc_slot"}, index)
    on_exit(fn -> :persistent_term.erase({AshReplicant, "sc_slot"}) end)
    :ok
  end

  defp sc(kind, table, detail \\ "d"),
    do: %Replicant.SchemaChange{
      kind: kind,
      change: :column_added,
      schema: "public",
      table: table,
      detail: detail
    }

  test "an additive change on a mapped table auto-applies (:ok)" do
    assert :ok = Sink.handle_schema_change(sc(:additive, "orders"), %{relation: :rel})
  end

  test "a destructive change on a mapped table halts fail-closed, value-free" do
    # The sentinel lives in the SchemaChange's `detail` (a realistic destructive
    # detail naming a column). The error must NOT carry `detail`, so both the
    # inspect and the rendered message must be free of it.
    assert {:error, %AshReplicant.Error{reason: :schema_change_destructive} = e} =
             Sink.handle_schema_change(
               sc(:destructive, "orders", "dropped column: orders_secret"),
               %{relation: :rel}
             )

    refute inspect(e) =~ "orders_secret"
    refute Exception.message(e) =~ "orders_secret"
  end

  test "a destructive change on a resource with on_schema_change :ignore auto-applies (:ok)" do
    # Hand-built index mapping the source table to a resource whose policy is
    # :ignore. This locks the fail-OPEN clause: destructive under :ignore -> :ok.
    config = %{resolver_index: %{{"public", "ignore_tbl"} => IgnoreMirror}}

    assert :ok =
             AshReplicant.Sink.Impl.handle_schema_change(
               config,
               sc(:destructive, "ignore_tbl"),
               %{relation: :rel}
             )
  end

  test "an unmapped table falls to the behaviour default (additive :ok / destructive error)" do
    assert :ok = Sink.handle_schema_change(sc(:additive, "unmapped_tbl"), %{relation: :rel})

    assert {:error, %AshReplicant.Error{}} =
             Sink.handle_schema_change(sc(:destructive, "unmapped_tbl"), %{relation: :rel})
  end
end
