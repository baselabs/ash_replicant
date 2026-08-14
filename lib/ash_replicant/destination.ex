defmodule AshReplicant.Destination do
  @moduledoc false

  alias AshReplicant.DestinationParticipant
  alias AshReplicant.DestinationParticipant.{ActionRef, Context, ReplayIdentity}
  alias AshReplicant.Resource.Info
  alias Ecto.Adapters.SQL
  alias Spark.Dsl.Extension, as: DslExtension

  @core_code_modules [
    AshReplicant,
    AshReplicant.Apply,
    AshReplicant.Apply.Context,
    AshReplicant.Apply.Scd2,
    AshReplicant.Destination,
    AshReplicant.DestinationParticipant,
    AshReplicant.Error,
    AshReplicant.Resolver,
    AshReplicant.Resource.Info,
    AshReplicant.Sink,
    AshReplicant.Sink.Impl,
    AshReplicant.Telemetry
  ]

  defmodule Entry do
    @moduledoc false
    @enforce_keys [
      :role,
      :resource,
      :action,
      :source,
      :tenant_mode,
      :replay_identity,
      :protection
    ]
    defstruct [:role, :resource, :action, :source, :tenant_mode, :replay_identity, :protection]

    @type t :: %__MODULE__{
            role: atom(),
            resource: module(),
            action: atom(),
            source: module() | :framework,
            tenant_mode: :inherit,
            replay_identity: ReplayIdentity.t() | nil,
            protection: map() | nil
          }
  end

  defmodule Manifest do
    @moduledoc false
    @enforce_keys [:repo, :entries, :onetime_prefixes_by_action, :digest]
    defstruct [:repo, :entries, :onetime_prefixes_by_action, :digest]

    @type prefix :: nil | String.t() | :context_tenant
    @type action_key :: {module(), atom()}
    @type t :: %__MODULE__{
            repo: module(),
            entries: [Entry.t()],
            onetime_prefixes_by_action: %{optional(action_key()) => [prefix()]},
            digest: binary()
          }
  end

  defmodule Generation do
    @moduledoc false
    @enforce_keys [
      :reference,
      :sink,
      :sink_config,
      :sink_config_digest,
      :resolver_index,
      :manifest,
      :manifest_digest,
      :code_modules,
      :code_fingerprint,
      :source_identity,
      :publication,
      :dynamic_repo
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            reference: reference(),
            sink: module(),
            sink_config: map(),
            sink_config_digest: binary(),
            resolver_index: map(),
            manifest: Manifest.t(),
            manifest_digest: binary(),
            code_modules: [module()],
            code_fingerprint: binary(),
            source_identity: map(),
            publication: [String.t()],
            dynamic_repo: atom() | pid()
          }
  end

  @safe_changes [
    AshCloak.Changes.Encrypt,
    Ash.Resource.Change.Atomic,
    Ash.Resource.Change.AtomicSet,
    Ash.Resource.Change.Filter,
    Ash.Resource.Change.GetAndLock,
    Ash.Resource.Change.GetAndLockForUpdate,
    Ash.Resource.Change.Increment,
    Ash.Resource.Change.OptimisticLock,
    Ash.Resource.Change.PreventChange,
    Ash.Resource.Change.Select,
    Ash.Resource.Change.SetAttribute,
    Ash.Resource.Change.SetContext
  ]

  @safe_validations [
    Ash.Resource.Validation.ActionIs,
    Ash.Resource.Validation.All,
    Ash.Resource.Validation.Any,
    Ash.Resource.Validation.ArgumentDoesNotEqual,
    Ash.Resource.Validation.ArgumentEquals,
    Ash.Resource.Validation.ArgumentIn,
    Ash.Resource.Validation.AttributeDoesNotEqual,
    Ash.Resource.Validation.AttributeEquals,
    Ash.Resource.Validation.AttributeIn,
    Ash.Resource.Validation.AttributesPresent,
    Ash.Resource.Validation.ByteSize,
    Ash.Resource.Validation.Changing,
    Ash.Resource.Validation.Compare,
    Ash.Resource.Validation.Confirm,
    Ash.Resource.Validation.DataOneOf,
    Ash.Resource.Validation.Match,
    Ash.Resource.Validation.Negate,
    Ash.Resource.Validation.OneOf,
    Ash.Resource.Validation.Present,
    Ash.Resource.Validation.StringLength
  ]

  @safe_preparations [
    Ash.Resource.Preparation.Build,
    Ash.Resource.Preparation.SetContext
  ]

  @unsafe_function_modules [
    Ash.Resource.Change.AfterAction,
    Ash.Resource.Change.AfterTransaction,
    Ash.Resource.Change.BeforeAction,
    Ash.Resource.Change.BeforeTransaction,
    Ash.Resource.Change.Function,
    Ash.Resource.Preparation.AfterAction,
    Ash.Resource.Preparation.BeforeAction,
    Ash.Resource.Preparation.Function,
    Ash.Resource.Validation.Function,
    Ash.Resource.Validation.PreFlightAuthorization
  ]

  @relationship_changes [
    Ash.Resource.Change.ManageRelationship,
    Ash.Resource.Change.CascadeDestroy,
    Ash.Resource.Change.CascadeUpdate,
    Ash.Resource.Change.RelateActor
  ]

  @safe_default_callbacks [
    {Ash.UUID, :generate, 0},
    {Ash.UUIDv7, :generate, 0},
    {DateTime, :utc_now, 0}
  ]

  @safe_onetime_callbacks [
    AshOnetime.Codec.ActionResult,
    AshOnetime.Codec.JSON,
    AshOnetime.Codec.Resource
  ]

  @type reason ::
          {:invalid_destination_config, atom()}
          | {:destination_repo_mismatch, module()}
          | {:destination_repo_dynamic, module()}
          | {:destination_repo_not_postgres, module()}
          | {:destination_action_missing, module(), atom()}
          | {:destination_participant_required, module(), atom(), module()}
          | {:destination_participant_invalid, module()}
          | {:destination_participant_mismatch, module(), atom()}
          | {:destination_participant_cycle, module(), atom()}

  @spec manifest(map()) :: {:ok, Manifest.t()} | {:error, reason()}
  def manifest(%{repo: repo, domains: domains, checkpoint_resource: checkpoint})
      when is_atom(repo) and is_list(domains) and is_atom(checkpoint) do
    with :ok <- validate_repo_module(repo),
         {:ok, roots} <- root_actions(domains, checkpoint),
         {:ok, entries, onetime_prefixes_by_action} <- walk_roots(roots, repo),
         :ok <- validate_onetime_entries(entries) do
      entries =
        entries
        |> Enum.uniq()
        |> Enum.sort_by(&entry_sort_key/1)

      digest =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({repo, entries, onetime_prefixes_by_action}, [:deterministic])
        )

      {:ok,
       %Manifest{
         repo: repo,
         entries: entries,
         onetime_prefixes_by_action: onetime_prefixes_by_action,
         digest: digest
       }}
    end
  rescue
    _error -> {:error, {:invalid_destination_config, :reflection_failed}}
  catch
    _kind, _reason -> {:error, {:invalid_destination_config, :reflection_failed}}
  end

  def manifest(_), do: {:error, {:invalid_destination_config, :shape}}

  @doc false
  @spec config_digest(map()) :: binary()
  def config_digest(config),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(config, [:deterministic]))

  @doc false
  @spec code_modules(module(), Manifest.t()) :: {:ok, [module()]} | {:error, reason()}
  def code_modules(sink, %Manifest{} = manifest) when is_atom(sink) do
    modules =
      [sink, manifest | @core_code_modules]
      |> collect_modules(MapSet.new())
      |> then(fn modules ->
        Enum.reduce(manifest.entries, modules, fn entry, acc ->
          entry.resource
          |> resource_runtime_shape()
          |> collect_modules(acc)
        end)
      end)
      |> Enum.sort_by(&Atom.to_string/1)

    {:ok, modules}
  rescue
    _error -> {:error, {:invalid_destination_config, :code_fingerprint}}
  catch
    _kind, _reason -> {:error, {:invalid_destination_config, :code_fingerprint}}
  end

  @doc false
  @spec code_fingerprint([module()]) :: {:ok, binary()} | {:error, reason()}
  def code_fingerprint(modules) when is_list(modules) do
    fingerprints = Enum.map(modules, &{&1, module_fingerprint(&1)})
    {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(fingerprints, [:deterministic]))}
  rescue
    _error -> {:error, {:invalid_destination_config, :code_fingerprint}}
  catch
    _kind, _reason -> {:error, {:invalid_destination_config, :code_fingerprint}}
  end

  @doc false
  @spec effective_dynamic_repo(module()) ::
          {:ok, atom() | pid()} | {:error, {:invalid_destination_config, atom()}}
  def effective_dynamic_repo(repo) when is_atom(repo) do
    identity = repo.get_dynamic_repo()

    if dynamic_repo_owned_by?(repo, identity) do
      {:ok, identity}
    else
      {:error, {:invalid_destination_config, :effective_repo}}
    end
  rescue
    _error -> {:error, {:invalid_destination_config, :effective_repo}}
  catch
    _kind, _reason -> {:error, {:invalid_destination_config, :effective_repo}}
  end

  @doc false
  @spec preflight_onetime(Manifest.t(), atom() | pid()) ::
          :ok | {:error, {:invalid_destination_config, :onetime_store}}
  def preflight_onetime(%Manifest{} = manifest, dynamic_repo) do
    manifest.onetime_prefixes_by_action
    |> Map.values()
    |> List.flatten()
    |> Enum.reject(&(&1 == :context_tenant))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn prefix, :ok ->
      case preflight_onetime_relations(dynamic_repo, prefix) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, {:invalid_destination_config, :onetime_store}}}
      end
    end)
  rescue
    _error -> {:error, {:invalid_destination_config, :onetime_store}}
  catch
    _kind, _reason -> {:error, {:invalid_destination_config, :onetime_store}}
  end

  @doc false
  @spec preflight_onetime_transaction(
          Manifest.t(),
          atom() | pid(),
          term(),
          module(),
          atom()
        ) ::
          :ok | {:error, {:invalid_destination_config, :onetime_store}}
  def preflight_onetime_transaction(
        %Manifest{} = manifest,
        dynamic_repo,
        tenant,
        resource,
        action
      )
      when is_atom(resource) and is_atom(action) do
    context_tenant? =
      manifest.onetime_prefixes_by_action
      |> Map.get({resource, action}, [])
      |> Enum.member?(:context_tenant)

    cond do
      not context_tenant? ->
        :ok

      not (is_binary(tenant) and byte_size(tenant) in 1..63) ->
        {:error, {:invalid_destination_config, :onetime_store}}

      preflight_onetime_relations(dynamic_repo, tenant) == :ok ->
        :ok

      true ->
        {:error, {:invalid_destination_config, :onetime_store}}
    end
  rescue
    _error -> {:error, {:invalid_destination_config, :onetime_store}}
  catch
    _kind, _reason -> {:error, {:invalid_destination_config, :onetime_store}}
  end

  def preflight_onetime_transaction(_manifest, _dynamic_repo, _tenant, _resource, _action),
    do: {:error, {:invalid_destination_config, :onetime_store}}

  @doc false
  @spec dynamic_repo_owned_by?(module(), atom() | pid()) :: boolean()
  def dynamic_repo_owned_by?(repo, repo), do: true

  def dynamic_repo_owned_by?(repo, identity) when is_atom(identity) or is_pid(identity) do
    %{repo: owner} = Ecto.Repo.Registry.lookup(identity)
    owner == repo
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  def dynamic_repo_owned_by?(_repo, _identity), do: false

  @doc false
  def __after_compile__(env, _bytecode) do
    config = env.module.__ash_replicant_config__()

    case manifest(config) do
      {:ok, _manifest} ->
        :ok

      {:error, reason} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "unsafe AshReplicant destination: #{inspect(reason)}"
    end
  end

  defp root_actions(domains, checkpoint) do
    with {:ok, mapped_roots} <- mapped_root_actions(domains),
         {:ok, checkpoint_read} <- required_primary_action(checkpoint, :read) do
      {:ok,
       mapped_roots ++
         [
           root_ref(checkpoint, checkpoint_read, :checkpoint),
           root_ref(checkpoint, :upsert, :checkpoint)
         ]}
    end
  end

  defp walk_roots(roots, repo) do
    Enum.reduce_while(roots, {:ok, [], %{}}, fn root, {:ok, all_entries, prefixes_by_action} ->
      case walk([root], repo, %{}, %{}, []) do
        {:ok, _completed, entries} ->
          {resource, action, _role, _source, _tenant_mode, _replay_identity} = root

          prefixes =
            entries
            |> Enum.filter(&is_map(&1.protection))
            |> Enum.map(&onetime_static_prefix/1)
            |> Enum.uniq()
            |> Enum.sort_by(&prefix_sort_key/1)

          prefixes_by_action =
            Map.update(
              prefixes_by_action,
              {resource, action},
              prefixes,
              &merge_prefixes(&1, prefixes)
            )

          {:cont, {:ok, entries ++ all_entries, prefixes_by_action}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp prefix_sort_key(nil), do: {0, ""}
  defp prefix_sort_key(:context_tenant), do: {1, ""}
  defp prefix_sort_key(prefix) when is_binary(prefix), do: {2, prefix}

  defp merge_prefixes(existing, additional) do
    existing
    |> Kernel.++(additional)
    |> Enum.uniq()
    |> Enum.sort_by(&prefix_sort_key/1)
  end

  defp mapped_root_actions(domains) do
    domains
    |> destination_resources()
    |> Enum.reduce_while({:ok, []}, fn resource, {:ok, roots} ->
      case mapped_resource_roots(resource) do
        {:ok, resource_roots} -> {:cont, {:ok, resource_roots ++ roots}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp destination_resources(domains) do
    domains
    |> AshReplicant.Resolver.domain_resources()
    |> Enum.filter(&replicant_destination_resource?/1)
  end

  # UNRESCUED twin of the resolver index's filter: a module whose reflection
  # raises fails the manifest (`:reflection_failed`) here, while the index
  # skips it — activation must never silently drop a declared resource.
  # Defensive depth: Ash.Domain's compile-time Spark verification makes the
  # stance unreachable through a well-formed domain; the enumeration-set pin
  # in destination_test.exs covers the reachable drift class.
  defp replicant_destination_resource?(resource),
    do: AshReplicant.Resource in Spark.extensions(resource)

  defp mapped_resource_roots(resource) do
    with {:ok, read} <- required_primary_action(resource, :read),
         {:ok, create} <- required_primary_action(resource, :create),
         {:ok, destroy} <- required_primary_action(resource, :destroy) do
      base = Enum.map([read, create, destroy], &root_ref(resource, &1, :mapped))

      if Info.history_scd2?(resource) do
        {:ok,
         [
           root_ref(resource, Info.replicant_history_close_action!(resource), :history_close)
           | base
         ]}
      else
        {:ok, base}
      end
    end
  end

  defp resource_runtime_shape(resource) do
    if function_exported?(resource, :spark_dsl_config, 0) do
      {resource, resource.spark_dsl_config()}
    else
      resource
    end
  end

  defp collect_modules(term, modules) when is_function(term) do
    module = term |> Function.info(:module) |> elem(1)
    MapSet.put(modules, module)
  end

  defp collect_modules(term, modules) when is_atom(term) do
    if module?(term), do: MapSet.put(modules, term), else: modules
  end

  defp collect_modules(term, modules) when is_list(term),
    do: Enum.reduce(term, modules, &collect_modules/2)

  defp collect_modules(term, modules) when is_tuple(term),
    do: term |> Tuple.to_list() |> collect_modules(modules)

  defp collect_modules(term, modules) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.reduce(modules, fn {key, value}, acc ->
      acc = collect_modules(key, acc)
      collect_modules(value, acc)
    end)
  end

  defp collect_modules(_term, modules), do: modules

  defp module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :module_info, 1)
  end

  defp module_fingerprint(module) do
    case :code.get_object_code(module) do
      {^module, bytecode, _path} -> :crypto.hash(:sha256, bytecode)
      :error -> module.module_info(:md5)
    end
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp required_primary_action(resource, type) do
    case Ash.Resource.Info.primary_action(resource, type) do
      nil -> {:error, {:destination_action_missing, resource, type}}
      action -> {:ok, action.name}
    end
  end

  defp walk([], _repo, _active, completed, entries), do: {:ok, completed, entries}

  defp walk(
         [
           {resource, action_name, role, source, tenant_mode, replay_identity}
           | rest
         ],
         repo,
         active,
         completed,
         entries
       ) do
    key = {resource, action_name}
    protection = normalized_protection(resource, action_name)

    entry = %Entry{
      role: role,
      resource: resource,
      action: action_name,
      source: source,
      tenant_mode: tenant_mode,
      replay_identity: replay_identity,
      protection: protection
    }

    cond do
      Map.has_key?(active, key) ->
        {:error, {:destination_participant_cycle, resource, action_name}}

      Map.has_key?(completed, key) ->
        walk(rest, repo, active, completed, [entry | entries])

      true ->
        with :ok <- validate_resource_repo(resource, repo),
             %{} = action <- Ash.Resource.Info.action(resource, action_name),
             {:ok, refs} <- inspect_action(resource, action),
             :ok <- validate_touches(resource, action, refs),
             {:ok, completed, entries} <-
               walk(
                 participant_roots(refs),
                 repo,
                 Map.put(active, key, true),
                 completed,
                 [entry | entries]
               ) do
          walk(rest, repo, active, Map.put(completed, key, true), entries)
        else
          nil -> {:error, {:destination_action_missing, resource, action_name}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp participant_roots(refs) do
    Enum.map(refs, fn {%ActionRef{} = ref, ref_source} ->
      {
        ref.resource,
        ref.action,
        :auxiliary,
        ref_source,
        ref.tenant_mode,
        ref.replay_identity
      }
    end)
  end

  defp inspect_action(resource, action) do
    context = %Context{resource: resource, action: action.name, kind: :manual}

    with {:ok, manual_refs} <- inspect_manual(action_implementation(action), context),
         {:ok, callback_refs} <- inspect_action_callbacks(action, context),
         {:ok, type_refs} <- inspect_action_types(resource, action),
         :ok <- inspect_tenant_resolver(resource, action),
         {:ok, change_refs} <-
           inspect_items(
             resource,
             action,
             Ash.Resource.Info.action_changes(resource, action),
             :change
           ),
         {:ok, validation_refs} <-
           inspect_items(resource, action, action_validations(resource, action), :validation),
         {:ok, preparation_refs} <-
           inspect_items(resource, action, action_preparations(resource, action), :preparation) do
      {:ok,
       manual_refs ++
         callback_refs ++ type_refs ++ change_refs ++ validation_refs ++ preparation_refs}
    end
  end

  defp inspect_action_callbacks(action, context) do
    [:modify_query, :error_handler]
    |> Enum.map(&Map.get(action, &1))
    |> Enum.reduce_while({:ok, []}, fn callback, {:ok, refs} ->
      case inspect_callback(callback, %{context | kind: :callback}) do
        {:ok, found} -> {:cont, {:ok, refs ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp inspect_callback(nil, _context), do: {:ok, []}

  defp inspect_callback({module, function, args}, context)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: inspect_provider(module, [function: function], context)

  defp inspect_callback(_callback, context),
    do: {:error, {:destination_participant_required, context.resource, context.action, Function}}

  defp inspect_action_types(resource, action) do
    fields =
      Ash.Resource.Info.attributes(resource) ++
        action.arguments ++
        accepted_attributes(resource, action) ++
        runtime_default_attributes(resource, action) ++
        Map.get(action, :metadata, []) ++ return_type(action)

    fields = Enum.uniq(fields)

    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, refs} ->
      context = %Context{resource: resource, action: action.name, kind: :type}

      with {:ok, found} <- inspect_type(field.type, Map.get(field, :constraints, []), context),
           {:ok, defaults} <- inspect_field_defaults(field, action, context) do
        {:cont, {:ok, refs ++ found ++ defaults}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp accepted_attributes(resource, action) do
    action
    |> Map.get(:accept, [])
    |> List.wrap()
    |> Enum.map(&Ash.Resource.Info.attribute(resource, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp runtime_default_attributes(resource, %{type: :create}) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(&(not is_nil(&1.default) or not is_nil(&1.update_default)))
  end

  defp runtime_default_attributes(resource, %{type: :update}) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(&(not is_nil(&1.update_default)))
  end

  defp runtime_default_attributes(resource, %{type: :destroy, soft?: true}) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(&(not is_nil(&1.update_default)))
  end

  defp runtime_default_attributes(_resource, _action), do: []

  defp return_type(%{type: :action, returns: nil}), do: []

  defp return_type(%{type: :action} = action) do
    [%{type: action.returns, constraints: Map.get(action, :constraints, [])}]
  end

  defp return_type(_action), do: []

  defp inspect_type(type, constraints, context),
    do: inspect_type(type, constraints, context, %{})

  defp inspect_type({:array, type}, constraints, context, seen) do
    inspect_type(type, Keyword.get(constraints, :items, []), context, seen)
  end

  defp inspect_type(type, constraints, context, seen) do
    module = Ash.Type.get_type!(type)
    key = {module, constraints}

    if Map.has_key?(seen, key) do
      {:ok, []}
    else
      seen = Map.put(seen, key, true)

      with {:ok, own_refs} <- inspect_type_module(module, constraints, context),
           {:ok, nested_refs} <- inspect_referenced_types(module, constraints, context, seen) do
        {:ok, own_refs ++ nested_refs}
      end
    end
  end

  defp inspect_type_module(module, constraints, context) do
    if Ash.Type.builtin?(module),
      do: {:ok, []},
      else: inspect_provider(module, constraints, context)
  end

  defp inspect_referenced_types(module, constraints, context, seen) do
    references =
      if function_exported?(module, :referenced_types, 1),
        do: module.referenced_types(constraints),
        else: []

    Enum.reduce_while(references, {:ok, []}, fn {type, nested_constraints, _via}, {:ok, refs} ->
      case inspect_type(type, nested_constraints, context, seen) do
        {:ok, found} -> {:cont, {:ok, refs ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp inspect_field_defaults(%Ash.Resource.Attribute{} = field, %{type: :create}, context),
    do: inspect_defaults(field, [:default, :update_default], context)

  defp inspect_field_defaults(%Ash.Resource.Attribute{} = field, %{type: :update}, context),
    do: inspect_defaults(field, [:update_default], context)

  defp inspect_field_defaults(
         %Ash.Resource.Attribute{} = field,
         %{type: :destroy, soft?: true},
         context
       ),
       do: inspect_defaults(field, [:update_default], context)

  defp inspect_field_defaults(%Ash.Resource.Attribute{} = _field, _action, _context),
    do: {:ok, []}

  defp inspect_field_defaults(field, _action, context),
    do: inspect_defaults(field, [:default], context)

  defp inspect_defaults(field, keys, context) do
    keys
    |> Enum.map(&Map.get(field, &1))
    |> Enum.reduce_while({:ok, []}, fn default, {:ok, refs} ->
      case inspect_default(default, %{context | kind: :callback}) do
        {:ok, found} -> {:cont, {:ok, refs ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp inspect_default(nil, _context), do: {:ok, []}

  defp inspect_default(default, context) when is_function(default) do
    module = default |> Function.info(:module) |> elem(1)
    name = default |> Function.info(:name) |> elem(1)
    arity = default |> Function.info(:arity) |> elem(1)

    cond do
      {module, name, arity} in @safe_default_callbacks ->
        {:ok, []}

      generated_default?(module, name, context) ->
        {:error, {:destination_participant_required, context.resource, context.action, Function}}

      true ->
        inspect_provider(module, [function: name, arity: arity], context)
    end
  end

  defp inspect_default({module, function, args}, context)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: inspect_provider(module, [function: function, arity: length(args)], context)

  defp inspect_default(_literal, _context), do: {:ok, []}

  defp generated_default?(module, name, context) do
    value = Atom.to_string(name)

    String.starts_with?(value, "-") or
      (module == context.resource and
         (String.starts_with?(value, "default_") or
            String.starts_with?(value, "update_default_")) and
         String.contains?(value, "_generated_"))
  end

  defp inspect_tenant_resolver(resource, action)
       when action.type in [:create, :update, :destroy] do
    if AshReplicant.Resource in Spark.extensions(resource) do
      inspect_tenant_mfa(Info.replicant_tenant_mfa(resource), resource, action)
    else
      :ok
    end
  end

  defp inspect_tenant_resolver(_resource, _action), do: :ok

  defp inspect_tenant_mfa(
         {:ok, {module, function, args}},
         resource,
         action
       )
       when is_atom(module) and is_atom(function) and is_list(args) do
    context = %Context{resource: resource, action: action.name, kind: :tenant_resolver}

    case inspect_provider(module, [function: function], context) do
      {:ok, []} -> :ok
      {:ok, _refs} -> {:error, {:destination_participant_invalid, module}}
      {:error, _reason} = error -> error
    end
  end

  defp inspect_tenant_mfa(_mfa, _resource, _action), do: :ok

  defp inspect_manual(nil, _context), do: {:ok, []}

  defp inspect_manual({AshOnetime.GenericAction, opts}, context) do
    with :ok <- validate_wrapper_protection(opts, context),
         {:ok, protection_refs} <- inspect_onetime_protection(context),
         {:ok, original_refs} <- inspect_manual(Keyword.get(opts, :original), context) do
      {:ok, protection_refs ++ original_refs}
    end
  end

  defp inspect_manual({module, opts}, context), do: inspect_provider(module, opts, context)

  defp inspect_manual(module, context) when is_atom(module),
    do: inspect_provider(module, [], context)

  defp inspect_manual(_other, context),
    do: {:error, {:destination_participant_required, context.resource, context.action, Function}}

  defp inspect_items(resource, action, items, kind) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, refs} ->
      {module, opts, actual_kind} = item_module_opts(item, kind)
      context = %Context{resource: resource, action: action.name, kind: actual_kind}

      with {:ok, found} <- inspect_item(module, opts, context),
           {:ok, conditional} <- inspect_raw_items(Map.get(item, :where, []), context) do
        {:cont, {:ok, refs ++ found ++ conditional}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp inspect_raw_items(items, context) do
    Enum.reduce_while(List.wrap(items), {:ok, []}, fn item, {:ok, refs} ->
      {module, opts} = raw_module_opts(item)

      case inspect_item(module, opts, %{context | kind: :validation}) do
        {:ok, found} -> {:cont, {:ok, refs ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp inspect_item(module, opts, context)
       when module in [Ash.Resource.Validation.All, Ash.Resource.Validation.Any] do
    inspect_raw_items(Keyword.get(opts, :validations, []), context)
  end

  defp inspect_item(Ash.Resource.Validation.Negate, opts, context) do
    inspect_raw_items([Keyword.get(opts, :validation)], context)
  end

  defp inspect_item(module, opts, context)
       when module in [Ash.Resource.Change.SetContext, Ash.Resource.Preparation.SetContext] do
    inspect_set_context(Keyword.get(opts, :context), module, context)
  end

  defp inspect_item(module, opts, context)
       when module in [AshOnetime.Change, AshOnetime.GenericAction] do
    case validate_wrapper_protection(opts, context) do
      :ok -> inspect_onetime_protection(context)
      {:error, _reason} = error -> error
    end
  end

  defp inspect_item(module, _opts, _context)
       when module in @safe_changes or module in @safe_validations or
              module in @safe_preparations,
       do: {:ok, []}

  defp inspect_item(module, opts, context) when module in @relationship_changes,
    do: relationship_refs(module, opts, context)

  defp inspect_item(module, opts, context) when module in @unsafe_function_modules,
    do: inspect_provider(module, opts, context)

  defp inspect_item(module, opts, context) when is_atom(module) do
    inspect_provider(module, opts, context)
  end

  # An MFA (dynamic) context cannot be inspected statically: it is admissible
  # ONLY through the DestinationParticipant escape hatch — the module behind the
  # MFA declares its effects like any other opaque module. A static map is
  # admitted only when it does not replace :data_layer.
  defp inspect_set_context({provider, _fun, _args}, _set_context_module, context)
       when is_atom(provider),
       do: inspect_provider(provider, [], context)

  defp inspect_set_context(context_value, set_context_module, context) do
    if safe_context?(context_value) do
      {:ok, []}
    else
      {:error,
       {:destination_participant_invalid, context.resource, context.action, set_context_module}}
    end
  end

  defp safe_context?(context) when is_map(context),
    do: not Map.has_key?(context, :data_layer) and not Map.has_key?(context, "data_layer")

  defp safe_context?(_context), do: false

  defp inspect_provider(module, opts, context) when is_atom(module) do
    if participant?(module) do
      case module.destination_participants(opts, context) do
        {:ok, :no_database} -> {:ok, []}
        {:ok, {:actions, [_ | _] = refs}} -> validate_refs(refs, module)
        _other -> {:error, {:destination_participant_invalid, module}}
      end
    else
      {:error, {:destination_participant_required, context.resource, context.action, module}}
    end
  rescue
    _error -> {:error, {:destination_participant_invalid, module}}
  catch
    _kind, _reason -> {:error, {:destination_participant_invalid, module}}
  end

  defp inspect_provider(_module, _opts, context),
    do: {:error, {:destination_participant_required, context.resource, context.action, Function}}

  defp validate_refs(refs, module) do
    if Enum.all?(refs, fn
         %ActionRef{
           resource: resource,
           action: action,
           tenant_mode: :inherit,
           replay_identity: replay_identity
         }
         when is_atom(resource) and is_atom(action) ->
           valid_replay_identity?(replay_identity)

         _other ->
           false
       end) do
      {:ok, Enum.map(refs, &{&1, module})}
    else
      {:error, {:destination_participant_invalid, module}}
    end
  end

  defp valid_replay_identity?(nil), do: true

  defp valid_replay_identity?(%ReplayIdentity{components: [_ | _] = components, participant: p})
       when is_atom(p) and p not in [nil, true, false] do
    components == [
      :source_system_identifier,
      :source_database,
      :slot_name,
      :commit_lsn,
      :ordinal,
      :participant
    ]
  end

  defp valid_replay_identity?(_other), do: false

  @doc false
  @spec validate_onetime_entries([Entry.t()]) :: :ok | {:error, reason()}
  def validate_onetime_entries(entries) do
    entries
    |> Enum.filter(&is_map(&1.protection))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case validate_onetime_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_onetime_entry(%Entry{
         role: :auxiliary,
         resource: resource,
         action: action_name,
         replay_identity: %ReplayIdentity{participant: participant} = replay_identity,
         protection: protection
       }) do
    action = Ash.Resource.Info.action(resource, action_name)

    with true <- valid_replay_identity?(replay_identity),
         true <- protection.strategy == :idempotency,
         true <- protection.commit == :with_action,
         true <- protection.on_definite_store_failure == :fail_closed,
         true <- is_nil(protection.external_effect),
         true <- protection.key == [{:argument, :operation_key}],
         true <- protection.scope == replay_scope(participant),
         true <- private_operation_key?(action),
         true <- valid_onetime_response?(protection.response),
         true <- effect_free_cache?() do
      :ok
    else
      _other -> {:error, {:destination_participant_invalid, AshOnetime.Resource}}
    end
  end

  defp validate_onetime_entry(%Entry{}),
    do: {:error, {:destination_participant_invalid, AshOnetime.Resource}}

  defp replay_scope(participant) do
    [
      {:static, "ash_replicant:destination-participant:1"},
      {:static, Atom.to_string(participant)}
    ]
  end

  defp private_operation_key?(%{arguments: arguments}) do
    Enum.any?(arguments, fn argument ->
      argument.name == :operation_key and argument.public? == false and
        argument.allow_nil? == false and Ash.Type.get_type!(argument.type) == Ash.Type.String
    end)
  end

  defp private_operation_key?(_action), do: false

  defp onetime_static_prefix(%Entry{resource: resource}) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :context do
      :context_tenant
    else
      AshPostgres.DataLayer.Info.schema(resource)
    end
  end

  defp preflight_onetime_relations(dynamic_repo, prefix) do
    claims = qualified_relation(prefix, "ash_onetime_idempotency_claims")
    responses = qualified_relation(prefix, "ash_onetime_response_payloads")

    sql = """
    SELECT
      to_regclass($1) IS NOT NULL,
      to_regclass($2) IS NOT NULL,
      EXISTS (
        SELECT 1
        FROM pg_inherits
        WHERE inhparent = to_regclass($2)
      )
    """

    case SQL.query(dynamic_repo, sql, [claims, responses]) do
      {:ok, %{rows: [[true, true, true]]}} -> :ok
      _other -> :error
    end
  end

  defp qualified_relation(nil, relation), do: quote_ident(relation)

  defp qualified_relation(prefix, relation) when is_binary(prefix),
    do: quote_ident(prefix) <> "." <> quote_ident(relation)

  defp quote_ident(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")

  defp valid_onetime_response?(%{codec: codec, classify: classifier})
       when is_atom(codec) and is_atom(classifier),
       do: true

  defp valid_onetime_response?(_response), do: false

  defp effect_free_cache?,
    do: Application.get_env(:ash_onetime, :cache, AshOnetime.Cache.None) == AshOnetime.Cache.None

  defp relationship_refs(module, opts, context) do
    relationship_name = Keyword.get(opts, :relationship)

    case Ash.Resource.Info.relationship(context.resource, relationship_name) do
      %{destination: destination} = relationship ->
        relationship_action_refs(module, opts, relationship, destination)

      _other ->
        {:error, {:destination_participant_invalid, module}}
    end
  end

  defp relationship_action_refs(Ash.Resource.Change.ManageRelationship, opts, relationship, _) do
    manage_opts = Keyword.get(opts, :opts, [])

    managed_relationship_refs(manage_opts, relationship)
  end

  defp relationship_action_refs(Ash.Resource.Change.RelateActor, _opts, relationship, _) do
    if relationship.type == :belongs_to do
      {:ok, []}
    else
      manage_opts =
        :append_and_remove
        |> Ash.Changeset.manage_relationship_opts()
        |> Keyword.put(:authorize?, false)

      managed_relationship_refs(manage_opts, relationship)
    end
  end

  defp relationship_action_refs(module, opts, relationship, destination) do
    type = if module == Ash.Resource.Change.CascadeDestroy, do: :destroy, else: :update

    action_name =
      Keyword.get(opts, :action) || Ash.Resource.Info.primary_action!(destination, type).name

    action = Ash.Resource.Info.action(destination, action_name)

    read_action =
      Keyword.get(opts, :read_action) ||
        Map.get(relationship, :read_action) ||
        Map.get(action || %{}, :atomic_upgrade_with) ||
        Ash.Resource.Info.primary_action!(destination, :read).name

    {:ok,
     [
       {%ActionRef{resource: destination, action: read_action}, :framework},
       {%ActionRef{resource: destination, action: action_name}, :framework}
     ]}
  end

  defp managed_relationship_refs(manage_opts, relationship) do
    helper = Ash.Changeset.ManagedRelationshipHelpers

    refs =
      [
        helper.on_match_destination_actions(manage_opts, relationship),
        helper.on_no_match_destination_actions(manage_opts, relationship),
        helper.on_missing_destination_actions(manage_opts, relationship),
        helper.on_lookup_update_action(manage_opts, relationship),
        helper.on_lookup_read_action(manage_opts, relationship)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&managed_action_ref(&1, relationship))
      |> Enum.uniq()

    {:ok, Enum.map(refs, &{&1, :framework})}
  rescue
    _error -> {:error, {:destination_participant_invalid, Ash.Resource.Change.ManageRelationship}}
  end

  defp managed_action_ref({:destination, action}, relationship),
    do: %ActionRef{resource: relationship.destination, action: action}

  defp managed_action_ref({:join, action, _keys}, relationship),
    do: %ActionRef{resource: relationship.through, action: action}

  defp validate_touches(resource, action, refs) do
    declared = action.touches_resources |> List.wrap() |> MapSet.new()

    discovered =
      refs |> Enum.map(fn {%ActionRef{} = ref, _source} -> ref.resource end) |> MapSet.new()

    if MapSet.equal?(declared, discovered) do
      :ok
    else
      {:error, {:destination_participant_mismatch, resource, action.name}}
    end
  end

  defp validate_resource_repo(resource, repo) do
    raw = DslExtension.get_opt(resource, [:postgres], :repo, nil, false)
    configured = DslExtension.get_opt(resource, [:postgres], :repo, nil, true)

    cond do
      Ash.Resource.Info.data_layer(resource) != AshPostgres.DataLayer ->
        {:error, {:destination_repo_not_postgres, resource}}

      is_function(raw) or is_function(configured) ->
        {:error, {:destination_repo_dynamic, resource}}

      raw != repo ->
        {:error, {:destination_repo_mismatch, resource}}

      AshPostgres.DataLayer.Info.repo(resource, :read) != repo ->
        {:error, {:destination_repo_mismatch, resource}}

      AshPostgres.DataLayer.Info.repo(resource, :mutate) != repo ->
        {:error, {:destination_repo_mismatch, resource}}

      true ->
        :ok
    end
  end

  defp validate_repo_module(repo) do
    Code.ensure_loaded(repo)

    behaviours = repo.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    cond do
      AshPostgres.Repo not in behaviours ->
        {:error, {:invalid_destination_config, :repo}}

      repo.__adapter__() != Ecto.Adapters.Postgres ->
        {:error, {:invalid_destination_config, :adapter}}

      true ->
        :ok
    end
  rescue
    _error -> {:error, {:invalid_destination_config, :repo}}
  end

  defp action_validations(resource, action) do
    global =
      if action.type in [:read, :create, :update, :destroy],
        do: Ash.Resource.Info.validations(resource, action.type),
        else: []

    global ++ Map.get(action, :validations, [])
  end

  defp action_preparations(resource, %{type: :read} = action),
    do: Ash.Resource.Info.preparations(resource, :read) ++ Map.get(action, :preparations, [])

  defp action_preparations(resource, %{type: :action} = action),
    do: Ash.Resource.Info.preparations(resource, :action) ++ Map.get(action, :preparations, [])

  defp action_preparations(_resource, _action), do: []

  defp item_module_opts(item, fallback_kind) do
    kind =
      Enum.find([:change, :validation, :preparation], fallback_kind, fn field ->
        not is_nil(Map.get(item, field))
      end)

    value = Map.get(item, kind)

    case value do
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts, kind}
      module when is_atom(module) -> {module, [], kind}
      _other -> {Function, [], kind}
    end
  end

  defp raw_module_opts({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp raw_module_opts(module) when is_atom(module), do: {module, []}
  defp raw_module_opts(_other), do: {Function, []}

  defp participant?(module) do
    behaviours = module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    function_exported?(module, :destination_participants, 2) and
      DestinationParticipant in behaviours
  rescue
    _error -> false
  end

  defp action_implementation(%{type: :action} = action), do: Map.get(action, :run)
  defp action_implementation(action), do: Map.get(action, :manual)

  defp validate_wrapper_protection(opts, context) do
    declared = AshOnetime.Resource.Info.protection(context.resource, context.action)

    if declared && Keyword.get(opts, :protection) == declared do
      :ok
    else
      {:error, {:destination_participant_invalid, AshOnetime.Resource}}
    end
  end

  defp inspect_onetime_protection(context) do
    case AshOnetime.Resource.Info.protection(context.resource, context.action) do
      %{external_effect: external_effect} when not is_nil(external_effect) ->
        {:error, {:destination_participant_invalid, external_effect}}

      protection when is_map(protection) ->
        protection
        |> onetime_callback_modules()
        |> inspect_onetime_callbacks(context)

      _other ->
        {:error, {:destination_participant_invalid, AshOnetime.Resource}}
    end
  end

  defp inspect_onetime_callbacks(callbacks, context) do
    Enum.reduce_while(callbacks, {:ok, []}, fn {module, opts}, {:ok, refs} ->
      case inspect_onetime_callback(module, opts, %{context | kind: :callback}) do
        {:ok, found} -> {:cont, {:ok, refs ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp onetime_callback_modules(protection) do
    scope_modules =
      for {:tenant, module} <- List.wrap(protection.scope), do: {module, [function: :resolve]}

    key_modules =
      protection.key
      |> List.wrap()
      |> Enum.flat_map(fn
        {:verified, _name, module} -> [{module, [function: :verify]}]
        {:minted, module} -> [{module, [function: :mint]}]
        _source -> []
      end)

    response_modules =
      case protection.response do
        %{codec: codec, classify: classifier} ->
          [{codec, [function: :encode]}, {classifier, [function: :classify]}]

        _other ->
          []
      end

    Enum.uniq(scope_modules ++ key_modules ++ response_modules)
  end

  defp inspect_onetime_callback(module, _opts, _context)
       when module in @safe_onetime_callbacks,
       do: {:ok, []}

  defp inspect_onetime_callback(module, opts, context),
    do: inspect_provider(module, opts, context)

  defp normalized_protection(resource, action) do
    case AshOnetime.Resource.Info.protection(resource, action) do
      nil -> nil
      protection -> normalize_structural(protection)
    end
  end

  defp normalize_structural(%_module{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__spark_metadata__)
    |> normalize_structural()
  end

  defp normalize_structural(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, normalize_structural(value)} end)
  end

  defp normalize_structural(list) when is_list(list), do: Enum.map(list, &normalize_structural/1)

  defp normalize_structural(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&normalize_structural/1) |> List.to_tuple()

  defp normalize_structural(other), do: other

  defp root_ref(resource, action, role),
    do: {resource, action, role, :framework, :inherit, nil}

  defp entry_sort_key(entry) do
    {
      Atom.to_string(entry.resource),
      Atom.to_string(entry.action),
      Atom.to_string(entry.role),
      inspect(entry.source),
      :erlang.term_to_binary(entry.replay_identity),
      :erlang.term_to_binary(entry.protection)
    }
  end
end
