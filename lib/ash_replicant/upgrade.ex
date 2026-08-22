defmodule AshReplicant.Upgrade.Error do
  @moduledoc "A value-free structural refusal from the package upgrade planner."

  @type reason :: :binding_invalid | :version_unsupported
  @type t :: %__MODULE__{reason: reason()}

  defexception [:reason]

  @impl Exception
  def message(%__MODULE__{reason: :binding_invalid}),
    do: "--binding must be JSON naming one discovered sink and its two source identity fields"

  def message(%__MODULE__{reason: :version_unsupported}),
    do: "AshReplicant supports exactly the 0.4.0 to 1.0.0 package upgrade"
end

defmodule AshReplicant.Upgrade.Plan do
  @moduledoc "The explicit, host-bound 0.4.0 to 1.0.0 upgrade plan."

  @type binding :: %{
          required(:sink) => module(),
          required(:pipeline) => module(),
          required(:slot_name) => String.t(),
          required(:source_system_id) => String.t(),
          required(:source_database) => String.t()
        }

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          destination_database: String.t(),
          bindings: [binding()]
        }

  @enforce_keys [:repo, :prefix, :destination_database, :bindings]
  defstruct @enforce_keys
end

defmodule AshReplicant.Upgrade do
  @moduledoc """
  Pure planning and rendering for the canonical `0.4.0 -> 1.0.0` upgrade.

  The Mix task gathers compiled host modules and live database facts. This
  module parses only explicitly allowlisted sink names, renders the host-owned
  migration, and produces the value-free report shared by dry-run and apply.
  """

  alias AshReplicant.Upgrade.{Error, Plan}

  @from "0.4.0"
  @to "1.0.0"
  @first_migration "20260822000000"
  @module_name ~r/\A(?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/

  @spec validate_versions(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def validate_versions(@from, @to), do: :ok
  def validate_versions(_from, _to), do: error(:version_unsupported)

  @doc "Parse one repeatable JSON binding without interning a tracker-supplied atom."
  @spec parse_binding(String.t(), [module()]) :: {:ok, map()} | {:error, Error.t()}
  def parse_binding(encoded, allowed_sinks) when is_binary(encoded) and is_list(allowed_sinks) do
    with {:ok,
          %{
            "sink" => sink_name,
            "pipeline" => pipeline_name,
            "source_system_id" => source_system_id,
            "source_database" => source_database
          }} <- Jason.decode(encoded),
         true <- Regex.match?(@module_name, sink_name),
         true <- Regex.match?(@module_name, pipeline_name),
         sink when is_atom(sink) and not is_nil(sink) <-
           find_allowed_sink(sink_name, allowed_sinks),
         true <- nonempty_binary?(source_system_id) and nonempty_binary?(source_database) do
      {:ok,
       %{
         sink: sink,
         pipeline: String.trim_leading(pipeline_name, "Elixir."),
         source_system_id: source_system_id,
         source_database: source_database
       }}
    else
      _other -> error(:binding_invalid)
    end
  end

  def parse_binding(_encoded, _allowed_sinks), do: error(:binding_invalid)

  @doc "Render the migration that reasserts offline state when it actually runs."
  @spec render_migration(Plan.t(), module()) :: String.t()
  def render_migration(%Plan{} = plan, migration_module) when is_atom(migration_module) do
    checkpoint_bindings =
      Enum.map(plan.bindings, fn binding ->
        Map.take(binding, [:slot_name, :source_system_id, :source_database])
      end)

    options =
      [
        bindings: checkpoint_bindings,
        prefix: plan.prefix,
        destination_database: plan.destination_database,
        pipelines_stopped?: true
      ]
      |> inspect(pretty: true, limit: :infinity)

    """
    defmodule #{inspect(migration_module)} do
      use Ecto.Migration

      @offline_assertion "ASH_REPLICANT_PIPELINES_STOPPED"

      def up do
        execute(fn -> run!(:up) end)
      end

      def down do
        execute(fn -> run!(:down) end)
      end

      defp run!(direction) do
        unless System.get_env(@offline_assertion) == "1" do
          raise "set ASH_REPLICANT_PIPELINES_STOPPED=1 only after every pipeline node is stopped"
        end

        operation =
          case direction do
            :up -> &AshReplicant.Upgrade.Checkpoint.up/2
            :down -> &AshReplicant.Upgrade.Checkpoint.down/2
          end

        case operation.(repo(), #{options}) do
          {:ok, _report} -> :ok
          {:error, error} -> raise Exception.message(error)
        end
      end
    end
    """
  end

  @doc "Render only structural counts; no binding or database value is emitted."
  @spec report(Plan.t(), atom()) :: String.t()
  def report(%Plan{} = plan, state) when is_atom(state) do
    "ash_replicant upgrade: state=#{state} bindings=#{length(plan.bindings)}"
  end

  @doc "Choose one more than the largest existing 14-digit Ecto migration prefix."
  @spec next_migration_number([Path.t()]) :: String.t()
  def next_migration_number(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(fn path ->
      case Regex.run(~r/\A(\d{14})_/, Path.basename(path), capture: :all_but_first) do
        [number] -> [String.to_integer(number)]
        _other -> []
      end
    end)
    |> case do
      [] ->
        @first_migration

      numbers ->
        numbers |> Enum.max() |> Kernel.+(1) |> Integer.to_string() |> String.pad_leading(14, "0")
    end
  end

  @doc "Render the current host checkpoint resource snapshot without running codegen."
  @spec render_checkpoint_snapshot(module()) :: String.t()
  def render_checkpoint_snapshot(repo) when is_atom(repo) do
    repo
    |> checkpoint_snapshot()
    |> Map.update!(:custom_indexes, &snapshot_indexes/1)
    |> Map.update!(:identities, &snapshot_identities/1)
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp snapshot_indexes(indexes) do
    Enum.map(indexes, fn index ->
      Map.update!(index, :fields, &snapshot_index_fields/1)
    end)
  end

  defp snapshot_index_fields(fields),
    do: Enum.map(fields, &AshPostgres.CustomIndex.field_to_snapshot/1)

  defp snapshot_identities(identities) do
    Enum.map(identities, fn identity ->
      Map.update!(identity, :keys, &snapshot_identity_keys/1)
    end)
  end

  defp snapshot_identity_keys(keys), do: Enum.map(keys, &%{type: "atom", value: &1})

  @doc false
  def current_checkpoint_snapshot?(content, repo) when is_binary(content) and is_atom(repo) do
    with {:ok, actual} <- Jason.decode(content),
         {:ok, expected} <- render_checkpoint_snapshot(repo) |> Jason.decode() do
      actual == expected
    else
      _error -> false
    end
  end

  @doc false
  def legacy_checkpoint_snapshot?(content, repo) when is_binary(content) and is_atom(repo) do
    with {:ok, snapshot} <- Jason.decode(content),
         true <- snapshot["repo"] == Atom.to_string(repo),
         true <- snapshot["table"] == "ash_replicant_checkpoints",
         true <- is_nil(snapshot["schema"]),
         true <- legacy_attributes?(snapshot["attributes"]),
         true <- legacy_identities?(snapshot["identities"]),
         true <- snapshot["custom_indexes"] == [],
         hash when is_binary(hash) <- snapshot["hash"],
         true <- Regex.match?(~r/\A[0-9A-F]{64}\z/, hash) do
      true
    else
      _error -> false
    end
  end

  defp checkpoint_snapshot(repo) do
    snapshot = %{
      attributes: checkpoint_attributes(),
      table: "ash_replicant_checkpoints",
      repo: repo,
      schema: nil,
      multitenancy: %{global: nil, attribute: nil, strategy: nil},
      check_constraints: [],
      base_filter: nil,
      custom_indexes: [
        %{
          message: nil,
          name: "ash_replicant_checkpoints_unique_slot_index",
          table: nil,
          include: nil,
          where: nil,
          fields: [:slot_name],
          prefix: nil,
          unique: true,
          concurrently: false,
          error_fields: [:slot_name],
          all_tenants?: false,
          nulls_distinct: true,
          include_base_filter?: true,
          using: nil
        }
      ],
      custom_statements: [],
      identities: [
        %{
          name: :source_slot,
          keys: [:source_system_id, :source_database, :slot_name],
          where: nil,
          index_name: "ash_replicant_checkpoints_source_slot_index",
          base_filter: nil,
          all_tenants?: false,
          nils_distinct?: true
        }
      ],
      create_table_options: nil,
      has_create_action: true
    }

    hash = snapshot |> inspect() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16()
    Map.put(snapshot, :hash, hash)
  end

  defp checkpoint_attributes do
    [
      attribute(:source_system_id, :text, false, true),
      attribute(:source_database, :text, false, true),
      attribute(:slot_name, :text, false, true),
      attribute(:source_timeline, :bigint),
      attribute(:publication_contract, :binary),
      attribute(:publication_fingerprint, :binary),
      attribute(:commit_lsn, :bigint),
      attribute(:snapshot_progress, :binary),
      attribute(:snapshot_state, :binary),
      attribute(:origin_floor, :bigint),
      attribute(:terminal_cause, :text),
      attribute(:terminal_class, :text),
      attribute(:terminal_at, :utc_datetime_usec),
      attribute(:inserted_at, :utc_datetime_usec, false, false,
        default: ~s|fragment("(now() AT TIME ZONE 'utc')")|
      ),
      attribute(:updated_at, :utc_datetime_usec, false, false,
        default: ~s|fragment("(now() AT TIME ZONE 'utc')")|
      )
    ]
  end

  defp attribute(source, type, allow_nil? \\ true, primary_key? \\ false, opts \\ []) do
    %{
      default: Keyword.get(opts, :default, "nil"),
      size: nil,
      type: type,
      source: source,
      references: nil,
      primary_key?: primary_key?,
      allow_nil?: allow_nil?,
      generated?: false
    }
  end

  defp legacy_attributes?([slot, lsn]) do
    attribute_shape(slot) == {"slot_name", "text", false, true} and
      attribute_shape(lsn) == {"commit_lsn", "bigint", false, false}
  end

  defp legacy_attributes?(_attributes), do: false

  defp attribute_shape(attribute) when is_map(attribute) do
    {
      attribute["source"],
      attribute["type"],
      attribute["allow_nil?"],
      attribute["primary_key?"]
    }
  end

  defp attribute_shape(_attribute), do: nil

  defp legacy_identities?([
         %{
           "name" => "unique_slot",
           "index_name" => "ash_replicant_checkpoints_unique_slot_index",
           "keys" => [%{"type" => "atom", "value" => "slot_name"}]
         }
       ]),
       do: true

  defp legacy_identities?(_identities), do: false

  defp find_allowed_sink(name, allowed_sinks) do
    normalized = String.trim_leading(name, "Elixir.")
    Enum.find(allowed_sinks, &(Atom.to_string(&1) == "Elixir." <> normalized))
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""
  defp error(reason), do: {:error, Error.exception(reason: reason)}
end
