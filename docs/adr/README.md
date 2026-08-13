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

## On-touch gap list (not yet authored — author when a slice next touches the surface)

These decisions are authored by their owning roadmap row (do not bulk-author them
from historical testimony):

| Decision | Owner | Surface / code evidence |
|---|---|---|
| Source-bound effect-once checkpoint and serialization | B2 | `Sink.Impl.run_transaction/4`, `AshReplicant.Checkpoint` |
| Sensitive type-shape and value-free boundary | B5 | `ValidateSensitive`, `AshReplicant.Error`, `AshReplicant.Telemetry` |
| Tenant-blind layering and pipeline ownership | B7 | `AshReplicant`, `AshReplicant.Resolver` |
| SCD2 destination constraints and continuous validation | C5 | `ValidateHistory`, `AshReplicant.Apply.Scd2` |
| `REPLICA IDENTITY FULL` operational precondition | B4 / ADR-0001 amendment | `AshReplicant.Resource`, `Resolver.tenant_changed?/2` |
