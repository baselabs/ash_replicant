# 9. Classified boundaries: the completed value-free surface

Date: 2026-08-14

## Status

Accepted for the 1.0.0 release line (roadmap B5). Strengthens
[ADR-0006](0006-destination-transaction-boundary.md)'s transaction boundary
(the six delivery bodies) and the AGENTS Rule 4 enforcement points.

## Context

Rule 4 ("no row value in any error, log, or telemetry event, INCLUDING the
halt path") was enforced by three mechanisms with three gaps:

1. **The sink's boundary was raise-only.** Every delivery callback body used
   `rescue` alone; `:throw`/`:exit` escape a `rescue`, and DBConnection
   re-raises them after rollback. Replicant's outer wrapper catches them one
   frame up — so Rule 4 was enforced by the SIBLING's net, not our own, and
   the sink's own `[:ash_replicant, :sink, :halted]` never fired on those
   shapes. The schema-change callback had NO boundary at all: a fault escaped
   raw, and replicant's `handle_message` wrapper — while scrubbing it
   value-free — MISLABELED it `:decode_failure`, sending operators down the
   stream-corruption runbook for a sink fault.
2. **Telemetry validated KEYS, not values.** The allowlist gated metadata
   keys; a binary under the allowlisted `reason`, or a row value under a new
   measurement key, shipped downstream. The off-allowlist raise rendered the
   offending keys via `inspect` — a row value in KEY position leaked into the
   raised message itself.
3. **Identifier interpolation was config-shaped, not guarded.** Four raw-SQL
   sites interpolated DSL identifiers bare (`"#{table}"`); a `"` in an
   identifier breaks out of the quoting. Postgres ACCEPTS control characters
   inside quoted identifiers (probed live), so quoting alone would be
   "correct" — a control character in a DSL identifier is a misconfiguration
   that wrecks `pg_stat_activity` and logs either way.

## Decision

- **`catch :throw`/`:exit` at ALL SIX boundary bodies** (bind, checkpoint,
  transaction, snapshot, snapshot_complete, schema-change), routing into the
  same scrub/halt path as the rescues. The schema-change body additionally
  fires the sink's own `:halted` with the structural reason — the sink never
  raises on that path, so the sibling's `:decode_failure` mislabel becomes
  unreachable. Per-op catches in the apply paths keep the operation label for
  triage. Catching exits is deliberate: the framework already coerces them
  one frame up; the sink's catch moves the scrub EARLIER and keeps its own
  observability.
- **Typed telemetry.** Every metadata key carries an expected type
  (`reason/error_class/kind: nil|atom`, `commit_lsn/change_count:
  nil|non_neg_integer`, `table/slot_name: nil|binary`, `resource: nil|atom`,
  `tenant?: boolean`, `duration: non_neg_integer`), enforced at
  `validate!/1`; measurements gain a closed key set
  (`count|change_count|duration`; `byte_size` reserved for C1's message
  claims) with non-negative finite numeric enforcement. Violations raise
  naming the KEY and expected type only. The off-allowlist raise renders the
  COUNT of offending keys — never the keys. A conformance integration gate
  (`Telemetry.emitted_event_names/0` is the authoritative inventory)
  re-validates every live emission in handlers. BEAM honesty note: floats on
  the BEAM are always finite (arithmetic raises `badarith` instead of
  producing NaN/inf; the float bit-unifier rejects raw IEEE754 payloads —
  verified live), so the finiteness clauses are defensive documentation for
  any port, not a reachable rejection.
- **ONE identifier home** (`AshReplicant.Sql`): `quote_identifier/1` wraps in
  double quotes doubling embedded `"` (the PG-canonical escape,
  `to_regclass` round-trip probed); empty, non-binary, invalid-UTF-8, or
  NUL/C0/DEL/C1 control characters are REJECTED value-free (a misconfiguration
  fails before any SQL is built; codepoint-level scan — byte-level would
  false-positive UTF-8 continuation bytes). Every raw site routes through it,
  including the SCD2 `build_set` fragments and the manifest's relation
  quoting. **Enforcement is at ADMISSION:** the manifest walk validates every
  identifier it reads (schema, table, SCD2 window columns) at
  activation/after-compile — the raise at the SQL boundary stays
  defense-in-depth.
- **D6 absence gates:** the release contract asserts `apply_ledger` appears
  in `lib/` exactly twice (the removed option's fail-closed compile error)
  and a secret-literal scan over `lib/` is empty. The packaged `files:` list
  stays lib-only.
- **Message-claim confidentiality boundary (composes at C1/U5):** claims
  persist NO content — a versioned host-keyed HMAC over
  `canonical(system, database, slot, commit_lsn, ordinal, participant,
  invocation, content_digest)` where `content_digest` is a host-keyed digest
  of the body; responses are fixed structural payloads from an admitted codec
  set; key rotation retains key versions through the claim/recovery lifetime
  — a hard cut that orphans live claims is the same silent-suppression class
  as the operation-key collision (ADR-0010) and is rejected as such.
  Telemetry carries `byte_size` + class only. U3 ships this as the boundary
  statement; the mechanism lands with C1.

## Consequences

- Rule 4 is self-enforced at the sink's own boundary on every fault shape;
  observability (the halt event + structural reason) no longer depends on
  the sibling's wrapper or its classification.
- A control-character identifier halts at activation with a value-free
  structural reason instead of interpolating — operators see the
  misconfiguration at deploy time, not in `pg_stat_activity`.
- Telemetry typing closes type confusion; the residual — same-type value
  substitution under an allowed key (e.g. a binary `table` carrying a row
  value) — remains the caller's value-free responsibility and is stated here
  as a residual, not silently closed.
- The scrub-boundary matrix pins the red cells (throw/exit escapes; the
  schema-change raw raise) and the already-closed depth (the five raise
  cells) so vacuous confidence cannot hide the difference. Bind's throw/exit
  cells are covered by clause-identity + mutation proof: the reconnect
  coverage gate fires before any faultable seam and contains its own faults
  as `:preflight_failed`.
