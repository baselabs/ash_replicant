defmodule AshReplicant.Checkpoint do
  @moduledoc """
  `use AshReplicant.Checkpoint, repo: MyApp.Repo, domain: MyApp.Domain` generates the
  bundled AshPostgres checkpoint resource (table `ash_replicant_checkpoints`) bound to
  the host's repo and domain.

  One row per replication slot: `slot_name` (primary key) and the durable `commit_lsn`
  watermark. The sink upserts it in the same transaction as the mirrored changes, which
  is what gives effect-once (dup = 0) semantics.

  A macro is required because an AshPostgres resource needs its host `repo` at compile
  time; `ash_replicant` cannot hardcode it.

  ## Locking the checkpoint down with policies

  The checkpoint is an internal watermark, not tenant data: nothing outside the sink
  should read or write it. By default the generated resource carries no authorizer (so
  `policies do` is not even a declarable section), which means a host that exposes it on
  a wire surface — a JSON:API route, an MCP tool — has no way to enforce that. Pass the
  policy authorizer to close that:

      use AshReplicant.Checkpoint,
        repo: MyApp.Repo,
        domain: MyApp.Domain,
        authorizers: [Ash.Policy.Authorizer]

      # ...then declare your own policies in the module body, e.g. system-only:
      policies do
        default_access_type :strict

        policy always() do
          authorize_if MyApp.Checks.SystemActor
        end
      end

  The sink always reads and upserts the checkpoint with `authorize?: false` on both
  paths (its internal `read_checkpoint` and `upsert_checkpoint` helpers), so it bypasses
  policy — effect-once is unaffected by whatever policies the host
  declares, including none. With the authorizer present and no policies declared, the
  resource is fail-closed to every actor except the sink's `authorize?: false` path,
  which is the safe default for a watermark. `authorizers:` defaults to `[]`, so omitting
  it reproduces the pre-0.4 resource exactly (no behaviour change for existing hosts).
  """

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :domain)
    # Opt-in, default []. The consumer passes [Ash.Policy.Authorizer] to make the
    # generated resource policy-capable and then declares its own `policies do` block;
    # `authorizers: []` is identical to the option Ash already defaults to, so an
    # existing host that omits it gets the byte-for-byte pre-0.4 resource.
    authorizers = Keyword.get(opts, :authorizers, [])

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: unquote(authorizers)

      postgres do
        table "ash_replicant_checkpoints"
        repo unquote(repo)
      end

      attributes do
        attribute :slot_name, :string do
          primary_key? true
          allow_nil? false
        end

        # Ash `:integer` maps to Postgres `bigint` under AshPostgres — LSNs exceed int4.
        attribute :commit_lsn, :integer do
          allow_nil? false
        end
      end

      identities do
        identity :unique_slot, [:slot_name]
      end

      actions do
        defaults [:read]

        create :upsert do
          upsert? true
          upsert_identity :unique_slot
          accept [:slot_name, :commit_lsn]
        end
      end
    end
  end
end
