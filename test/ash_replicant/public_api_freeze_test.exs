defmodule AshReplicant.PublicApiFreezeTest do
  @moduledoc """
  D8 / PKG01: the public API inventory, frozen (ADR-0023).

  The PUBLIC surface is the module set below — everything a consumer can
  call. Every other module in the package is internal-by-convention: it
  ships (Elixir has no package-private), it is covered by tests, but it
  is NOT API and may change in any release. Adding a module or a public
  function to the PUBLIC set is a conscious SemVer decision: extend the
  inventory here AND the ADR, or the freeze reds. Removing or changing a
  listed signature is a breaking change requiring a major version.

  The inventory asserts each entry's presence AND its key function
  heads, so a rename or arity change inside the public surface cannot
  slip through as an internal refactor.
  """

  use ExUnit.Case, async: true

  @public_modules [
    # The operator surface
    {AshReplicant,
     [
       version: 0,
       start_link: 1,
       stop_supervised: 1,
       status: 1,
       preflight: 1,
       doctor: 1,
       adopt_checkpoint: 3,
       reset_checkpoint: 2,
       acknowledge_checkpoint_timeline: 3
     ]},
    # The sink DSL (use AshReplicant.Sink)
    {AshReplicant.Sink, []},
    # The resource DSL (replicant do ... end)
    {AshReplicant.Resource, []},
    # Reflection over the resource DSL
    {AshReplicant.Resource.Info, []},
    # The host-supervised lifecycle owner
    {AshReplicant.PipelineOwner, [start_link: 1, child_spec: 1]},
    # The derived-status evidence view under status/1
    {AshReplicant.Status, [derive: 1, derive: 2, status: 1, classify: 1]},
    # Declared destination participants (the host-implemented behaviour)
    {AshReplicant.DestinationParticipant, [operation_key: 2]},
    # The notifier wrapper hosts must route load statements through
    # The notifier wrapper hosts must route load statements through
    # (hosts wrap their notifiers with it; probe_load/3 is its admission probe)
    {AshReplicant.Notifier, [probe_load: 3]},
    # Generated internal resources (checkpoint) — the use-macro hosts call
    {AshReplicant.Checkpoint, []},
    # The generated pipeline supervisor module hosts supervise
    {AshReplicant.Pipeline, []},
    # Operator tooling
    {AshReplicant.Doctor, [run: 2]},
    {AshReplicant.Doctor.Report, []},
    {AshReplicant.Doctor.Check, []},
    {AshReplicant.Telemetry, [emitted_event_names: 0]},
    # The install planner (the Mix task renders it; both are API)
    {AshReplicant.Install, []},
    # The upgrade classifier/planner behind the package task
    {AshReplicant.Upgrade, []},
    {AshReplicant.Upgrade.Checkpoint, []},
    # The error struct every surface returns
    {AshReplicant.Error, []},
    # Mix tasks
    {Mix.Tasks.AshReplicant.Preflight, [run: 1]},
    {Mix.Tasks.AshReplicant.Doctor, [run: 1]},
    {Mix.Tasks.AshReplicant.Install, [run: 1]},
    {Mix.Tasks.AshReplicant.Upgrade, [run: 1]}
  ]

  test "every ADR-0023 public module ships (removal/renaming is a conscious API edit)" do
    shipped = shipped_ash_replicant_modules()

    for {module, _heads} <- @public_modules do
      assert module in shipped,
             "#{inspect(module)} is in the public inventory but no longer ships — a SemVer decision, extend ADR-0023"
    end
  end

  test "every public entry ships with its key function heads" do
    for {module, heads} <- @public_modules do
      assert Code.ensure_loaded?(module),
             "#{inspect(module)} is in the public inventory but does not load"

      for {name, arity} <- heads do
        assert function_exported?(module, name, arity),
               "#{inspect(module)}.#{name}/#{arity} is in the public inventory but is not exported"
      end
    end
  end

  # The application's shipped modules under the AshReplicant + Mix.Tasks
  # namespaces, excluding test-only fixtures (they live under
  # AshReplicant.Test and are never in the app's module list).
  defp shipped_ash_replicant_modules do
    {:ok, modules} = :application.get_key(:ash_replicant, :modules)

    modules
    |> Enum.filter(fn m ->
      name = Atom.to_string(m)

      String.starts_with?(name, "Elixir.AshReplicant") or
        String.starts_with?(name, "Elixir.Mix.Tasks.AshReplicant")
    end)
    |> MapSet.new()
  end
end
