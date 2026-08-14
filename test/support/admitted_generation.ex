defmodule AshReplicant.Test.AdmittedGeneration do
  @moduledoc false

  alias AshReplicant.Destination
  alias AshReplicant.Destination.Generation

  def put!(sink, opts \\ []) when is_atom(sink) do
    config = sink.__ash_replicant_config__()
    {:ok, manifest} = Destination.manifest(config)
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
      code_modules: code_modules,
      code_fingerprint: code_fingerprint,
      source_identity:
        Keyword.get(opts, :source_identity, %{
          system_identifier: "test-system",
          database: "test-database"
        }),
      publication: Keyword.get(opts, :publication, ["test_publication"]),
      dynamic_repo: dynamic_repo
    }

    :persistent_term.put({AshReplicant, config.slot_name}, generation)
    generation
  end
end
