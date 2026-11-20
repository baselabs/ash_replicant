# 14. Internal trust and lifecycle ownership: default-deny resources, one owner per generation

Date: 2026-08-18

## Status

Accepted. Governs roadmap B7 (`docs/ROADMAP.md` row "Secure internal
resources and pipeline lifecycle") and retires the gap-list row "Tenant-blind
layering and pipeline ownership" (this record is that decision). Every
generated internal resource and every lifecycle surface added later (C3
progress, D1 tooling) inherits this frame.

## Context

Two pre-B7 gaps, one frame.

**Internal resources were opt-in guarded.** The generated checkpoint
carried no authorizer unless the host passed `authorizers:
[Ash.Policy.Authorizer]` and then declared its own policies
(`lib/ash_replicant/checkpoint.ex` pre-B7, whose own moduledoc deferred to
B7). A host that exposed the resource on a wire surface — JSON:API route,
MCP tool, admin dashboard — had no enforcement at all: the checkpoint is an
internal watermark, not tenant data, and nothing outside the sink should
read or write it.

**The resolver generation had no owner.** `AshReplicant.start_link/1`
validated, prefetched, and wrote the `Generation` into `:persistent_term`
keyed by slot; `stop_supervised/1` erased it. Nothing monitored the
Replicant pipeline the generation admits. Replicant pipelines are
`:temporary` children of `Replicant.Supervisor` — a fail-closed halt
(`Replicant.Supervisor.halt/2`, teardown from an unlinked spawn) is
PERMANENT by design, and an exhausted `:one_for_all` crash or an external
`Replicant.stop/1` equally leaves no restart. Any of those left the
`:persistent_term` entry live forever: a **stale generation** that (a)
failed every later `start_link/1` with `:slot_already_active` and (b)
refused every offline operator function (`adopt_checkpoint`,
`reset_checkpoint`, `acknowledge_checkpoint_timeline`) — the two recovery
paths an operator needs exactly when a pipeline has died.

**The frame** (`AGENTS.md` Critical Rule 5): `replicant` is tenant-blind
and classification-blind transport; the adapter owns multitenancy,
classification, and admission. The generation IS the admission state —
which resolver index, which manifest, which source identity may write —
so owning it is adapter-layer work; monitoring a Replicant process is the
minimum transport-lifecycle touch needed to own it, and it observes only.

## Decision

1. **Generated internal resources are default-deny.** `use
   AshReplicant.Checkpoint` now generates the resource with
   `Ash.Policy.Authorizer` by default and NO policies. Ash policy
   semantics are fail-closed on the empty policy set — if no check
   authorizes the request, it is forbidden — so every external actor is
   denied every action. The sink and operator paths already read and
   write with `authorize?: false` (the internal locked reads, upserts,
   and destroys in `lib/ash_replicant.ex`; the checkpoint read/upsert in
   `AshReplicant.Sink.Impl`), so effect-once is unaffected by whatever
   the authorizer would say. Hosts opt out with `authorizers: []` (the
   pre-B7 shape, for hosts that already front the resource with their own
   authorization) or declare their own policies in the module body (the
   documented `system: true` actor pattern). Every future generated
   internal resource ships with the same default.
2. **One owner per live generation.** `AshReplicant.PipelineOwner` is a
   per-slot GenServer: `child_spec/1` makes it a `:temporary` child with
   id `{AshReplicant.PipelineOwner, slot_name}` under a host supervisor
   (a duplicate slot in one tree is then a supervisor-level start error,
   not a racing overwrite). Its `init` runs the whole activation chain —
   the same validation, preflights, activation lock, and error shapes as
   before — stores the generation with `owner: self()`, starts the
   Replicant pipeline, and **monitors** the pipeline pid. On `:DOWN` (a
   fail-closed halt, a crash, an external stop, a host-tree shutdown) it
   erases only its own generation (the existing compare-reference erase),
   clears the snapshot ordinals, and exits `:normal`. Replicant retains
   transport ownership: the owner never holds, restarts, or reconfigures
   the connection; it observes process death and cleans up admission
   state. The owner is unlinked from its caller: a bare caller finishing — or being
   shut down by its own test runner — must not take a live pipeline down
   mid-transaction (the pre-B7 pipeline likewise outlived its starter),
   while a host supervisor needs no link — it monitors the child and
   delivers tree shutdown as a direct `:shutdown` exit signal, which the
   trapping owner receives and honors by stopping its pipeline first.
3. **A dead owner is fail-closed and replaceable.** Callback admission
   (`run_admitted_callback`) checks owner liveness at entry: a generation
   whose owner is dead fails closed (`:config_invalid`, op `:callback`),
   and its lifetime guard stops the transport independently of further
   callbacks. Any attempted callback still halts fail-closed (Replicant
   halts on any non-ok sink return — the sink contract read
   first-hand in `deps/replicant/lib/replicant/sink.ex`). Activation and
   the offline operator functions treat a dead-owner entry as absent: the
   next `start_link/1` reaps any orphan pipeline and replaces the entry;
   `adopt`/`reset`/`acknowledge` proceed instead of wedging on
   `:slot_already_active`. "No stale generation" means no entry that
   still ADMITS effects or BLOCKS recovery; physical erasure of a
   dead-owner entry is lazy (there is no eager sweeper process by
   design — every consumer already refuses or replaces it).
4. **Duplicate starts cannot overwrite live configuration.** A live owner
   is the definition of live configuration: activation returns
   `:slot_already_active` whenever the entry's owner pid is alive, and
   the compare-reference erase makes every cleanup path incapable of
   touching another generation.
5. **Halt is permanent; restart is explicit.** The owner's restart type
   is `:temporary`, matching the pipeline's own `:temporary` discipline
   (a fail-closed halt must not auto-resurrect under anyone): restarting
   is an explicit host/operator act that re-runs the full admission.

### Operation drain and forced owner death

The library application supervises a node-local owner registry, lease registry
and per-owner lifetime guards. Lifecycle exclusivity covers activation, offline
operators,
`stop_supervised/1`, pending-owner reclamation and owner cleanup. Callbacks,
reads, the census and an owner's terminal write hold shared operation leases;
shared holders never wait on each other. Once a lifecycle writer queues, new
operations wait behind it. Holder and waiter monitors remove abandoned requests.

`stop_supervised/1` drains admitted operations, stops transport, reasserts its
terminal fact and erases admission under an exclusive hold, then releases the
hold before joining the owner. Owner cleanup takes the same exclusive hold;
joining while holding it would deadlock. An owner's terminal write holds a
shared lease and checks its generation, so stop drains it without a stale owner
writing over a successor. Cleanup reasserts the final terminal fact exclusively
after every admitted operation drains, preventing a late checkpoint advance from
clearing its durable record. Host-tree shutdown and census halts drain exclusively
before terminal recording and cleanup. Cleanup clears only its own generation.

The child's shutdown budget is `:infinity`: the census has a 10-second default
and 60-second maximum; a durable terminal write has a 5-second budget; sink
transactions declare 120-second database timeouts. None bounds arbitrary host
code inside an admitted callback, or time behind earlier lifecycle requests.
Adding finite database deadlines cannot bound the stop drain. A finite host
shutdown would therefore permit a brutal kill during an admitted operation.

A supervised lifetime guard monitors the owner independently of its mailbox. It
owns each monitored census worker and its deadline, so timeout still fires while
the owner waits for the exclusive lease. A deadline kills the worker even if it
traps exits; the guard retains the expired token until the owner classifies it,
so timeout classification does not depend on cross-process message ordering. Owner death cancels the deadline, kills
and joins the census, then terminates the exact monitored transport pid, never a
successor registered under the same slot. Normal cleanup cancels all schedules
and joins the census; the guard exits when its owner does. No cluster lock is
claimed: admission lives in node-local `:persistent_term`, local owner liveness
is required, and the former global-lock resource key included `node()`.

The application's `prep_stop/1` closes new activation, operator and callback
admission and signals owners to stop, then drains every slot already known to
the lease registry. This joins activations that were already creating owners before closure. It joins
all registered owners and lifetime guards before OTP terminates either
registry, preserving the same drain during library-application shutdown.

## Consequences

- A pipeline death of ANY origin (halt, crash, external stop) now frees
  the slot for re-activation and operator recovery immediately — the
  stale-generation wedge class is closed.
- An owner crash stops mirroring promptly: the lifetime guard stops the
  observed transport without waiting for another callback, and callback
  admission still fails closed. Mirroring continues only under a live owner. An operator or host restarts explicitly.
- A host-tree shutdown now stops pipelines owned by that tree (the
  supervisor's shutdown signal reaches the owner directly) — previously a
  pipeline outlived its starter process.
- `AshReplicant.start_link/1` now returns the owner's pid (not the
  pipeline's); both are opaque handles and `stop_supervised/1` is
  unchanged. The owner is not linked to the caller, so an owner crash is
  NOT propagated as a caller exit — it surfaces as the generation's
  fail-closed admission instead.
- Hosts relying on the unguarded checkpoint shape must pass
  `authorizers: []` or declare policies — a breaking, fail-safe default
  change recorded in the CHANGELOG.
- `replicant` stays tenant-blind: the owner monitors processes and owns
  adapter admission state; no tenant, classification, or row knowledge
  is added to the sibling (Critical Rule 5 unchanged, now with a named
  lifecycle owner on the adapter side).

## Evidence

- `deps/replicant/lib/replicant/supervisor.ex` — `:temporary` pipelines,
  `halt/2` permanent teardown from an unlinked spawn, registry-keyed
  terminate (read first-hand; the normative callback contract is
  `deps/replicant/lib/replicant/sink.ex` — every non-ok callback return
  halts fail-closed).
- `deps/replicant/lib/replicant/pipeline.ex` — `:one_for_all` per-slot
  supervisor registered as `{slot_name, :pipeline}` in
  `Replicant.Registry`.
- `lib/ash_replicant/pipeline_owner.ex` — the owner: `child_spec`
  (`:temporary`, per-slot id), init-time activation with preserved error
  shapes, pipeline monitor, `:DOWN` cleanup, EXIT semantics.
- `lib/ash_replicant.ex` — activation records `owner:`, activation and
  offline operator paths replace dead-owner entries and reap orphan
  pipelines, callback admission checks owner liveness.
- `lib/ash_replicant/destination.ex` — `Generation` carries `owner`.
- `lib/ash_replicant/checkpoint.ex` — the default-deny authorizer and
  the opt-out.
- `test/ash_replicant/pipeline_owner_test.exs` — the lifecycle
  invariants (supervised start/shutdown, halt cleanup, owner crash
  fail-closed + replacement, duplicate start, offline ops on a stale
  entry).
- `test/ash_replicant/checkpoint_policy_test.exs` +
  `test/integration/checkpoint_policy_test.exs` — the default-deny and
  sink-bypass proofs.
- `test/integration/source_coverage_test.exs` — the live-halt marquee:
  a real unmapped-column halt erases the generation and the slot
  re-activates.
