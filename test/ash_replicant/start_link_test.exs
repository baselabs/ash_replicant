defmodule AshReplicant.StartLinkTest do
  use ExUnit.Case, async: false

  defmodule DupSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.DuplicateDomain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "dup_slot"
  end

  defmodule ValidSink do
    use AshReplicant.Sink,
      repo: AshReplicant.TestRepo,
      domains: [AshReplicant.Test.Domain],
      checkpoint_resource: AshReplicant.Test.Checkpoint,
      slot_name: "valid_slot"
  end

  test "a duplicate {schema,table} across the sink's domains fails closed before starting a pipeline" do
    assert {:error, {:duplicate_source, {"public", "dup_orders"}}} =
             AshReplicant.start_link(
               sink: DupSink,
               connection: [
                 hostname: "localhost",
                 port: 5599,
                 username: "postgres",
                 database: "postgres"
               ],
               publication: "dup_pub"
             )

    # fail-closed: no index cached (slot_name is baked in DupSink), no pipeline.
    assert :persistent_term.get({AshReplicant, "dup_slot"}, :none) == :none
  end

  test "on a valid index build, the resolver index IS cached before the pipeline hands off (success branch)" do
    on_exit(fn -> :persistent_term.erase({AshReplicant, "valid_slot"}) end)

    # An INVALID publication makes Replicant.Config.validate reject BEFORE connecting,
    # so we exercise the success branch (index built + cached) network-free.
    result =
      AshReplicant.start_link(
        sink: ValidSink,
        connection: [
          hostname: "localhost",
          port: 5599,
          username: "postgres",
          database: "postgres"
        ],
        publication: "invalid publication with spaces!"
      )

    # replicant's Identifier.validate rejects the bad publication with :invalid_identifier.
    assert result == {:error, :invalid_identifier}

    # the success branch ran the put: the index for ValidSink's baked slot IS cached.
    index = :persistent_term.get({AshReplicant, "valid_slot"}, :none)
    refute index == :none
    assert map_size(index) >= 1
  end
end
