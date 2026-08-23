# ADR-0022: Recovery horizons and typed telemetry proof

Date: 2026-08-23
Status: Accepted (O03, issue #13)
Supersedes: none (extends ADR-0015 message claims, ADR-0019 status vocabulary,
and the D5/U3 typed telemetry surface)

## Context

A standalone `pg_logical_emit_message` is deduped by NOTHING but its AshOnetime
claim — `handle_message/2` has no watermark skip, and the claim commits before
the watermark moves (for external-effect routes, three-state recovery rides the
claim and the watermark advances only after finalize). The claim lives until
`retain_until = admitted_at + retention_seconds`; the cleanup worker then reaps
it. Meanwhile the slot retains the un-acked WAL until `max_slot_wal_keep_size`
is exceeded: `wal_status` walks `reserved → extended → unreserved` (still
recoverable) `→ lost` (impossible).

Two horizons follow, and both fail SILENTLY without this ADR:

1. **Claim retention.** An outage shorter than the slot's WAL window but longer
   than a route's declared retention expires the dedup while the WAL is still
   recoverable — re-delivery then RE-EXECUTES the message (effect-once broken)
   or blocks recovery (external routes) with no prior signal.
2. **Digest-key rotation.** The claim stores only a hash of the versioned
   digest string, so the mint version is unreadable from claims. Removing a
   still-needed key version turns a recoverable re-delivery into the
   `content_digest_mismatch` halt: fail-closed, but recovery is blocked.

The issue #13 acceptance: horizon violations alert BEFORE recovery becomes
impossible; telemetry metadata/measurements stay typed with mutation tests
covering every key; the OTel/metrics examples are executable.

## Decision

1. **`recovery_horizon {count, unit}` is a sink DSL option** — the operator's
   supported outage/replay window, REQUIRED exactly when claim-backed
   `message_routes` exist on a state-mirror sink (compile), REJECTED otherwise
   (route-less sinks have no claims; an `:append_log` sink's routes dedup
   structurally through the append identity, ADR-0018). Activation refuses
   `:retention_below_recovery_horizon` when the manifest's minimum claim
   retention does not cover the horizon. One classification body:
   `AshReplicant.Horizon`.

2. **A digest-key witness on the checkpoint row.** The nullable
   `digest_key_state` column carries an authenticated envelope (the
   `Snapshot.State` framing pattern): the last-observed digest-key versions,
   active version, and observation time — MAC'd under the ORTHOGONAL
   `:ash_replicant, :horizon_provenance_keys` family, never the rotating
   message digest keys themselves (authenticating under the keys whose removal
   the witness detects is circular). Written at bind and on every
   census-observed SET change — claims mint continuously, so a bind-only
   witness understates a removed version's last-mint time and the canonical
   add-v2-then-remove-v1 rotation goes blind in proportion to connection age
   (the adversarial F1 finding). Classification: a version removed within
   `max(route retention)` of the last observation containing it is
   `:digest_key_horizon_violated` (census drift halt / activation refusal /
   doctor fail); past the horizon it is a legitimate retirement and the
   envelope rebinds; undecodable, tampered, or clock-regressed state is
   `:digest_key_state_invalid`, fail closed. A NULL envelope on a claim-routed
   row MINTS rather than halts (the pre-O03 upgrade posture).

3. **Three alert delivery legs**, because the census dies with the pipeline
   and the primary horizon scenario is HALTED (adversarial F2):
   - **Census push while running**: slot facts classified through the doctor's
     own probe (`lost` → `:source_wal_lost` drift halt; `unreserved`/exhausted
     → `[:ash_replicant, :retention, :at_risk]`, meta only, continue).
   - **Activation resume gate**: re-activating after a halt whose duration
     crossed the retention floor while the slot still retains WAL refuses
     `:retention_horizon_crossed` — the operator reconciles consciously (the
     no-unproven-zero posture). A lost slot defers to the stream's own
     failure (data loss, not duplication); an unreachable probe never blocks
     recovery.
   - **Doctor pull while halted**: the `:retention_horizon` check delegates to
     the same Horizon body; the doctor (operator-invoked or on the operator's
     own scheduler) is the documented periodic probe for a halted pipeline —
     the supervision contract ("no new process") forbids a library-owned
     halted-state watcher.

4. **One SQL home.** `Doctor.Probe.sql_replication_slot/0` gained
   `safe_wal_size` itself; the runtime probes THROUGH `Probe.probe_slot/2`
   (rule 11: never a copy).

5. **Executable examples + per-key mutation matrix.** The `Telemetry`
   moduledoc's metrics and OpenTelemetry-bridge blocks are extracted verbatim
   and executed by a test; the OTel mapping table is pinned complete against
   `emitted_event_names/0`. The data-boundary mutation matrix carries one
   mutant family per typed metadata key, per measurement key, and per shared
   type clause, with a completeness tripwire forcing every future key to ship
   with its mutant.

## Consequences

- Message-route sinks carry a breaking DSL addition (pre-1.0,
  release-candidate: acceptable; the installer generates no routes by default).
- Hosts must run `mix ash.codegen` for the new checkpoint column and configure
  `:horizon_provenance_keys` when they use message routes — the CHANGELOG and
  README carry both steps.
- The at-risk event carries NO measurement (byte_size is C1-reserved; a
  non-positive `safe_wal_size` would fail measurement validation and mask the
  alert as a checker fault).
- Forward writer clock skew overstates elapsed time in the legitimate-retirement
  direction; accepted as bounded (NTP scale vs hours–days horizons).
- Key material grows by one family; the witness stores version integers and a
  timestamp only — never key bytes (value-free, Critical Rule 4).

## Alternatives rejected

- App-env horizon (invisible to compile verifiers and DSL introspection — the
  ADR-0001 pattern puts fail-closed config in the DSL).
- Optional horizon with a doctor `:skipped` (leaves the validation vacuous
  exactly when claims exist).
- Reading mint-versions from claims (impossible — the fingerprint is a hash);
  forbidding key removal entirely (unbounded key sprawl); config-declared
  retirement timestamps (self-attested); node-local witness state (lost on
  restart — exactly when outages happen); MAC under the digest keys
  (circular).
- A library-owned halted-state watcher process (violates the supervision
  contract; the doctor on the operator's scheduler is the pull channel).
- A second slot SQL statement for the runtime (rule 11: one home; the
  statement was extended instead).
