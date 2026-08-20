defmodule AshReplicant.Test.AdmittedGeneration do
  @moduledoc false

  alias AshReplicant.Checkpoint.Identity
  alias AshReplicant.Destination
  alias AshReplicant.Destination.Generation
  alias AshReplicant.Snapshot.State

  def put!(sink, opts \\ []) when is_atom(sink) do
    config = sink.__ash_replicant_config__()
    publication = Keyword.get(opts, :publication, ["test_publication"])
    {:ok, manifest} = Destination.manifest(config)
    {:ok, source_contract} = Identity.build_contract(config, publication)

    coverage =
      case Keyword.get(opts, :coverage) do
        nil ->
          {:ok, index} = AshReplicant.Resolver.build_index(config.domains)
          AshReplicant.Coverage.from_manifest(index, source_contract.manifest)

        provided ->
          provided
      end

    {:ok, resolver_index} = AshReplicant.Resolver.build_index(config.domains)
    {:ok, dynamic_repo} = Destination.effective_dynamic_repo(config.repo)
    {:ok, code_modules} = Destination.code_modules(sink, manifest)
    {:ok, code_fingerprint} = Destination.code_fingerprint(code_modules)

    generation = %Generation{
      reference: make_ref(),
      sink: sink,
      sink_config: config,
      sink_config_digest: Destination.config_digest(config),
      resolver_index: resolver_index,
      manifest: manifest,
      manifest_digest: manifest.digest,
      source_contract: source_contract,
      source_connection: Keyword.get(opts, :source_connection),
      coverage: coverage,
      code_modules: code_modules,
      code_fingerprint: code_fingerprint,
      source_identity:
        Keyword.get(opts, :source_identity, %{
          system_identifier: "test-system",
          database: "test-database"
        }),
      publication: publication,
      dynamic_repo: dynamic_repo,
      delivery_run:
        Keyword.get_lazy(opts, :delivery_run, fn ->
          :crypto.strong_rand_bytes(State.id_bytes())
        end),
      owner: Keyword.get(opts, :owner, placeholder_owner())
    }

    :persistent_term.put({AshReplicant, config.slot_name}, generation)
    generation
  end

  # ADR-0014: a generation admits callbacks only while its owner is alive.
  # Tests that put! a generation without a real pipeline owner get a live
  # placeholder tied to the CALLER — it exits when the caller does, so it can
  # never outlive the test that owns the generation.
  defp placeholder_owner do
    caller = self()

    spawn_link(fn ->
      ref = Process.monitor(caller)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        :stop -> :ok
      end
    end)
  end
end
