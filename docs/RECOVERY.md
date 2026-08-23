# Recovery states — the fault → state → operator matrix

Every control-plane fault this adapter can hit, the state it surfaces
(`AshReplicant.status/1` plus the durable lifecycle tombstone), what the
pipeline does on its own, and what an operator owes. Everything here is
value-free: statuses and halt reasons are closed atom vocabularies, never row
or message bytes.

How to read a state:

- `:healthy` — a live owner AND pipeline AND an enabled census whose last run
  passed, no in-flight snapshot.
- `:catching_up` — live and working (activation, census not yet passed,
  snapshot in flight, or an owner busy past the status-call timeout). Includes
  the self-healing window after a transient source disconnect.
- `{:halted, reason}` — mirroring stopped permanently (restart is explicit).
- `{:misconfigured, reason}` — halted on a configuration fault an operator
  fixes in configuration (identity, contract, mapping).
- `:not_started` — no generation and a stopped-class (or absent) tombstone.

One halt event can carry two names: the `replicant` transport telemetry
(`:sink_failed`, `:checkpoint_unknown`, …) and this library's tombstone cause
on the operator surface (`AshReplicant.status/1`, the checkpoint row's
terminal columns). The matrix names both where they differ.

## The matrix

| Fault | Surfaced state | Pipeline behavior | Operator action | Safety property preserved |
|---|---|---|---|---|
| Source disconnect (walsender death, socket drop, failover blip) | Invisible to the derived status — it stays `:healthy` (last census passed) or `:catching_up`; never a halt | Self-healed: the connection reconnects in-process, re-verifies the actual session identity, re-classifies the durable contract (unchanged ⇒ verify-only, no write), resumes from `max(durable checkpoint, confirmed_flush)` | None | WAL committed during the outage streams through; effects stay exactly-once (watermark skip + per-row upserts); the generation and owner are untouched |
| Session identity mismatch at connect/reconnect | `{:misconfigured, :source_identity_rebound}` (a foreign row under the slot: `:source_identity_rebound`; a wrong expectation: `:source_identity_mismatch`) | Halted before checkpoint lookup | Reconcile the configured identity with the actual source, or rebind deliberately via `reset_checkpoint/2`; restart explicitly | A watermark can never be replayed against a different database |
| Owner death, WAL flowing | Before the first post-death delivery: `{:halted, :owner_lost}`; after it: `{:halted, :config_invalid}` (tombstone, class halt) | The next delivery's admission fails closed, which halts the pipeline itself; an already-admitted in-flight transaction may lawfully complete | Restart explicitly — the dead generation is reaped and replaced automatically | No effect is admitted under a dead owner |
| Owner death, quiet stream | `{:halted, :owner_lost}` (persists — no delivery arrives to fail; the census dies with its owner) | The connected pipeline stays up but its next write fails closed | Restart explicitly | Same as above |
| Pipeline crash (either child) | `:catching_up` | Self-healed: the per-slot `:one_for_all` supervisor restarts assembler + connection TOGETHER, resuming from the durable checkpoint | None (a halt is permanent; a crash is not a halt) | No un-acked WAL is lost and none is applied twice (delivery re-reads the watermark under lock) |
| Pipeline halt of any origin | `{:halted, cause}` — the precise writer's cause (`:sink_failed`, `:config_invalid`, drift reasons, …), or the generic `:pipeline_terminated` when a death went unexplained | Permanent (`:temporary`); the owner erases the generation and exits | Restart explicitly (full re-admission) | The slot is never wedged by a stale generation |
| Checkpoint WRITE fault mid-delivery | `{:halted, :sink_failed}` | The whole delivery transaction rolls back — mapped rows, auxiliary effects, claims, and the checkpoint advance together | Repair the destination; restart explicitly | The un-acked WAL re-streams and replays exactly once |
| Checkpoint READ fault, persistent, mid-run | `{:halted, :sink_failed}` | The next reading callback (delivery admission, or the reconnect bind) fails closed: zero effects, watermark byte-identical | Repair the read path (permissions, catalog); restart explicitly | The connect-position read alone is fail-open (resume-from-0, transport spec §14.15) and silent — safety comes from the locked delivery re-read failing closed, so the fail-open can never yield an effect |
| Checkpoint READ fault + the slot is ABSENT at connect | Halted before streaming (transport reason `:checkpoint_unknown`) | Fail-CLOSED — deliberately NOT the resume-from-0 fail-open | Restore the slot or `reset_checkpoint/2`; restart explicitly | A lost slot is never silently treated as a fresh stream |
| Checkpoint row ABSENT under a live slot (at delivery) | `{:halted, :checkpoint_unbound}` (permanent) | Halted; never a frontier-0 reapply | `adopt_checkpoint/3` (legacy capture) or `reset_checkpoint/2` + fresh start | An absent watermark can never authorize re-delivery from zero |
| Source timeline change (same system id) | `{:halted, :source_timeline_changed}` | Halted at the bind; watermark and contract untouched | Same-primary crash-restart: `acknowledge_checkpoint_timeline/3` (idempotent). Promotion/fork you cannot prove continuous: `reset_checkpoint/2` and a full re-snapshot — never bare re-delivery | The watermark never silently crosses a WAL-history fork |
| Publication contract drift | Incompatible (removed relation, type break): `{:misconfigured, :publication_contract_incompatible}`; detected between reconnects by the census: the census drift reason | Halted (bind or census); the checkpoint freezes | Reconcile the publication with the mapped resources; restart explicitly. Additive-compatible growth is healthy and persists at the next bind — no action | The durable contract stays a faithful classifier of what the watermark covers |
| Census timeout / checker exception / unreachable source | Typed non-pass (`:census_timeout`, `:census_checker_fault`, `:census_source_unreachable`); halts `{:halted, :census_unverifiable}` at the exact configured budget of consecutive faults | The budget resets on any healthy run; drift (vs fault) halts immediately | Fix the checker substrate (privileges, reachability); restart explicitly | Quiet drift becomes a bounded halt instead of invisible |
| WAL retention horizon (O03) | `[:ash_replicant, :retention, :at_risk]` telemetry while WAL is at risk; `{:halted, :source_wal_lost}` / `{:halted, :retention_horizon_crossed}` once crossed | At-risk continues (alert only); crossed refuses the resume | While halted nothing watches the clock: run `mix ash_replicant.doctor` (or `AshReplicant.doctor/1`) on an operator scheduler — that is the documented pull channel | Recovery-impossible states alert BEFORE recovery becomes impossible |

## Restart is always explicit

Every halt in the table ends mirroring permanently. Restarting re-runs the
full admission chain (preflights, manifest, coverage, horizon) and resumes
from the durable watermark — the un-acked WAL re-streams and dedups to zero
net effect. `AshReplicant.stop_supervised/1` records `:operator_stopped` (a
stop, not a fault) and frees the slot the same way.

## Provenance

Each row's mechanism is governed by an ADR (0014 lifecycle ownership, 0019
census/readiness, 0007 effect-once, 0017 snapshot retry, 0022 recovery
horizons) and is exercised live by the fault-matrix suite
(`test/integration/fault_recovery_test.exs` and the suites it cites).
