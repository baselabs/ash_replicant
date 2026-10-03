# 26. Replicant 1.4 decoder options: full pass-through AND full admission

Date: 2026-10-01 (the Replicant 1.4.0 sibling upgrade; amended the same day,
before any release was cut — see the amendment note)

## Status

Status: Accepted. Supersedes: none (extends the ADR-0005 coordination contract
with Replicant's ADR-0009 decoder surface).

> **Amendment (2026-10-01, pre-release).** This ADR was first authored with a
> `:pgoutput`-only admission refusal while the decoder options were passed
> through. The owner rejected that scope: the point of the Replicant 1.4
> upgrade is 9.6/12 capability through the plugin decoders. The refusal code
> never shipped (no tag, no Hex release carried it); this ADR records the
> decision as implemented — full admission — and keeps the amendment visible
> rather than rewriting history.

## Context

Replicant 1.4.0 added logical-decoding output-plugin selection: a top-level
`decoder:` option (`:pgoutput` the unchanged default, `:pglogical` on pglogical
2.x, `:wal2json` on wal2json ≥ 2.6), per-decoder table-set keys
(`publication:` / `replication_sets:` / `tables:`), and two wal2json-only knobs
(`allow_keyless_tables:`, `schema_check_interval:`). Upstream proves the sink
contract decoder-invariant: same callbacks, same `commit_lsn` watermark, same
checkpoint modes, byte-identical cross-decoder delivery on the tested majors
(9.6, 12, 15–18), and fail-closed halts for every plugin divergence
(keyless-table drops, dropped-column detection, empty-transaction suppression
on pre-PG15 servers).

The adapter's admission surfaces were publication-shaped before 1.4: the
activation chain required `publication:` before forwarding anything (a
plugin-shaped config died as a misleading `{:error, :config_invalid}`, and a
config carrying `decoder: :pglogical` alongside a publication STARTED silently
on pgoutput with the decoder key dropped), the source-coverage census read
`pg_publication_tables`, the durable contract manifest recorded the sorted
publication list, and the doctor's catalog statements were publication-bound.

## Decision

1. **Pass through every decoder option unchanged.** `@replicant_option_keys`
   gains `:decoder`, `:replication_sets`, `:tables`,
   `:allow_keyless_tables`, and `:schema_check_interval:`. Decoder selection
   is a tenant-blind transport concern — the same split that keeps
   multitenancy in the adapter — so the option GRAMMAR is the transport's: a
   table-set key belonging to another decoder, a wal2json-only knob under
   pgoutput, a `streaming:`/`failover:`/`messages:` capability the chosen
   decoder cannot express (a routed sink auto-starts `messages: true`;
   pglogical has none) are all refused by Replicant's own validation and
   surface as its synchronous `{:error, :config_invalid}` /
   `{:error, :decoder_capability_unsupported}` start errors. The adapter
   duplicates none of that grammar.
2. **Admit all three decoders through one table-set home.**
   `AshReplicant.SourceSet.normalize/1` is the single admission rule the
   activation chain and the doctor's plan share: `decoder:` must be one of the
   three atoms (anything else fails with the transport's own
   `:config_invalid` grammar atom); the chosen decoder's table-set key must be
   present and well-shaped (`publication:` for pgoutput, `replication_sets:`
   for pglogical, `tables:` for wal2json). Presence and shape only —
   identifier validity is the census SQL builders' own validation, exactly
   the split `publication:` always had.
3. **The census is decoder-scoped, not publication-bound.**
   `AshReplicant.Coverage.collect_census/2` branches on the set's census
   member: pgoutput keeps the publication-bound single pass BYTE-IDENTICAL to
   the pre-decoder census; pglogical's table set is the configured replication
   sets' members, discovered through Replicant's own
   `QueryBuilder.replication_set_tables/1`; wal2json's is the configured
   `tables:` list itself. The plugin paths read columns, primary keys, and
   `relreplident` through the framework's `table_columns_for/1` /
   `pk_columns_for/1` plus the adapter's `sql_relreplident_for/1` (every pair
   `Replicant.Identifier`-validated before `VALUES` interpolation). The pure
   rule evaluation (`evaluate/3`) is unchanged — strict coverage, ignores,
   RIF, type matrix all judge the same census map.
4. **The contract manifest records the decoder-scoped set, compatibly.** A
   pgoutput set builds the EXACT pre-decoder manifest shape — no `:decoder`
   key — so every stored v1 manifest keeps classifying `:equal`
   (upgrade-in-place, fingerprint unchanged). A plugin set records
   `decoder:`, its own table-set names, and `publication: []`. `classify/2`
   treats the decoder and its set as one source fact: any divergence —
   decoder switch, set change — is `{:incompatible, :decoder}`.
5. **The runtime guard and reconnect check carry the set.** The generation
   stores `source_set` (replacing `publication`); the session-identity guard
   compares the transport's context against it (the transport's context still
   names `publication:` — nil under a plugin decoder, whose table set is not a
   publication); the C01 census re-check re-runs the decoder-scoped census
   between reconnects.
6. **The doctor is decoder-aware and honest about what a catalog can prove.**
   The source release check is per-decoder: pgoutput floors at PostgreSQL 12
   (publications exist from 10; 12 is the oldest major CI runs), the plugin
   decoders floor at 9.6 — upstream's own tested plugin majors; the warn
   ceiling (19) is unchanged. **The floor is ENFORCED, not advisory**
   (amended 2026-10-02 — at 1.5.0 it was doctor-only, so a wal2json config
   against a pre-9.6 source died as the transport's connect halt instead of a
   named refusal): the census probes the release FIRST on a statement every
   connectable release can answer (`sql_release_probe/0` —
   `server_version_num` alone, because `pg_control_system()` exists from 9.6
   and would fault the whole probe on a 9.4/9.5 source into the unreachable
   class), then refuses below-floor configs with the named
   `{:error, :source_release_unsupported}` misconfiguration before any
   9.6-dependent statement runs — at activation, at the reconnect re-check,
   and mirrored by the doctor's `:source_release` check (below-floor fails;
   its sibling source checks skip with that reason). The floor map's one home
   is `AshReplicant.SourceSet.release_floors/0` (compile-time gated against
   the admitted decoder set); the ceiling above 19 stays doctor-advisory.
   The slot statement is release-conditional
   (`wal_status`/`safe_wal_size` exist from 13; a pre-13 release selects NULL
   and `Horizon.classify_slot_risk/1` reads the absent status as `:unknown`,
   never a guess). A new `:source_plugin` check reports pglogical's extension
   row (`pg_available_extensions`) — pass when available, fail
   `:source_plugin_missing` when not — and for wal2json reports
   `:plugin_presence_not_provable` (a decoding library has no extension row;
   the transport's connect-time probe is the authority). Per-table privileges
   gain a `VALUES`-joined variant for the plugin paths.
   A decoder or table-set switch between a stored contract and the live one
   halts under its own name, `:decoder_contract_incompatible` (amended
   2026-10-02 — at 1.5.0 the census folded every `{:incompatible, _}` into
   `:publication_contract_incompatible`, sending an operator hunting
   publications after a decoder switch); publication-shape incompatibility
   keeps the original atom. The session-identity guard compares the
   transport's publication view order-insensitively (the transport reports
   its own order; the manifest's canonical form is sorted).
7. **The substrate and CI tell the truth about majors.**
   `test/support/pg_old.dockerfile` mirrors upstream's public recipe
   verbatim (pglogical 2.4.8 and wal2json commit-pinned onto digest-pinned
   postgres:9.6/12 bases). The `decoder-old-majors` CI job builds it and runs
   `test/integration/decoder_admission_test.exs` per major against a 16
   destination: pglogical and wal2json lanes mirror insert/update/delete
   through the host's own actions, tolerate the pre-15 empty-transaction
   suppression (a catalog-touching zero-change transaction between mirrored
   writes), prove effect-once across stop/resume, exercise the decoder-scoped
   preflight/doctor, and — on 12 — mirror the pgoutput publication path; on
   9.6 the pgoutput lane asserts the honest pre-10 refusal class. The
   supported SOURCE matrix this package claims is exactly what CI runs:
   **pgoutput on 12 and 15–18; pglogical and wal2json on 9.6 and 12.** The
   snapshot path is decoder-invariant by construction (the same sink
   callbacks; no decoder branch exists in the provenance machinery) and rides
   upstream's cross-decoder parity suite rather than a lane of its own.

## Consequences

- A host that was silently relying on the dropped-key behavior (a config
  carrying `decoder: :pglogical` that actually ran pgoutput) now runs the
  plugin decoder it asked for, under the adapter's own census and contract —
  the fail-closed fix, not a regression.
- Stored pgoutput checkpoints, contracts, and fingerprints are untouched; a
  deployment that never configures a plugin decoder sees byte-identical
  admission behavior.
- Connect-time decoder halts (`{:decoder, :table_missing}`,
  `{:decoder, :extension_missing}`, `{:decoder, :table_keyless}`,
  `{:config, :decoder_unsupported_on_server}`) are transport-initiated and
  land in the existing generic `:pipeline_terminated` tombstone;
  Replicant's `[:replicant, :connection, :slot_invalidated]` telemetry
  carries the precise reason — documented as the operator's first stop.
- pglogical runs its tables under DEFAULT replica identity (its native
  protocol keys off the primary key; it refuses REPLICA IDENTITY FULL tables
  in update/delete sets — observed live). The adapter's own RIF rules are
  unchanged and remain what they always were: tenant-scoped sources, SCD2
  non-PK business keys, and append logs require FULL; wal2json delivers the
  full old record under FULL; a pglogical tenant-scoped source therefore
  needs its PK columns to satisfy the adapter's tenant resolution the same
  way pgoutput DEFAULT-identity tables do under the recorded rules.
- Evidence: `test/ash_replicant/source_set_test.exs` (the admission matrix),
  the decoder-set describe in `checkpoint_identity_test.exs` (manifest
  shapes, the stored-pgoutput `:equal` back-compat, the `{:incompatible,
  :decoder}` classifier), `decoder_option_test.exs` (admission, grammar
  forwarding, the doctor plan), `doctor_test.exs` (per-decoder floors), and
  `test/integration/decoder_admission_test.exs` (the live lanes; locally the
  substrate runs in the BaseLabs cluster's ephemeral namespace via
  `ASH_REPLICANT_PGOLD_URL`).

## Amendment (2026-10-03): the delegated snapshot evidence exists — the lock moved, the floor did not

Decision §7's closing sentence delegates the snapshot path on the
plugin-decoder majors to upstream's cross-decoder parity suite. That
delegation had no teeth for two releases without anyone knowing: Replicant
1.4.0 and 1.4.1 rejected PostgreSQL 9.6's two-part exported-snapshot name
in `set_transaction_snapshot/1`, so `snapshot: true` on a 9.6
pglogical/wal2json source — inside this package's supported matrix —
failed its back-fill (`:snapshot_failed`) and held `:snapshot_incomplete`,
fail-closed, delivering nothing. Upstream's suite did not carry a 9.6
snapshot leg until the fix itself. Replicant 1.4.2 (October 3, 2026) fixes
the transport (the middle hex group of the name allowlist becomes optional;
character class and string-literal guard unchanged — verified against the
`v1.4.1…v1.4.2` bytes, `query_builder.ex` alone) and adds the missing
connected leg (`test/integration/plugin_snapshot_pg96_test.exs`: a 9.6
back-fill under a continuously committing writer, every row exactly once
across the snapshot/stream handoff), which is now what the delegation
rests on. Nothing in this adapter changed: the snapshot machinery is
decoder-invariant and no adapter code references the snapshot name
(re-verified: zero references in `lib/`). The release lock moves to 1.4.2;
the requirement floor stays `>= 1.4.0` (ADR-0002's same-day amendment
records why: the broken slice is loud and fail-closed, not the class that
moves floors).
