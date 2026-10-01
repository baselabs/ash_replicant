# 26. Replicant 1.4 decoder options: full pass-through, pgoutput-only admission

Date: 2026-10-01 (the Replicant 1.4.0 sibling upgrade)

## Status

Status: Accepted. Supersedes: none (extends the ADR-0005 coordination contract
with Replicant's ADR-0009 decoder surface).

## Context

Replicant 1.4.0 added logical-decoding output-plugin selection: a top-level
`decoder:` option (`:pgoutput` the unchanged default, `:pglogical` on pglogical
2.x, `:wal2json` on wal2json ≥ 2.6), per-decoder table-set keys
(`publication:` / `replication_sets:` / `tables:`), and two wal2json-only knobs
(`allow_keyless_tables:`, `schema_check_interval:`). Upstream proves the sink
contract decoder-invariant: same callbacks, same `commit_lsn` watermark, same
checkpoint modes, byte-identical cross-decoder delivery on the tested majors
(9.6, 12, 15–18), and fail-closed halts for every plugin divergence
(keyless-table drops, dropped-column detection, empty-transaction suppression on
pre-PG15 servers).

The adapter had two coupling facts to answer for. First, its activation chain
forwarded a CLOSED allowlist of transport options and required `publication:`
before any forwarding, so a plugin-shaped configuration could never reach the
transport: `decoder: :wal2json` with `tables:` died as a misleading
`{:error, :config_invalid}` (nil publication), and `decoder: :pglogical` with a
publication present STARTED silently on pgoutput — the decoder key was dropped
on the floor, exactly the misconfiguration trap a fail-closed adapter must
refuse. Second, the adapter's own admission invariants are publication-scoped:
the source-coverage census reads `pg_publication_tables` (preflight and the C01
reconnect check), the durable contract manifest records the sorted publication
list and halts `{:incompatible, :publication}` on any change, and the doctor's
catalog statements are publication-bound.

## Decision

1. **Pass through every decoder option unchanged.** `@replicant_option_keys`
   gains `:decoder`, `:replication_sets`, `:tables`,
   `:allow_keyless_tables`, and `:schema_check_interval`. Decoder selection is
   a tenant-blind transport concern — the same split that keeps multitenancy in
   the adapter — so the option GRAMMAR is the transport's: a table-set key
   belonging to another decoder, a wal2json-only knob under pgoutput, an
   unknown decoder atom, and a capability the chosen decoder cannot express
   (`streaming:`/`failover:` off pgoutput, `messages:` on pglogical — relevant
   because a routed sink auto-starts `messages: true`) are all refused by
   Replicant's own validation and surface as its synchronous
   `{:error, :config_invalid}` / `{:error, :decoder_capability_unsupported}`
   start errors. The adapter duplicates none of that grammar.
2. **Admission is `:pgoutput`-only, refused with a named error.** One
   adapter-side rule (`AshReplicant.validate_decoder/1`, the SAME body the
   activation chain and the doctor's plan call) refuses `:pglogical` and
   `:wal2json` with `{:error, :decoder_unsupported}` — before publication
   normalization, so the plugin-shaped config gets the truthful named refusal
   instead of the nil-publication `:config_invalid`. The error is
   value-free and structural; it names the operator's fix (configure pgoutput
   or wait for plugin admission).
3. **Connect-time decoder halts stay transport-owned.** Replicant 1.4's
   connect-time halts (`{:decoder, :table_missing}`,
   `{:decoder, :extension_missing}`, `{:decoder, :table_keyless}`,
   `{:config, :decoder_unsupported_on_server}`) are delivered through
   `Replicant.Supervisor.halt/2`, which discards the cause; none of the four
   arises for a pgoutput publication on the supported 16–18 matrix. The
   pipeline death surfaces as the existing generic `:pipeline_terminated`
   tombstone, and the precise reason rides upstream's
   `[:replicant, :connection, :slot_invalidated]` telemetry — documented in
   `usage-rules.md` as the operator's first stop. No adapter error-tuple
   enumeration changes: the adapter never pattern-matched `Replicant.Error`
   reasons before 1.4 and does not start now (the start-time atoms pass
   through raw, value-free, from `Replicant.start_link/1`'s own return).
4. **The Replicant floor moves to `>= 1.4.0 and < 2.0.0-0`.** The adapter now
   forwards the 1.4 option grammar, and the documented decoder contract (the
   refusal set, the capability refusals, the grammar errors) is only true of a
   1.4 runtime; a consumer resolving 1.3.x would get a silently narrower
   grammar than the one this package documents and forwards into.
5. **Plugin-decoder admission is roadmap work with a named inventory.**
   Lifting the refusal requires: decoder-aware table-set census (upstream
   ships the query surface — `QueryBuilder.replication_set_tables/1`,
   `configured_table_info/1`, `table_columns_for/1`, `pk_columns_for/1` —
   which the adapter's census and doctor probe statements would adopt, each
   new statement joining `Probe.statements/1` with its non-vacuity test and
   live gate per ADR-0025); a contract manifest that records the
   decoder-scoped table set without breaking stored pgoutput manifests
   (absent decoder key = pgoutput, so existing fingerprints classify
   `:equal`); a `decoder` leg in the doctor; pre-15 compatibility of every
   probe statement (`pg_control_system()` exists from 9.6); and integration
   evidence on the plugin majors (9.6/12), which this repo's CI matrix
   (pinned PG16/17/18) does not currently host. The supported-major claim
   until then is honest: pgoutput on PostgreSQL 16–18 — this repo's tested
   matrix — with upstream's own 9.6/12/15 plugin parity unused by this
   adapter.

## Consequences

- A host that was silently relying on the dropped-key behavior (a config
  carrying `decoder: :pglogical` that actually ran pgoutput) now fails at
  start with the named error — the fail-closed fix, not a regression.
- The empty-transaction suppression on pre-PG15 servers cannot affect the
  tested matrix (16–18) and the sink has no empty-transaction reliance:
  `handle_transaction/1` applies only delivered changes, and upstream keeps
  an `:append_log` sink's slot at its durable frontier across suppressed
  empty transactions (its Critical Rule 3's append clause), preserving the
  out-of-band-advance detection ADR-0018 relies on.
- Dropped-column `:destructive` halts now fire on every decoder at the change
  (wal2json previously saw them only at reconnect); for the adapter this is
  the existing `handle_schema_change/2` → `on_schema_change` policy path,
  unchanged.
- Evidence: `test/ash_replicant/decoder_option_test.exs` (admission
  refusals at activation and in the doctor plan, the pass-through grammar
  proofs — each cross-decoder key and wal2json-only knob refused BY
  REPLICANT, which proves the forwarding — and the explicit-pgoutput
  admitted start); `replicant_dependency_test.exs` pins the floor and the
  three-atom decoder grammar.
