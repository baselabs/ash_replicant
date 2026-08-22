defmodule AshReplicant.Install.Error do
  @moduledoc """
  A structural refusal from the install planner (`AshReplicant.Install`).

  Every refusal names the artifact it is about and the exact flag that resolves
  it. Messages are value-free in the same sense as the runtime boundaries: they
  carry module names, a slot name, and flag names — never a connection,
  publication, identity, or secret, none of which the installer ever reads.
  """

  @type reason ::
          :module_name_invalid
          | :slot_name_invalid
          | :repo_required
          | :repo_ambiguous
          | :repo_unknown
          | :project_state_incomplete
          | :module_conflict
          | :binding_unreadable
          | :checkpoint_repo_mismatch
          | :sink_slot_mismatch
          | :pipeline_sink_mismatch

  @type t :: %__MODULE__{reason: reason(), artifact: module() | nil, detail: map()}

  defexception reason: nil, artifact: nil, detail: %{}

  @impl Exception
  def message(%__MODULE__{reason: :module_name_invalid, detail: detail}) do
    """
    #{detail.flag} must name an Elixir module.

    Use a conventional alias made of upper-case segments, for example:

        mix ash_replicant.install #{detail.flag} MyApp.Replicant
    """
  end

  def message(%__MODULE__{reason: :slot_name_invalid}) do
    """
    --slot must name a legal PostgreSQL replication slot.

    PostgreSQL admits 1 to 63 characters drawn from lower-case letters, digits, and \
    the underscore. Re-run naming a legal slot:

        mix ash_replicant.install --slot my_app_replicant
    """
  end

  def message(%__MODULE__{reason: :repo_required}) do
    """
    no AshPostgres repo was found in this project.

    AshReplicant commits its mirror writes and its checkpoint through one AshPostgres \
    repo, so the install cannot proceed without knowing which. Generate one with \
    `mix ash_postgres.install`, or name an existing repo:

        mix ash_replicant.install --repo MyApp.Repo
    """
  end

  def message(%__MODULE__{reason: :repo_ambiguous, detail: detail}) do
    """
    this project defines more than one repo (#{inspect(detail.repos)}).

    AshReplicant will not guess which one this sink commits into — the wrong choice \
    puts the durable checkpoint in a different database from the mirrored rows. Name it:

        mix ash_replicant.install --repo #{inspect(detail.suggestion)}
    """
  end

  def message(%__MODULE__{reason: :repo_unknown}) do
    """
    --repo must name an AshPostgres repo defined in this project.

    AshReplicant cannot generate a checkpoint against an unknown or non-Postgres repo. \
    Name one of the project's `use AshPostgres.Repo` modules and re-run.
    """
  end

  def message(%__MODULE__{reason: :project_state_incomplete, detail: detail}) do
    """
    the installer could not classify every target module; missing roles: \
    #{inspect(detail.missing)}.

    No source was changed. Re-run after the project can be parsed completely.
    """
  end

  def message(%__MODULE__{reason: :module_conflict, artifact: artifact, detail: detail}) do
    """
    #{inspect(artifact)} already exists and is not #{detail.description}.

    The installer never overwrites a module it did not generate. Rename or remove the \
    existing module, or generate this one under a different name:

        mix ash_replicant.install #{detail.flag} #{inspect(detail.suggestion)}
    """
  end

  def message(%__MODULE__{reason: :binding_unreadable, artifact: artifact, detail: detail}) do
    """
    #{inspect(artifact)} uses the expected AshReplicant module, but its \
    #{detail.binding} binding is not a literal the installer can verify.

    The installer never evaluates host source and never assumes an unreadable binding \
    matches. Make the binding a literal, or generate a separate artifact:

        mix ash_replicant.install #{detail.flag} #{inspect(detail.suggestion)}
    """
  end

  def message(%__MODULE__{reason: :checkpoint_repo_mismatch, artifact: artifact, detail: detail}) do
    """
    #{inspect(artifact)} is already bound to repo #{inspect(detail.existing)}, but this \
    install targets #{inspect(detail.requested)}.

    A checkpoint's repo is the database its durable watermark commits into. Re-pointing \
    it strands that watermark and re-delivers everything above it. Keep the existing \
    binding:

        mix ash_replicant.install --repo #{inspect(detail.existing)}

    or generate a separate checkpoint for the other repo:

        mix ash_replicant.install --checkpoint #{inspect(detail.suggestion)}
    """
  end

  def message(%__MODULE__{reason: :sink_slot_mismatch, artifact: artifact, detail: detail}) do
    """
    #{inspect(artifact)} is already bound to slot #{inspect(detail.existing)}, but this \
    install requests #{inspect(detail.requested)}.

    The slot name keys the durable checkpoint identity (source system, source database, \
    slot). Re-keying it abandons the existing checkpoint row and re-delivers from the \
    new slot's own position. Keep the existing binding:

        mix ash_replicant.install --slot #{detail.existing}

    or generate a separate sink for the other slot:

        mix ash_replicant.install --sink #{inspect(detail.suggestion)}
    """
  end

  def message(%__MODULE__{reason: :pipeline_sink_mismatch, artifact: artifact, detail: detail}) do
    """
    #{inspect(artifact)} is already wired to sink #{inspect(detail.existing)}, but this \
    install targets #{inspect(detail.requested)}.

    One generated pipeline supervises one sink's owner. Keep the existing wiring:

        mix ash_replicant.install --sink #{inspect(detail.existing)}

    or generate a separate pipeline for the other sink:

        mix ash_replicant.install --pipeline #{inspect(detail.suggestion)}
    """
  end
end

defmodule AshReplicant.Install do
  @moduledoc """
  The install PLANNER — the decision half of `mix ash_replicant.install` (I01).

  This module is deliberately Igniter-free and side-effect-free. The Mix task
  gathers facts about the host project (which repos exist, which target modules
  already exist and what they are bound to) and hands them here; everything the
  installer REFUSES is decided by `plan/1` and rendered by
  `AshReplicant.Install.Error`.

  The split exists because the refusals are the part whose failure is quiet.
  Overwriting a foreign module is loud; silently re-pointing an existing
  checkpoint at a second repo, or re-keying a live sink onto a different
  replication slot, is not — the project still compiles, and the damage shows up
  as a re-delivered or abandoned watermark in production. Keeping those
  decisions pure is what lets every one of them carry a unit test.

  ## The artifacts

  Four modules, named from the app's module prefix unless a flag overrides them:

  | Role | Default | Generated shape |
  | --- | --- | --- |
  | `:domain` | `MyApp.Replicant` | `use Ash.Domain` holding the checkpoint |
  | `:checkpoint` | `MyApp.Replicant.Checkpoint` | `use AshReplicant.Checkpoint` |
  | `:sink` | `MyApp.Replicant.Sink` | `use AshReplicant.Sink` |
  | `:pipeline` | `MyApp.Replicant.Pipeline` | `use AshReplicant.Pipeline` |

  ## Refusal order

  Cheapest and most-local first, so an operator fixes one thing at a time:
  the slot name, then repo resolution, then module conflicts, then binding
  drift. `plan/1` returns the FIRST refusal in that order.
  """

  alias AshReplicant.Install.Error

  @slot_name_format ~r/\A[a-z0-9_]{1,63}\z/
  @module_name_format ~r/\A(?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/

  @roles [:domain, :checkpoint, :sink, :pipeline]

  @flags %{
    domain: "--domain",
    checkpoint: "--checkpoint",
    sink: "--sink",
    pipeline: "--pipeline"
  }

  @module_flags Map.put(@flags, :repo, "--repo")

  @bindings %{
    checkpoint: "repo",
    sink: "slot name",
    pipeline: "sink"
  }

  @descriptions %{
    domain: "an Ash domain",
    checkpoint: "an AshReplicant checkpoint resource",
    sink: "an AshReplicant sink",
    pipeline: "an AshReplicant pipeline"
  }

  @suffixes %{
    domain: "Replicant",
    checkpoint: "Replicant.Checkpoint",
    sink: "Replicant.Sink",
    pipeline: "Replicant.Pipeline"
  }

  @typedoc "A planned artifact: the module name, and whether the install creates it."
  @type artifact :: %{module: module(), create?: boolean()}

  @typedoc """
  What the host project already has at each artifact's name.

  * `:absent` — nothing is there; the installer creates it.
  * `:ash_domain` — an existing `Ash.Domain` the checkpoint can join.
  * `{:ash_replicant, binding}` — a module this installer generated, with the
    binding it carries (`nil` when the binding could not be read from source).
  * `:foreign` — a module the installer did not generate. Always a refusal.
  """
  @type existing ::
          :absent
          | :ash_domain
          | :foreign
          | {:ash_replicant, module() | String.t() | nil}

  @type t :: %__MODULE__{
          otp_app: atom(),
          repo: module(),
          slot_name: String.t(),
          domain: artifact(),
          checkpoint: artifact(),
          sink: artifact(),
          pipeline: artifact()
        }

  defstruct [:otp_app, :repo, :slot_name, :domain, :checkpoint, :sink, :pipeline]

  @doc """
  The module name for every artifact, from the project's module prefix and
  already-validated name-override flags. `validate_options/1` is the admission
  boundary; after it succeeds this function is total and never consults the
  project.
  """
  @spec artifacts(module(), map()) :: %{
          domain: module(),
          checkpoint: module(),
          sink: module(),
          pipeline: module()
        }
  def artifacts(prefix, options \\ %{}) do
    Map.new(@roles, fn role ->
      {role, named(options, role, Module.concat(prefix, Map.fetch!(@suffixes, role)))}
    end)
  end

  @doc """
  The slot name this install uses: the `--slot` flag, else one derived from the
  OTP application name.
  """
  @spec default_slot_name(atom()) :: String.t()
  def default_slot_name(otp_app), do: "#{otp_app}_replicant"

  @doc """
  Decide the install.

  Options:

  * `:otp_app` — the host's OTP application name (required).
  * `:prefix` — the host's module prefix, e.g. `MyApp` (required).
  * `:options` — the parsed CLI flags, as a map of atom keys to string values.
  * `:repos` — every AshPostgres repo module discovered in the project.
  * `:existing` — a complete map of every role to `t:existing/0`.
  """
  @spec plan(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def plan(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    prefix = Keyword.fetch!(opts, :prefix)
    options = Keyword.get(opts, :options, %{})
    repos = Keyword.get(opts, :repos, [])
    existing = Keyword.get(opts, :existing, %{})

    with :ok <- validate_options(options),
         :ok <- validate_existing(existing),
         artifacts = artifacts(prefix, options),
         {:ok, slot_name} <- resolve_slot_name(otp_app, options),
         {:ok, repo} <- resolve_repo(repos, options),
         :ok <- refuse_conflicts(artifacts, existing),
         :ok <- refuse_drift(artifacts, existing, repo, slot_name) do
      {:ok,
       %__MODULE__{
         otp_app: otp_app,
         repo: repo,
         slot_name: slot_name,
         domain: artifact(artifacts, existing, :domain),
         checkpoint: artifact(artifacts, existing, :checkpoint),
         sink: artifact(artifacts, existing, :sink),
         pipeline: artifact(artifacts, existing, :pipeline)
       }}
    end
  end

  @doc false
  @spec validate_options(map()) :: :ok | {:error, Error.t()}
  def validate_options(options) do
    Enum.find_value(@module_flags, :ok, fn {role, flag} ->
      case Map.fetch(options, role) do
        :error ->
          false

        {:ok, value} ->
          validate_module_flag(value, role, flag)
      end
    end)
  end

  defp validate_module_flag(value, role, flag) do
    if valid_module_name?(value),
      do: false,
      else: {:error, %Error{reason: :module_name_invalid, detail: %{role: role, flag: flag}}}
  end

  defp artifact(artifacts, existing, role) do
    %{
      module: Map.fetch!(artifacts, role),
      create?: Map.get(existing, role, :absent) == :absent
    }
  end

  defp named(options, role, default) do
    case Map.get(options, role) do
      nil -> default
      value -> parse_module(value)
    end
  end

  defp parse_module(value) when is_atom(value), do: value

  defp parse_module(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split(".")
    |> Module.concat()
  end

  defp valid_module_name?(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> valid_module_name?()
  end

  defp valid_module_name?(value) when is_binary(value) do
    value = String.trim(value)
    value != "Elixir" and Regex.match?(@module_name_format, value)
  end

  defp valid_module_name?(_value), do: false

  defp validate_existing(existing) do
    missing = @roles -- Map.keys(existing)

    case missing do
      [] -> :ok
      missing -> {:error, %Error{reason: :project_state_incomplete, detail: %{missing: missing}}}
    end
  end

  defp resolve_slot_name(otp_app, options) do
    slot_name = Map.get(options, :slot) || default_slot_name(otp_app)

    if is_binary(slot_name) and Regex.match?(@slot_name_format, slot_name) do
      {:ok, slot_name}
    else
      {:error, %Error{reason: :slot_name_invalid, detail: %{slot_name: slot_name}}}
    end
  end

  defp resolve_repo(repos, options) do
    case {Map.get(options, :repo), repos} do
      {nil, []} ->
        {:error, %Error{reason: :repo_required, detail: %{}}}

      {nil, [repo]} ->
        {:ok, repo}

      {nil, repos} ->
        {:error,
         %Error{
           reason: :repo_ambiguous,
           detail: %{repos: repos, suggestion: List.first(repos)}
         }}

      {named, repos} ->
        repo = parse_module(named)

        if repo in repos do
          {:ok, repo}
        else
          {:error, %Error{reason: :repo_unknown, detail: %{}}}
        end
    end
  end

  defp refuse_conflicts(artifacts, existing) do
    Enum.reduce_while(@roles, :ok, fn role, :ok ->
      case {role, Map.get(existing, role, :absent)} do
        {_role, :foreign} ->
          {:halt, {:error, conflict(artifacts, role)}}

        {:domain, {:ash_replicant, _binding}} ->
          {:halt, {:error, conflict(artifacts, role)}}

        {:sink, {:ash_replicant, binding}} when not is_binary(binding) ->
          {:halt, {:error, binding_unreadable(artifacts, role)}}

        {role, {:ash_replicant, binding}}
        when role in [:checkpoint, :pipeline] and (is_nil(binding) or not is_atom(binding)) ->
          {:halt, {:error, binding_unreadable(artifacts, role)}}

        _admissible ->
          {:cont, :ok}
      end
    end)
  end

  defp binding_unreadable(artifacts, role) do
    module = Map.fetch!(artifacts, role)

    %Error{
      reason: :binding_unreadable,
      artifact: module,
      detail: %{
        role: role,
        binding: Map.fetch!(@bindings, role),
        flag: Map.fetch!(@flags, role),
        suggestion: Module.concat(module, "Secondary")
      }
    }
  end

  defp conflict(artifacts, role) do
    module = Map.fetch!(artifacts, role)

    %Error{
      reason: :module_conflict,
      artifact: module,
      detail: %{
        role: role,
        flag: Map.fetch!(@flags, role),
        description: Map.fetch!(@descriptions, role),
        suggestion: Module.concat(module, "Replicant")
      }
    }
  end

  defp refuse_drift(artifacts, existing, repo, slot_name) do
    with :ok <- refuse_checkpoint_drift(artifacts, existing, repo),
         :ok <- refuse_sink_drift(artifacts, existing, slot_name) do
      refuse_pipeline_drift(artifacts, existing)
    end
  end

  defp refuse_checkpoint_drift(artifacts, existing, repo) do
    case Map.get(existing, :checkpoint, :absent) do
      {:ash_replicant, bound} when not is_nil(bound) and bound != repo ->
        module = Map.fetch!(artifacts, :checkpoint)

        {:error,
         %Error{
           reason: :checkpoint_repo_mismatch,
           artifact: module,
           detail: %{
             existing: bound,
             requested: repo,
             suggestion: Module.concat(module, "Secondary")
           }
         }}

      _admissible ->
        :ok
    end
  end

  defp refuse_sink_drift(artifacts, existing, slot_name) do
    case Map.get(existing, :sink, :absent) do
      {:ash_replicant, bound} when is_binary(bound) and bound != slot_name ->
        module = Map.fetch!(artifacts, :sink)

        {:error,
         %Error{
           reason: :sink_slot_mismatch,
           artifact: module,
           detail: %{
             existing: bound,
             requested: slot_name,
             suggestion: Module.concat(module, "Secondary")
           }
         }}

      _admissible ->
        :ok
    end
  end

  defp refuse_pipeline_drift(artifacts, existing) do
    sink = Map.fetch!(artifacts, :sink)

    case Map.get(existing, :pipeline, :absent) do
      {:ash_replicant, bound} when not is_nil(bound) and bound != sink ->
        module = Map.fetch!(artifacts, :pipeline)

        {:error,
         %Error{
           reason: :pipeline_sink_mismatch,
           artifact: module,
           detail: %{
             existing: bound,
             requested: sink,
             suggestion: Module.concat(module, "Secondary")
           }
         }}

      _admissible ->
        :ok
    end
  end
end
