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
  """

  @doc false
  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    domain = Keyword.fetch!(opts, :domain)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer

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
