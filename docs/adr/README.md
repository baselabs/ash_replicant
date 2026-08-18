# Architecture Decision Records

Product-shaping decisions for `ash_replicant`, one file per decision (Nygard format:
Status / Context / Decision / Consequences). Tracked (not gitignored) — a bare clone, CI,
or a future maintainer needs them; the deliberation stays in the local `.forge/specs/`
design notes, the DECISION lands here.

**Authoring rule:** ADRs are authored **on-touch**, by the slice that owns or changes the
surface — never bulk-authored from testimony. The charter (`docs/CHARTER.md`) still holds
the narrative "why"; an ADR is the tracked, per-decision record with code evidence.

## Records

| # | Decision | Charter ref |
|---|---|---|
| [0001](0001-fail-closed-multitenancy.md) | Multitenancy is fail-closed; a declared tenant source requires a multitenancy block | [D2] |
| [0002](0002-supported-runtime-and-dependencies.md) | Support Elixir 1.20.3/OTP 29 and an audit-clean Ash 3 line | 1.0.0 release contract |
| [0003](0003-verification-and-release-evidence.md) | Release evidence must prove no-database, live integration, drift, docs, and package substrates independently | 1.0.0 release contract |
| [0004](0004-public-authority-and-release-history.md) | Public authority follows live code and immutable receipts; historical gaps are reported, not invented | A4 / E1 |
| [0005](0005-replicant-coordination.md) | Support Replicant 1.x from Hex, pin actual-session identity at activation, and preserve explicit capability gates | A3 / B2 / C1–C3 |
| [0006](0006-destination-transaction-boundary.md) | Admit one recursive AshPostgres destination action graph and only WAL-safe local AshOnetime participants | B1 / C1–C4 |
| [0007](0007-source-bound-checkpoint-effect-once.md) | Bind checkpoints to the actual-session source identity with a locked monotonic watermark and a classified contract manifest | B2 / C1–C3 / C5 |
| [0008](0008-strict-source-coverage.md) | Preflight publication and mapping coverage against the live source catalog; enforce REPLICA IDENTITY FULL where old-record tenants are required | B3 / B4 / C5 |
| [0009](0009-classified-boundaries.md) | Complete the value-free boundary (throw/exit catches at all six bodies, schema-change reclassification), typed telemetry, one identifier quoting home with admission-time control-character rejection | B5 |
| [0010](0010-host-action-contract.md) | Per-invocation operation discriminator closing the intra-change AshOnetime key collision (declarations stay 6-axis); notifier `load/2` manifest admission; the action-contract freeze table | B6 |
| [0011](0011-frozen-reason-and-event-taxonomy.md) | The closed error-reason set and the telemetry event-name inventory are pinned public contract — additive growth only, removal/rename is breaking with migration notes | B5 / D3 / D8 |
| [0012](0012-snapshot-run-scoped-ordinal-space.md) | One continuing ordinal axis per snapshot run, keyed by the run's consistent point — the axis ADR-0010's operation keys depend on | B6 / C3 |

## On-touch gap list (not yet authored — author when a slice next touches the surface)

These decisions are authored by their owning roadmap row (do not bulk-author them
from historical testimony). Rows whose decision has since been authored are
retired here: the sensitive type-shape / value-free boundary row was authored as
[ADR-0009](0009-classified-boundaries.md) (B5), and the `REPLICA IDENTITY FULL`
operational precondition row is governed by
[ADR-0008](0008-strict-source-coverage.md) (enforced at activation by
`AshReplicant.Coverage`'s preflight census) with the runtime old-side halt in
[ADR-0001](0001-fail-closed-multitenancy.md)'s B4 amendment:

| Decision | Owner | Surface / code evidence |
|---|---|---|
| Tenant-blind layering and pipeline ownership | B7 | `AshReplicant`, `AshReplicant.Resolver` |
| SCD2 destination constraints and continuous validation | C5 | `ValidateHistory`, `AshReplicant.Apply.Scd2` |
